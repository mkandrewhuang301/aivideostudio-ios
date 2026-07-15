// EditorView.swift
// Fantasia
// Phase 13, Plan 11: the Editor shell (top bar, preview stage, controls row, timeline mount
// point) hosting the locked sketch's layout (.planning/sketches/001-video-editor-v0/index.html)
// + 13-UI-SPEC.md's Editor deltas (project-title rename, forced-dark canvas). This is a
// SEPARATE screen tree from GenerateView — nothing here touches the composer/keyboard code
// (CLAUDE.md frozen section).
//
// Forced-dark exception (13-UI-SPEC.md): this canvas is ALWAYS dark, regardless of the app's
// light/dark ThemeManager setting — matches every professional video editor convention and the
// locked sketch, which has no light variant.
//
// Plan 12 replaced plan 11's placeholder mount view below with the real TimelineTrackView
// (Fantasia/Views/Editor/TimelineTrackView.swift) — filmstrip clips, fixed-center playhead,
// background scrub, and the stacked Text/Audio/Caption track mount points.
//
// Plan 17: wires the Export button (top bar) to the real backend export pipeline (plan 07's
// POST /:id/export via ProjectManager.exportProject(id:), plan 08). Dispatch is a brief
// disabled-spinner window only (D-12 — export never locks the project); the returned
// generation_id is handed to the EXISTING GenerationManager poll loop (no new polling code) so
// completion/failure follow the app-wide APNs push + Generate feed pattern (D-07) — zero new
// completion UI here. Exact copy strings per 13-UI-SPEC.md's Export Flow section.

import SwiftUI
import AVFoundation

struct EditorView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(\.dismiss) private var dismiss

    @State private var state: EditorState
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleError: String?
    @State private var titleErrorClearTask: Task<Void, Never>?

    @State private var isExporting = false
    @State private var exportToastMessage: String?
    @State private var exportToastTask: Task<Void, Never>?
    @State private var exportFailedError: String?

    // Plan 16: fullscreen preview player (SC6) + Caption Style sheet (Delta 4).
    @State private var showFullscreenPlayer = false
    @State private var showCaptionStyleSheet = false

    // 13-19 Task A: default-bar Audio action opens the sheet here now (lifted up from
    // AudioTrackRow, which owned it before the bottom bar existed).
    @State private var showAddAudioSheet = false
    @State private var isCaptionsBusy = false
    @State private var barToastMessage: String?
    @State private var barToastTask: Task<Void, Never>?

    // 13-19 Task C0: the assembled back-to-back playback composition + each clip's
    // [start, end) on that composition's timeline (global seconds) — rebuilt whenever
    // `state.project.clips` changes. `currentPlayEnd` is the play-range boundary the periodic
    // time observer auto-pauses at (recomputed from `state.selection` each time Play is pressed).
    @State private var clipRanges: [EditorCompositionBuilder.ClipRange] = []
    @State private var currentPlayEnd: Double = .infinity

    // Forced-dark palette (13-UI-SPEC.md Color contract) — NOT theme.background/theme.surface.
    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051)   // #0A0A0D
    private let previewStageBackground = Color(red: 0.047, green: 0.047, blue: 0.067) // #0C0C11
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)                 // #8C59FF
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)          // #FF5470

    private static let aspectOptions: [String] = ["9:16", "4:5", "1:1", "16:9"]

    init(project: EditProject) {
        _state = State(initialValue: EditorState(project: project))
    }

    var body: some View {
        editorContent
            .background(canvasBackground.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { Task { await rebuildPlayer() } }
            .onDisappear { tearDownPlayer() }
            .onChange(of: state.isPlaying) { _, isPlaying in handlePlayingChange(isPlaying) }
            .onChange(of: state.currentTime) { _, newValue in handleScrubSeek(newValue) }
            .onChange(of: state.project.clips) { _, _ in Task { await rebuildPlayer() } }
            .sheet(isPresented: $showAddAudioSheet) {
                // F8 (Plan 13-21): idsBefore snapshots at PRESENTATION time (this closure runs once
                // per sheet presentation) — onAdded diffs against it to find the newly-added row
                // and records an "add" UndoableAction (undo = soft-delete, redo = restore).
                let idsBefore = Set(state.project.audioClips.map(\.id))
                AddAudioSheet(currentTime: state.currentTime, onAdded: {
                    syncProjectFromManager()
                    let newIds = Set(state.project.audioClips.map(\.id)).subtracting(idsBefore)
                    for newId in newIds {
                        state.history.record(UndoableAction(
                            label: "Add audio",
                            undo: { try await projectManager.deleteAudioClip(audioId: newId) },
                            redo: { try await projectManager.restoreAudioClip(audioId: newId) }
                        ))
                    }
                })
            }
            .overlay(alignment: .bottom) { barToastOverlay }
            .onChange(of: showFullscreenPlayer) { _, isShowing in handleFullscreenChange(isShowing) }
            .fullScreenCover(isPresented: $showFullscreenPlayer) {
                FullscreenEditorPlayerView(state: state, onMinimize: { showFullscreenPlayer = false })
            }
            .sheet(isPresented: $showCaptionStyleSheet) {
                CaptionStyleSheet(state: state)
            }
            .overlay(alignment: .bottom) { exportToastOverlay }
            .alert("Export failed", isPresented: Binding(
                get: { exportFailedError != nil },
                set: { if !$0 { exportFailedError = nil } }
            )) {
                Button("OK", role: .cancel) { exportFailedError = nil }
            } message: {
                Text(exportFailedError ?? "")
            }
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            topBar
            previewStage
            controlsRow
            TimelineTrackView(
                state: state,
                onAddAudio: { showAddAudioSheet = true },
                onAddDefaultText: { Task { await addDefaultTextOverlay() } },
                onCoverUpdated: {
                    syncProjectFromManager()
                    showBarToast("Cover updated")
                }
            )
            editorBottomBar
        }
    }

    private var editorBottomBar: some View {
        EditorBottomBar(
            state: state,
            onEdit: selectClipUnderPlayhead,
            onAddText: { Task { await addDefaultTextOverlay() } },
            onAddAudio: { showAddAudioSheet = true },
            onCaptions: handleCaptionsAction,
            hasCaptionableMedia: hasCaptionableMedia,
            isCaptionsBusy: isCaptionsBusy,
            onSplit: performSplit,
            onDone: { state.select(.none) },
            onDeleteSelected: deleteSelected,
            onEditText: requestEditSelectedText,
            onDuplicateText: { Task { await duplicateSelectedText() } },
            onEditCaption: requestEditSelectedCaption
        )
    }

    @ViewBuilder
    private var barToastOverlay: some View {
        if let barToastMessage {
            Text(barToastMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 74)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var exportToastOverlay: some View {
        if let exportToastMessage {
            Text(exportToastMessage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.75), in: Capsule())
                .padding(.bottom, 24)
                .transition(.opacity)
        }
    }

    // Task C: seek-on-scrub. Compares against the PLAYER's own current time rather than a
    // "player-originated write" boolean flag (the plan's sanctioned alternative) — the periodic
    // time observer's own writes always land within epsilon of the player's actual position, so
    // only a genuine external scrub (timeline drag) triggers a seek.
    private func handleScrubSeek(_ newValue: Double) {
        guard let player else { return }
        let playerSeconds = player.currentTime().seconds
        guard playerSeconds.isFinite else { return }
        if abs(playerSeconds - newValue) > 0.15 {
            let target = CMTime(seconds: newValue, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func handlePlayingChange(_ isPlaying: Bool) {
        if isPlaying {
            currentPlayEnd = computePlayEnd()
            player?.play()
        } else {
            player?.pause()
        }
    }

    // The fullscreen player (plan 16) owns its own AVPlayer bound to the same EditorState clock —
    // pause the inline player while fullscreen is up so both players' periodic time observers
    // never race writes onto state.currentTime at once, then reconcile the inline player's
    // position/playback back on minimize.
    private func handleFullscreenChange(_ isShowing: Bool) {
        if isShowing {
            player?.pause()
        } else if let player {
            let time = CMTime(seconds: state.currentTime, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if state.isPlaying { player.play() }
        }
    }

    // MARK: - Top bar: close ✕ / tap-to-rename title (Delta 1) / Export
    //
    // F6 (Plan 13-21): rebuilt as a ZStack — the title layer is centered on the FULL bar width
    // (screen center), with ✕/Export in a SEPARATE HStack layer on top. Previously the title sat
    // inside the SAME HStack as ✕/Export (HStack(spacer, title, spacer, export)), which centers it
    // between the two buttons, not on the screen — visibly off-center whenever the two buttons'
    // widths differ (they do: Export becomes "Exporting…", wider, while dispatching). The title's
    // available width is now explicitly capped so a long title truncates with "…" instead of ever
    // pushing into (or being pushed by) either button — measured live via onGeometryChange so the
    // cap self-adjusts if either button's width changes (e.g. Export → "Exporting…").

    @State private var closeZoneWidth: CGFloat = 44
    @State private var exportZoneWidth: CGFloat = 90

    private var topBar: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack {
                    titleView
                        .frame(
                            maxWidth: max(geo.size.width - 2 * max(closeZoneWidth, exportZoneWidth) - 16, 40)
                        )
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Close editor")
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { closeZoneWidth = $0 }

                        Spacer(minLength: 8)

                        exportButton
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { exportZoneWidth = $0 }
                    }
                }
            }
            .frame(height: 44)

            if let titleError {
                Text(titleError)
                    .font(.system(size: 11))
                    .foregroundStyle(destructive)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 2) // F7 (Plan 13-21): 6 → 2, frees more vertical space for the preview
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Untitled Project", text: $titleDraft)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .frame(maxWidth: 200)
                .onSubmit { commitTitleRename() }
        } else {
            Button {
                titleDraft = state.project.title ?? ""
                isEditingTitle = true
            } label: {
                HStack(spacing: 8) {
                    // F6: lineLimit(1) + truncationMode(.tail) — the outer titleView.frame(maxWidth:)
                    // above proposes a capped width to this HStack, which SwiftUI shrinks the
                    // flexible Text into (the pencil icon, having no flexibility, stays full-size
                    // and always visible next to the truncated text).
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var displayTitle: String {
        let title = state.project.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled Project" : title
    }

    private var exportButton: some View {
        Button {
            performExport()
        } label: {
            Group {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white)
                        Text("Exporting…")
                    }
                } else {
                    Text("Export")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(accent, in: Capsule())
        }
        .disabled(isExporting)
    }

    // MARK: - Export (Delta: Plan 17 — D-07/D-10/D-12/SC7)
    //
    // The button is only disabled long enough to prevent a double-tap during the network
    // round-trip to dispatch — NOT for the whole render (D-12: the project was never locked, so
    // Export becomes tappable again immediately after dispatch succeeds). The returned
    // generation_id is fed into the EXISTING GenerationManager poll loop so the export enters the
    // normal tracked-generations set; completion/failure are handled entirely by the app-wide
    // APNs push + Generate feed refresh (D-07) — no bespoke export-status polling here.
    private func performExport() {
        guard !isExporting else { return }
        isExporting = true
        Task {
            do {
                _ = try await projectManager.exportProject(id: state.project.id)
                isExporting = false
                showExportToast("Exporting your video — we'll notify you when it's ready.")
                generationManager.startPolling(forceRefresh: true)
            } catch {
                print("[EditorView] exportProject error: \(error)")
                isExporting = false
                exportFailedError = "Your project is safe — nothing was lost. Try exporting again."
            }
        }
    }

    private func showExportToast(_ message: String) {
        exportToastMessage = message
        exportToastTask?.cancel()
        exportToastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            exportToastMessage = nil
        }
    }

    private func commitTitleRename() {
        isEditingTitle = false
        let newTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousTitle = state.project.title
        guard newTitle != (previousTitle ?? "") else { return }

        state.project.title = newTitle.isEmpty ? nil : newTitle // optimistic local update
        Task {
            do {
                try await projectManager.updateProjectTitle(newTitle)
                // F8: "update" record — before/after are the two title strings themselves.
                state.history.record(UndoableAction(
                    label: "Rename project",
                    undo: { try await projectManager.updateProjectTitle(previousTitle ?? "") },
                    redo: { try await projectManager.updateProjectTitle(newTitle) }
                ))
            } catch {
                print("[EditorView] updateProjectTitle error: \(error)")
                state.project.title = previousTitle // revert — no blocking alert
                showTitleError("Couldn't rename project.")
            }
        }
    }

    private func showTitleError(_ message: String) {
        titleError = message
        titleErrorClearTask?.cancel()
        titleErrorClearTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            titleError = nil
        }
    }

    // MARK: - Preview stage: AVPlayer-backed inline surface, letterboxed to state.aspectRatio

    private var previewStage: some View {
        GeometryReader { geo in
            let ratio = Self.aspectFraction(state.aspectRatio)
            // Task C: the preview is the hero — grows to fill whatever vertical space is left
            // over from topBar/controlsRow/TimelineTrackView/EditorBottomBar (all fixed-height),
            // instead of a hard-coded 340pt. F7 (Plan 13-21): stage insets shrink 24 → 8pt (both
            // axes) so the preview is visibly larger — the letterbox math itself is unchanged, a
            // non-matching source clip still correctly shows bars.
            let maxHeight = max(geo.size.height - 8, 100)
            let availWidth = geo.size.width - 8
            let size: CGSize = {
                if maxHeight * ratio <= availWidth {
                    return CGSize(width: maxHeight * ratio, height: maxHeight)
                } else {
                    return CGSize(width: availWidth, height: availWidth / ratio)
                }
            }()

            ZStack {
                if let player {
                    FillingVideoPlayerView(player: player, videoGravity: .resizeAspect)
                } else {
                    Color.black
                    Image(systemName: "film")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.3))
                }
                // i5.3 (Plan 13-20): the composition only carries VIDEO frames (see
                // buildComposition's KNOWN LIMITATION doc comment below) — when the playhead sits
                // inside an IMAGE clip's [start, end) range, overlay the still directly so image
                // clips are no longer a black hole in the live preview (export already renders
                // them correctly server-side).
                if let imageClipURL = currentImageClipURL {
                    AsyncImage(url: imageClipURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Color.black
                        }
                    }
                }
                // F11 (Plan 13-21): tap-outside-deselects catcher — sits BEHIND
                // TextOverlayCanvasView (added via `.overlay` below, which layers on top of this
                // whole ZStack), so a tap on an actual text overlay's own hit target still wins;
                // a tap anywhere else on the empty video area falls through to here and deselects.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.select(.none) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                // Plan 13: on-video Text overlays (SC3), sized/clipped to the same letterboxed
                // canvas frame the AVPlayer surface renders in so overlay coordinates line up 1:1.
                TextOverlayCanvasView(state: state)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .overlay {
                // Plan 16: live karaoke captions (SC5's render half — Delta 6), same letterboxed
                // canvas frame as the Text overlay layer above so both sit in the same coordinate
                // space as the AVPlayer surface. Read-only preview, never interactive.
                CaptionOverlayView(state: state)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(previewStageBackground)
    }

    private static func aspectFraction(_ ratio: String) -> CGFloat {
        switch ratio {
        case "9:16": return 9.0 / 16.0
        case "4:5": return 4.0 / 5.0
        case "1:1": return 1.0
        case "16:9": return 16.0 / 9.0
        default: return 9.0 / 16.0
        }
    }

    // MARK: - Controls row: fullscreen + aspect-ratio toggle + undo/redo (sketch's controls-row)

    private var controlsRow: some View {
        HStack(spacing: 4) {
            Button {
                showFullscreenPlayer = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Fullscreen")

            Button {
                cycleAspectRatio()
            } label: {
                Text(state.aspectRatio)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Aspect ratio")

            // Plan 16, Delta 4: Caption Style gear — only once the Captions track has >=1 cue.
            if !state.project.captionCues.isEmpty {
                Button {
                    showCaptionStyleSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Caption style")
            }

            // F11 (Plan 13-21): tapping the empty space between the aspect/caption-style buttons
            // and the undo/redo buttons deselects — same tap-outside-deselects treatment as the
            // preview stage and timeline background.
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { state.select(.none) }

            // F8 (Plan 13-21): undo HIDDEN until the stack is non-empty, redo HIDDEN until ITS
            // stack is non-empty (exact user spec — redo only ever appears after an undo). Both
            // disabled while an undo/redo is already in flight (EditorHistory.isProcessing).
            if state.history.canUndo {
                Button {
                    Task { await performUndo() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .disabled(state.history.isProcessing)
                .accessibilityLabel("Undo")
            }

            if state.history.canRedo {
                Button {
                    Task { await performRedo() }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .disabled(state.history.isProcessing)
                .accessibilityLabel("Redo")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2) // F7 (Plan 13-21): 4 → 2, frees more vertical space for the preview
    }

    // MARK: - Undo/redo (F8, Plan 13-21)

    private func performUndo() async {
        if let errorMessage = await state.history.undo() {
            showBarToast(errorMessage)
        }
        syncProjectFromManager()
    }

    private func performRedo() async {
        if let errorMessage = await state.history.redo() {
            showBarToast(errorMessage)
        }
        syncProjectFromManager()
    }

    private func cycleAspectRatio() {
        let options = Self.aspectOptions
        let currentIndex = options.firstIndex(of: state.aspectRatio) ?? 0
        let nextRatio = options[(currentIndex + 1) % options.count]
        let previousRatio = state.aspectRatio

        state.aspectRatio = nextRatio // immediate local preview feedback
        Task {
            do {
                try await projectManager.updateAspectRatio(nextRatio)
                state.project.aspectRatio = nextRatio
                state.history.record(UndoableAction(
                    label: "Aspect ratio",
                    undo: {
                        try await projectManager.updateAspectRatio(previousRatio)
                        state.aspectRatio = previousRatio
                        state.project.aspectRatio = previousRatio
                    },
                    redo: {
                        try await projectManager.updateAspectRatio(nextRatio)
                        state.aspectRatio = nextRatio
                        state.project.aspectRatio = nextRatio
                    }
                ))
            } catch {
                print("[EditorView] updateAspectRatio error: \(error)")
                state.aspectRatio = previousRatio // revert on 400/failure
            }
        }
    }

    // MARK: - Player plumbing (13-19 Task C0, extracted to EditorCompositionBuilder.swift in
    // Plan 13-21 F1): assembles ALL clips into ONE AVMutableComposition for real back-to-back
    // playback (analog: FullScreenVideoPlayerView's AVPlayer setup, no pan-to-dismiss/zoom here).
    // Text/caption overlays stay synced to state.currentTime as separate SwiftUI layers on top
    // (already the case) — they are NOT baked into this live preview composition, matching the
    // plan's explicit out-of-scope note (that's Export's job). The SAME composition builder now
    // also backs the fullscreen player (FullscreenEditorPlayerView) — see
    // EditorCompositionBuilder.swift's KNOWN LIMITATION doc comment for the image-clip caveat.

    private func rebuildPlayer() async {
        tearDownPlayerObserverOnly()
        guard let (composition, ranges) = await EditorCompositionBuilder.build(clips: state.project.clips) else { return }
        clipRanges = ranges

        let item = AVPlayerItem(asset: composition)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                // i4.2 (Plan 13-20): the divider can never read before 00:00 or past the total —
                // state.seek and the scrub gesture already clamp; this closes the last gap
                // (periodic playback writes were unclamped).
                state.currentTime = min(max(time.seconds, 0), state.totalDuration)
                if state.isPlaying, time.seconds >= currentPlayEnd - 0.05 {
                    state.isPlaying = false
                }
            }
        }

        let seekTime = CMTime(seconds: state.currentTime, preferredTimescale: 600)
        await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if state.isPlaying {
            currentPlayEnd = computePlayEnd()
            avPlayer.play()
        }
    }

    /// Play-range end for the CURRENT selection (13-19 Task C0, exact user spec): nothing selected
    /// plays to the end of the whole timeline; a selected clip plays only to that clip's own end
    /// (its start, if the playhead needed to snap there, was already applied by
    /// TimelineTrackView.selectClip at SELECTION time — this only resolves the END boundary).
    private func computePlayEnd() -> Double {
        if case .clip(let id) = state.selection, let range = clipRanges.first(where: { $0.clipId == id }) {
            return range.end
        }
        return state.totalDuration
    }

    private func duration(of clip: ProjectClip) -> Double {
        EditorCompositionBuilder.duration(of: clip)
    }

    /// i5.3: the image clip (if any) whose [start, end) range the playhead currently sits inside,
    /// resolved from `clipRanges` (the same cumulative-duration windows `buildComposition` already
    /// computes) — nil for video clips or when the playhead is outside every clip's range.
    private var currentImageClipURL: URL? {
        guard let range = clipRanges.first(where: { state.currentTime >= $0.start && state.currentTime < $0.end }),
              let clip = state.project.clips.first(where: { $0.id == range.clipId }),
              clip.mediaType == "image",
              let urlString = clip.url,
              let url = URL(string: urlString) else { return nil }
        return url
    }

    private func tearDownPlayerObserverOnly() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
    }

    private func tearDownPlayer() {
        tearDownPlayerObserverOnly()
        titleErrorClearTask?.cancel()
        exportToastTask?.cancel()
        barToastTask?.cancel()
    }

    // MARK: - Bottom bar: default-bar actions (13-19 Task A)

    private var hasCaptionableMedia: Bool {
        state.project.clips.contains { $0.mediaType == "video" }
    }

    /// "Edit" (default bar) = select the clip currently under the playhead — no-op if there are
    /// no clips. Reuses the same cumulative-duration walk CaptionTrackRow.clipIdUnderPlayhead()
    /// and TimelineTrackView's clip helpers already do.
    private func selectClipUnderPlayhead() {
        let clips = state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
        guard !clips.isEmpty else { return }
        var acc = 0.0
        for clip in clips {
            let dur = duration(of: clip)
            if state.currentTime < acc + dur {
                state.select(.clip(clip.id))
                return
            }
            acc += dur
        }
        if let last = clips.last { state.select(.clip(last.id)) }
    }

    /// "Text" (default bar) — the exact canonical add TextOverlayTrackRow's row-level "+" used to
    /// make (now removed from that row per Task E; this is its sole surviving call site).
    private func addDefaultTextOverlay() async {
        let start = state.currentTime, end = state.currentTime + 3
        let idsBefore = Set(state.project.textOverlays.map(\.id))
        do {
            try await projectManager.addTextOverlay(
                text: "Text", xNorm: 0.5, yNorm: 0.5, startSeconds: start, endSeconds: end
            )
            syncProjectFromManager()
            // F8: "add" record — undo deletes the just-created row; redo re-creates it (gets a
            // NEW server id each time, tracked via this shared `var` so a later undo still
            // targets whatever id is currently live).
            if var newId = Set(state.project.textOverlays.map(\.id)).subtracting(idsBefore).first {
                state.history.record(UndoableAction(
                    label: "Add text",
                    undo: { try await projectManager.deleteTextOverlay(textId: newId) },
                    redo: {
                        try await projectManager.addTextOverlay(
                            text: "Text", xNorm: 0.5, yNorm: 0.5, startSeconds: start, endSeconds: end
                        )
                        if let recreated = projectManager.loadedProject?.textOverlays.last { newId = recreated.id }
                    }
                ))
            }
        } catch {
            print("[EditorView] addDefaultTextOverlay error: \(error)")
        }
    }

    /// "Captions" (default bar) — disabled state is enforced by EditorBottomBar itself
    /// (`hasCaptionableMedia`); this is only reachable when enabled. Empty track → auto-generate
    /// from the video clip under the playhead (fallback: first video clip); non-empty → open the
    /// existing Caption Style sheet.
    private func handleCaptionsAction() {
        guard hasCaptionableMedia else { return }
        if state.project.captionCues.isEmpty {
            autoGenerateCaptionsFromPlayhead()
        } else {
            showCaptionStyleSheet = true
        }
    }

    private func autoGenerateCaptionsFromPlayhead() {
        guard let clipId = videoClipIdUnderPlayheadOrFirst() else { return }
        isCaptionsBusy = true
        let idsBefore = Set(state.project.captionCues.map(\.id))
        Task {
            do {
                try await projectManager.autoGenerateCaptions(clipId: clipId)
                syncProjectFromManager()
                // F8: bulk "add" — undo deletes every newly-created cue; redo re-creates them
                // from the captured field snapshot (not by re-running transcription, which isn't
                // guaranteed deterministic).
                let newCues = state.project.captionCues.filter { !idsBefore.contains($0.id) }
                if !newCues.isEmpty {
                    state.history.record(UndoableAction(
                        label: "Auto-generate captions",
                        undo: {
                            for cue in newCues { try await projectManager.deleteCaptionCue(cueId: cue.id) }
                        },
                        redo: {
                            for cue in newCues {
                                try await projectManager.addCaptionCue(
                                    startSeconds: cue.startSeconds, endSeconds: cue.endSeconds, words: cue.words
                                )
                            }
                        }
                    ))
                }
            } catch {
                print("[EditorView] autoGenerateCaptions error: \(error)")
                showBarToast("Couldn't generate captions")
            }
            isCaptionsBusy = false
        }
    }

    private func videoClipIdUnderPlayheadOrFirst() -> String? {
        let clips = state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
        var acc = 0.0
        for clip in clips {
            let dur = duration(of: clip)
            if state.currentTime < acc + dur, clip.mediaType == "video" { return clip.id }
            acc += dur
        }
        return clips.first(where: { $0.mediaType == "video" })?.id
    }

    // MARK: - Bottom bar: contextual actions (13-19 Task A/F)

    /// Split — dispatches per selected-asset type. Converts the GLOBAL playhead time into the
    /// asset's own LOCAL time first (cumulative-duration walk for clips; startOffsetSeconds-
    /// relative for audio; text overlays are already timed on the global timeline directly).
    // F8 (Plan 13-21): splits record a COMPOSITE undo (delete the new piece + PATCH the
    // original's trim back) / redo (restore the new piece + re-PATCH the original's trim). The
    // new piece's id isn't in either split API response (ProjectManager discards it and refetches
    // — see splitClip's/splitAudioClip's doc comments), so it's resolved by diffing the clip/audio
    // id sets before vs. after the refresh.
    private func performSplit() {
        switch state.selection {
        case .clip(let id):
            guard let localSeconds = localSplitSeconds(forClipId: id) else {
                showBarToast("Nothing to split")
                return
            }
            guard let originalClip = state.project.clips.first(where: { $0.id == id }) else { return }
            let originalTrimEndBefore = originalClip.trimEndSeconds ?? originalClip.originalDurationSeconds
            let idsBefore = Set(state.project.clips.map(\.id))
            Task {
                do {
                    let didSplit = try await projectManager.splitClip(clipId: id, atLocalSeconds: localSeconds)
                    if didSplit {
                        syncProjectFromManager()
                        showBarToast("Split")
                        let idsAfter = Set(state.project.clips.map(\.id))
                        if let newClipId = idsAfter.subtracting(idsBefore).first {
                            state.history.record(UndoableAction(
                                label: "Split clip",
                                undo: {
                                    try await projectManager.deleteClip(clipId: newClipId)
                                    if let end = originalTrimEndBefore {
                                        try await projectManager.updateClip(clipId: id, trimEnd: end)
                                    }
                                },
                                redo: {
                                    try await projectManager.restoreClip(clipId: newClipId)
                                    try await projectManager.updateClip(clipId: id, trimEnd: localSeconds)
                                }
                            ))
                        }
                    } else {
                        showBarToast("Nothing to split")
                    }
                } catch {
                    print("[EditorView] splitClip error: \(error)")
                    showBarToast("Couldn't split")
                }
            }
        case .text(let id):
            guard let originalOverlay = state.project.textOverlays.first(where: { $0.id == id }) else { return }
            let originalEndBefore = originalOverlay.endSeconds
            let splitPoint = state.currentTime
            let idsBefore = Set(state.project.textOverlays.map(\.id))
            Task {
                do {
                    let didSplit = try await projectManager.splitTextOverlay(textId: id, atLocalSeconds: splitPoint)
                    if didSplit {
                        syncProjectFromManager()
                        let idsAfter = Set(state.project.textOverlays.map(\.id))
                        if let newTextId = idsAfter.subtracting(idsBefore).first {
                            // Text has no soft-delete — undo = delete the new piece + PATCH the
                            // original's end back; redo = re-create it via a fresh split (same
                            // math, deterministic from the same captured fields).
                            state.history.record(UndoableAction(
                                label: "Split text",
                                undo: {
                                    try await projectManager.deleteTextOverlay(textId: newTextId)
                                    try await projectManager.updateTextOverlay(textId: id, endSeconds: originalEndBefore)
                                },
                                redo: {
                                    try await projectManager.updateTextOverlay(textId: id, endSeconds: splitPoint)
                                    try await projectManager.addTextOverlay(
                                        text: originalOverlay.text, xNorm: originalOverlay.xNorm, yNorm: originalOverlay.yNorm,
                                        widthNorm: originalOverlay.widthNorm, rotation: originalOverlay.rotation,
                                        startSeconds: splitPoint, endSeconds: originalEndBefore
                                    )
                                }
                            ))
                        }
                    }
                    showBarToast(didSplit ? "Split" : "Nothing to split")
                } catch {
                    print("[EditorView] splitTextOverlay error: \(error)")
                    showBarToast("Couldn't split")
                }
            }
        case .audio(let id):
            guard let localSeconds = localSplitSeconds(forAudioId: id) else {
                showBarToast("Nothing to split")
                return
            }
            guard let originalAudio = state.project.audioClips.first(where: { $0.id == id }) else { return }
            let originalTrimEndBefore = originalAudio.trimEndSeconds ?? originalAudio.originalDurationSeconds
            let idsBefore = Set(state.project.audioClips.map(\.id))
            Task {
                do {
                    let didSplit = try await projectManager.splitAudioClip(audioId: id, atLocalSeconds: localSeconds)
                    if didSplit {
                        syncProjectFromManager()
                        showBarToast("Split")
                        let idsAfter = Set(state.project.audioClips.map(\.id))
                        if let newAudioId = idsAfter.subtracting(idsBefore).first {
                            state.history.record(UndoableAction(
                                label: "Split audio",
                                undo: {
                                    try await projectManager.deleteAudioClip(audioId: newAudioId)
                                    if let end = originalTrimEndBefore {
                                        try await projectManager.updateAudioClip(audioId: id, trimEndSeconds: end)
                                    }
                                },
                                redo: {
                                    try await projectManager.restoreAudioClip(audioId: newAudioId)
                                    try await projectManager.updateAudioClip(audioId: id, trimEndSeconds: localSeconds)
                                }
                            ))
                        }
                    } else {
                        showBarToast("Nothing to split")
                    }
                } catch {
                    print("[EditorView] splitAudioClip error: \(error)")
                    showBarToast("Couldn't split")
                }
            }
        case .caption, .none:
            break // no Split on captions/nothing selected, per user decision
        }
    }

    private func localSplitSeconds(forClipId id: String) -> Double? {
        let clips = state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
        guard let clip = clips.first(where: { $0.id == id }) else { return nil }
        var acc = 0.0
        for c in clips {
            if c.id == id {
                return clip.trimStartSeconds + (state.currentTime - acc)
            }
            acc += duration(of: c)
        }
        return nil
    }

    private func localSplitSeconds(forAudioId id: String) -> Double? {
        guard let clip = state.project.audioClips.first(where: { $0.id == id }) else { return nil }
        return clip.trimStartSeconds + (state.currentTime - clip.startOffsetSeconds)
    }

    /// Delete/Remove — the contextual bar's Delete (clip/caption) and Remove (text/audio) both
    /// route here, matching the copy strings each track row's own inline delete already uses.
    // F8 (Plan 13-21): every delete records an UndoableAction. Clips/audio soft-delete
    // server-side (B1) — undo = POST …/restore, redo = soft-delete again, SAME id throughout (the
    // row is never actually re-created). Text/caption have no soft-delete — undo = re-create from
    // the captured fields (the re-created row gets a NEW server id, tracked in a local `var` the
    // undo/redo closures share by reference), redo = delete whatever id is currently live.
    private func deleteSelected() {
        switch state.selection {
        case .clip(let id):
            Task {
                do {
                    try await projectManager.deleteClip(clipId: id)
                    state.select(.none)
                    syncProjectFromManager()
                    showBarToast("Clip deleted")
                    state.history.record(UndoableAction(
                        label: "Delete clip",
                        undo: { try await projectManager.restoreClip(clipId: id) },
                        redo: { try await projectManager.deleteClip(clipId: id) }
                    ))
                } catch {
                    print("[EditorView] deleteClip error: \(error)")
                }
            }
        case .text(let id):
            guard let overlay = state.project.textOverlays.first(where: { $0.id == id }) else { return }
            Task {
                do {
                    try await projectManager.deleteTextOverlay(textId: id)
                    state.select(.none)
                    syncProjectFromManager()
                    showBarToast("Text removed")
                    var currentId = id
                    state.history.record(UndoableAction(
                        label: "Delete text",
                        undo: {
                            try await projectManager.addTextOverlay(
                                text: overlay.text, xNorm: overlay.xNorm, yNorm: overlay.yNorm,
                                widthNorm: overlay.widthNorm, rotation: overlay.rotation,
                                startSeconds: overlay.startSeconds, endSeconds: overlay.endSeconds
                            )
                            if let recreated = projectManager.loadedProject?.textOverlays.last {
                                currentId = recreated.id
                            }
                        },
                        redo: { try await projectManager.deleteTextOverlay(textId: currentId) }
                    ))
                } catch {
                    print("[EditorView] deleteTextOverlay error: \(error)")
                }
            }
        case .audio(let id):
            Task {
                do {
                    try await projectManager.deleteAudioClip(audioId: id)
                    state.select(.none)
                    syncProjectFromManager()
                    showBarToast("Audio removed")
                    state.history.record(UndoableAction(
                        label: "Delete audio",
                        undo: { try await projectManager.restoreAudioClip(audioId: id) },
                        redo: { try await projectManager.deleteAudioClip(audioId: id) }
                    ))
                } catch {
                    print("[EditorView] deleteAudioClip error: \(error)")
                }
            }
        case .caption(let id):
            guard let cue = state.project.captionCues.first(where: { $0.id == id }) else { return }
            Task {
                do {
                    try await projectManager.deleteCaptionCue(cueId: id)
                    state.select(.none)
                    syncProjectFromManager()
                    showBarToast("Caption removed")
                    var currentId = id
                    state.history.record(UndoableAction(
                        label: "Delete caption",
                        undo: {
                            try await projectManager.addCaptionCue(
                                startSeconds: cue.startSeconds, endSeconds: cue.endSeconds, words: cue.words
                            )
                            if let recreated = projectManager.loadedProject?.captionCues.last {
                                currentId = recreated.id
                            }
                        },
                        redo: { try await projectManager.deleteCaptionCue(cueId: currentId) }
                    ))
                } catch {
                    print("[EditorView] deleteCaptionCue error: \(error)")
                }
            }
        case .none:
            break
        }
    }

    /// Text "Edit" — signals TextOverlayItemView (via EditorState.editRequestedTextId) to enter
    /// the same inline edit mode its own ✎ corner button triggers.
    private func requestEditSelectedText() {
        if case .text(let id) = state.selection { state.editRequestedTextId = id }
    }

    /// Caption "Edit" — signals CaptionTrackRow (via EditorState.editRequestedCaptionId) to enter
    /// the same inline edit mode its own pill's edit toggle triggers.
    private func requestEditSelectedCaption() {
        if case .caption(let id) = state.selection { state.editRequestedCaptionId = id }
    }

    /// Text "Duplicate" — same call TextOverlayCanvasView's ⧉ corner button already makes.
    private func duplicateSelectedText() async {
        guard case .text(let id) = state.selection,
              let overlay = state.project.textOverlays.first(where: { $0.id == id }) else { return }
        let newXNorm = min(0.94, overlay.xNorm + 0.04)
        let newYNorm = min(0.94, overlay.yNorm + 0.04)
        let idsBefore = Set(state.project.textOverlays.map(\.id))
        do {
            try await projectManager.addTextOverlay(
                text: overlay.text,
                xNorm: newXNorm,
                yNorm: newYNorm,
                widthNorm: overlay.widthNorm,
                rotation: overlay.rotation,
                startSeconds: overlay.startSeconds,
                endSeconds: overlay.endSeconds
            )
            syncProjectFromManager()
            showBarToast("Text duplicated")
            if var newId = Set(state.project.textOverlays.map(\.id)).subtracting(idsBefore).first {
                state.history.record(UndoableAction(
                    label: "Duplicate text",
                    undo: { try await projectManager.deleteTextOverlay(textId: newId) },
                    redo: {
                        try await projectManager.addTextOverlay(
                            text: overlay.text, xNorm: newXNorm, yNorm: newYNorm, widthNorm: overlay.widthNorm,
                            rotation: overlay.rotation, startSeconds: overlay.startSeconds, endSeconds: overlay.endSeconds
                        )
                        if let recreated = projectManager.loadedProject?.textOverlays.last { newId = recreated.id }
                    }
                ))
            }
        } catch {
            print("[EditorView] duplicateSelectedText error: \(error)")
        }
    }

    // MARK: - Shared reconciliation/toast (mirrors TimelineTrackView/AudioTrackRow's identical
    // syncProjectFromManager()/showToast() helpers — EditorState "owns playback/selection state,
    // not persistence" per its own doc comment, so every mutation site is responsible for
    // reflecting ProjectManager's persisted result back onto the shared clock).

    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }

    private func showBarToast(_ message: String) {
        barToastMessage = message
        barToastTask?.cancel()
        barToastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            barToastMessage = nil
        }
    }
}
