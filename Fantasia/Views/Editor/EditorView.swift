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
// generation_id is registered immediately with the EXISTING GenerationManager poll loop. The
// editor keeps that exact id attached to an export-status sheet, which becomes the normal result
// surface with Share and Save to Photos when processing completes.

import SwiftUI
import AVFoundation
import QuartzCore

struct EditorView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(\.dismiss) private var dismiss

    @State private var state: EditorState
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?
    @State private var playerItemStatusObservation: NSKeyValueObservation?
    @State private var playerItemFailureObservation: NSObjectProtocol?
    @State private var playerRebuildGeneration: UInt = 0
    @State private var playerVideoOutput: AVPlayerItemVideoOutput?
    @State private var usesComposedVideoOutput = false
    @State private var previewSurfaceReady = false
    @State private var videoOutputRenderer = EditorVideoOutputRenderer()
    @State private var videoOutputReadinessObserver = EditorVideoOutputReadinessObserver()
    @State private var scrubSeekInFlight = false
    @State private var pendingScrubTarget: Double?
    @State private var slowScrubMode = false
    @State private var pendingScrubLandingTarget: Double?
    @State private var scrubSessionGeneration: UInt = 0
    @State private var scrubLandingRequestVersion: UInt = 0
    @State private var scrubFrameLadder = ScrubFrameLadder()
    @State private var showsScrubFrame = false

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleError: String?
    @State private var titleErrorClearTask: Task<Void, Never>?

    @State private var isExporting = false
    @State private var exportToastMessage: String?
    @State private var exportToastTask: Task<Void, Never>?
    @State private var exportFailedError: String?
    @State private var trackedExportGenerationId: String?
    @State private var showExportStatus = false

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
    @State private var didAttemptCachePurge = false

    // Forced-dark palette (13-UI-SPEC.md Color contract) — NOT theme.background/theme.surface.
    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051)   // #0A0A0D
    private let previewStageBackground = Color(red: 0.047, green: 0.047, blue: 0.067) // #0C0C11
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)                 // #8C59FF
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)          // #FF5470

    private static let aspectOptions: [String] = ["original", "9:16", "4:5", "1:1", "16:9"]

    // 13-22 i1: resolved fraction for the "Original" canvas aspect — the first (sortOrder) clip's
    // EXACT native ratio, not snapped to a preset. Cached here (recomputed whenever
    // state.project.clips changes, alongside rebuildPlayer) rather than resolved synchronously in
    // the view body, since the fallback path needs an async AVAsset track load.
    @State private var originalAspectFraction: CGFloat = 9.0 / 16.0

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
            .onChange(of: state.isScrubbing) { _, isScrubbing in
                if isScrubbing {
                    // A new generation prevents an older gesture's slow seek completion from
                    // leaking adaptive tolerance into this drag.
                    scrubSessionGeneration &+= 1
                    scrubLandingRequestVersion &+= 1
                    slowScrubMode = false
                    pendingScrubLandingTarget = nil
                    showsScrubFrame = true
                    return
                }
                slowScrubMode = false
                pendingScrubTarget = nil
                // 13-26 M4: exact-landing seek — nudge off a clip boundary if the scrub ended
                // right on one (see EditorState.displayTime's doc comment). If a mid-drag seek is
                // still decoding, queue this behind it so that older completion cannot overwrite
                // the precise landing frame.
                requestPreciseScrubLanding(at: state.displayTime(for: state.currentTime))
            }
            .onChange(of: state.project.clips) { _, _ in Task { await rebuildPlayer() } }
            // Plan 13-26 M1 Fix A: cache-first open (ProjectManager.openProjectFromCache) hands
            // this view a snapshot whose presigned URLs may already be >1h expired; the
            // background refreshLoadedProjectURLs() (kicked right after) updates
            // projectManager.loadedProject but nothing previously synced that back into
            // state.project — the editor never healed until some UNRELATED mutation happened to
            // call syncProjectFromManager(). This bridges it: any external change to
            // loadedProject (background refresh, or another screen mutating the same project)
            // reflects into state.project, and the existing clips onChange above rebuilds the
            // player once the fresh URLs land.
            .onChange(of: projectManager.loadedProject) { _, refreshed in
                guard let refreshed, refreshed.id == state.project.id else { return }
                state.project = refreshed
            }
            // 13-23 J4: the videoComposition's renderSize derives from the project aspect — cycling
            // the aspect toggle must rebuild the player item so the canvas shape follows.
            .onChange(of: state.aspectRatio) { _, _ in Task { await rebuildPlayer() } }
            .sheet(isPresented: $showAddAudioSheet) {
                // F8 (Plan 13-21): idsBefore snapshots at PRESENTATION time (this closure runs once
                // per sheet presentation) — onAdded diffs against it to find the newly-added row
                // and records an "add" UndoableAction (undo = soft-delete, redo = restore).
                let idsBefore = Set(state.project.audioClips.map(\.id))
                AddAudioSheet(currentTime: state.currentTime, totalDuration: state.totalDuration, onAdded: {
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
            // 13-22 i6.1: fullscreen now shares this SAME AVPlayer instance (no more separate
            // composition/player pair to reconcile) — the inline surface is simply occluded
            // behind the fullScreenCover the whole time and keeps ticking its own periodic
            // observer regardless of which surface is visible, so there is nothing to pause or
            // reconcile on open/minimize anymore (see FullscreenEditorPlayerView's file header).
            .fullScreenCover(isPresented: $showFullscreenPlayer) {
                FullscreenEditorPlayerView(
                    state: state,
                    player: player,
                    usesComposedVideoOutput: usesComposedVideoOutput,
                    videoOutputRenderer: videoOutputRenderer,
                    // Item 4 (round 2, Andrew review 2026-07-17): the SAME aspect fraction
                    // previewStage below already fits its own overlay layers to — passed through
                    // so FullscreenEditorPlayerView's overlay rect is byte-for-byte identical,
                    // never a second independent derivation. See that view's file header.
                    aspectFraction: aspectFraction(state.aspectRatio),
                    onMinimize: { showFullscreenPlayer = false },
                    // Item 5: FullscreenEditorPlayerView's own TextOverlayCanvasView mount already
                    // has `.allowsHitTesting(false)` (it's a preview-only surface — no move/resize/
                    // rotate/edit can actually fire there), so this is inert today, kept only for
                    // API consistency in case that ever changes. If it ever DID fire, note
                    // EditorView's barToastOverlay renders BEHIND this fullScreenCover while
                    // presented, so the toast wouldn't be visible until minimized back.
                    onError: { showBarToast($0) }
                )
            }
            .sheet(isPresented: $showCaptionStyleSheet) {
                CaptionStyleSheet(state: state)
            }
            .sheet(isPresented: $showExportStatus) {
                if let generationId = trackedExportGenerationId {
                    EditorExportStatusSheet(generationId: generationId, isPresented: $showExportStatus)
                }
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
                },
                onError: { showBarToast($0) }
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
            onEditCaption: requestEditSelectedCaption,
            onDeleteAllCaptions: requestDeleteAllCaptions
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

    // Task C / 13-25 L4: seek-on-scrub. Compares against the PLAYER's own current time rather than
    // a "player-originated write" boolean flag — the periodic time observer's own writes always
    // land within epsilon of the player's actual position, so only a genuine external scrub
    // (timeline drag) triggers a seek.
    //
    // Scrub seeks are serialized rather than cancelled: every issued seek gets a chance to render,
    // while unissued drag samples coalesce into one latest target. Exact seeks are preferred until
    // a long-GOP source proves slow, then the rest of that drag uses keyframe-friendly tolerance.
    // The final exact landing is serialized behind any active mid-drag seek.
    private func handleScrubSeek(_ newValue: Double) {
        guard let player else { return }
        let playerSeconds = player.currentTime().seconds
        guard playerSeconds.isFinite else { return }
        if state.isScrubbing {
            pendingScrubTarget = newValue
            // Preserve a near-current latest target while an older seek is active: after that
            // older seek lands, this target may no longer be near the player's actual position.
            guard scrubSeekInFlight || abs(playerSeconds - newValue) >= 0.02 else {
                pendingScrubTarget = nil
                return
            }
            drainScrubSeeks()
        } else if abs(playerSeconds - newValue) > 0.15 {
            // 13-26 M4: exact-landing seek — same boundary nudge as the isScrubbing→false path;
            // this is the OTHER caller that can land here (for example, snapPlayhead).
            let preciseTarget = CMTime(seconds: state.displayTime(for: newValue), preferredTimescale: 600)
            player.seek(to: preciseTarget, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func drainScrubSeeks() {
        guard !scrubSeekInFlight else { return }
        guard state.isScrubbing else {
            finishPreciseScrubLandingIfPossible()
            return
        }
        guard let targetSeconds = pendingScrubTarget, let player else { return }

        let playerSeconds = player.currentTime().seconds
        if playerSeconds.isFinite, abs(playerSeconds - targetSeconds) < 0.02 {
            pendingScrubTarget = nil
            return
        }

        pendingScrubTarget = nil
        scrubSeekInFlight = true
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let tolerance = slowScrubMode
            ? CMTime(seconds: 0.35, preferredTimescale: 600)
            : .zero
        let started = CACurrentMediaTime()
        let seekPlayer = player
        let seekSessionGeneration = scrubSessionGeneration
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
            Task { @MainActor in
                guard self.player === seekPlayer else {
                    scrubSeekInFlight = false
                    if state.isScrubbing {
                        drainScrubSeeks()
                    } else {
                        finishPreciseScrubLandingIfPossible()
                    }
                    return
                }
                if seekSessionGeneration == scrubSessionGeneration,
                   state.isScrubbing,
                   CACurrentMediaTime() - started > 0.25 {
                    slowScrubMode = true
                }
                scrubSeekInFlight = false
                if state.isScrubbing {
                    drainScrubSeeks()
                } else {
                    finishPreciseScrubLandingIfPossible()
                }
            }
        }
    }

    private func requestPreciseScrubLanding(at targetSeconds: Double) {
        scrubLandingRequestVersion &+= 1
        pendingScrubLandingTarget = targetSeconds
        finishPreciseScrubLandingIfPossible()
    }

    private func finishPreciseScrubLandingIfPossible() {
        guard !scrubSeekInFlight,
              !state.isScrubbing,
              let targetSeconds = pendingScrubLandingTarget,
              let player
        else { return }

        pendingScrubLandingTarget = nil
        scrubSeekInFlight = true
        let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let seekPlayer = player
        let landingVersion = scrubLandingRequestVersion
        let landingSession = scrubSessionGeneration
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                guard self.player === seekPlayer else {
                    scrubSeekInFlight = false
                    if landingVersion == scrubLandingRequestVersion,
                       landingSession == scrubSessionGeneration,
                       pendingScrubLandingTarget == nil {
                        // The active seek belonged to the player that was just replaced. Preserve
                        // its still-current target exactly once; never overwrite a newer landing.
                        pendingScrubLandingTarget = targetSeconds
                    }
                    finishPreciseScrubLandingIfPossible()
                    return
                }
                scrubSeekInFlight = false
                if state.isScrubbing {
                    drainScrubSeeks()
                } else if landingVersion == scrubLandingRequestVersion,
                          landingSession == scrubSessionGeneration,
                          finished {
                    // Keep the ladder visible until this exact seek completion, avoiding a flash
                    // of the player's stale pre-scrub frame during the handoff.
                    showsScrubFrame = false
                    if state.isPlaying { player.play() }
                } else if landingVersion == scrubLandingRequestVersion,
                          landingSession == scrubSessionGeneration {
                    // AVPlayer reports false when another operation interrupts the exact seek.
                    // Retain the ladder and retry only the still-current landing request.
                    pendingScrubLandingTarget = targetSeconds
                    finishPreciseScrubLandingIfPossible()
                } else {
                    // A newer landing was queued while this seek was in flight. Its request owns
                    // the ladder now, so immediately drain that latest target.
                    finishPreciseScrubLandingIfPossible()
                }
            }
        }
    }

    private func handlePlayingChange(_ isPlaying: Bool) {
        if isPlaying {
            currentPlayEnd = computePlayEnd()
            player?.play()
#if DEBUG
            if let player {
                let waitingReason = player.reasonForWaitingToPlay?.rawValue ?? "nil"
                print(
                    "[EditorView] play requested: timeControlStatus=\(player.timeControlStatus.rawValue) "
                    + "waitingReason=\(waitingReason)"
                )
            }
#endif
        } else {
            player?.pause()
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
                let generationId = try await projectManager.exportProject(id: state.project.id)
                generationManager.registerPendingExport(id: generationId, aspectRatio: state.aspectRatio)
                trackedExportGenerationId = generationId
                isExporting = false
                showExportStatus = true
                showExportToast("Export started — share or save it here when it’s ready.")
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
            let ratio = aspectFraction(state.aspectRatio)
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
                    if usesComposedVideoOutput {
                        EditorVideoOutputView(renderer: videoOutputRenderer)
                    } else {
                        FillingVideoPlayerView(
                            player: player,
                            videoGravity: .resizeAspect,
                            onReadyForDisplay: {
                                guard self.player === player else { return }
                                previewSurfaceReady = true
                            }
                        )
                    }
                } else {
                    Color.black
                }
                if !previewSurfaceReady {
                    Color.black
                    if let urlString = state.project.thumbnailUrl, let url = URL(string: urlString) {
                        LetterboxThumbnailView(
                            url: url,
                            cacheKey: "project-cover-\(state.project.id)-\(url.lastPathComponent)"
                        ) {
                            Color.black
                        }
                        .opacity(0.78)
                    }
                    if player == nil {
                        ProgressView()
                            .tint(.white)
                            .accessibilityLabel("Loading project preview")
                    }
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
                            Color.clear
                        }
                    }
                }
                // Q1: the dense source-frame ladder is the visible scrub path. Serialized player
                // seeks continue underneath so the final precise handoff starts nearby.
                if showsScrubFrame,
                   let scrubFrame = scrubFrameLadder.frame(
                    project: state.project.clips,
                    at: state.currentTime,
                    ranges: clipRanges
                   ) {
                    Color.black
                    Image(uiImage: scrubFrame)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
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
                // Plan 13: on-video Text overlays (SC3), sized to the same letterboxed canvas
                // frame the AVPlayer surface renders in so overlay coordinates line up 1:1.
                // 13-22 i7.1: NO `.clipShape` here (unlike the video/caption layers) — the
                // rotation handle ALWAYS extends above a selected box, and corner buttons clip
                // too near the edges; text controls may draw over the letterbox bars, exactly like
                // CapCut. This was the actual root cause of "rotation dot invisible."
                // Item 5 (Andrew review, 2026-07-17): wired to the same showBarToast surface every
                // other track row's onError already uses — TextOverlayCanvasView's move/resize/
                // rotate/edit/delete/duplicate failures were previously silent (print-only).
                TextOverlayCanvasView(state: state, onError: { showBarToast($0) })
                    .frame(width: size.width, height: size.height)
            }
            .overlay {
                // Plan 16: live karaoke captions (SC5's render half — Delta 6), same letterboxed
                // canvas frame as the Text overlay layer above so both sit in the same coordinate
                // space as the AVPlayer surface. Item 3 (Andrew review, 2026-07-17): no longer
                // read-only — draggable vertically here (isDraggable defaults true for this
                // inline mount); FullscreenEditorPlayerView passes isDraggable: false to keep its
                // own mount preview-only.
                CaptionOverlayView(state: state)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(previewStageBackground)
    }

    // 13-22 i1: "original" resolves to the first clip's exact native ratio via
    // `originalAspectFraction` (kept fresh by refreshOriginalAspectFraction(), called alongside
    // rebuildPlayer() below). Every fixed preset is unchanged.
    private func aspectFraction(_ ratio: String) -> CGFloat {
        switch ratio {
        case "original": return originalAspectFraction
        case "9:16": return 9.0 / 16.0
        case "4:5": return 4.0 / 5.0
        case "1:1": return 1.0
        case "16:9": return 16.0 / 9.0
        default: return 9.0 / 16.0
        }
    }

    /// Resolves `originalAspectFraction` from the FIRST (sortOrder) clip's stored pixel
    /// width/height (B1, self-healed server-side) — the common, synchronous-fast case. Falls back
    /// to reading that clip's own AVAsset video track `naturalSize` (rotation-corrected via
    /// `preferredTransform`) for the narrow race where width/height haven't been probed yet; falls
    /// back to 9:16 if neither resolves (e.g. an all-image project whose asset has no video track).
    private func refreshOriginalAspectFraction() async {
        let sorted = state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
        guard let first = sorted.first else {
            originalAspectFraction = 9.0 / 16.0
            return
        }
        if let w = first.width, let h = first.height, h > 0 {
            originalAspectFraction = CGFloat(w) / CGFloat(h)
            return
        }
        guard first.mediaType == "video", let urlString = first.url, let url = URL(string: urlString) else {
            originalAspectFraction = 9.0 / 16.0
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else {
            originalAspectFraction = 9.0 / 16.0
            return
        }
        let size = naturalSize.applying(transform)
        let width = abs(size.width), height = abs(size.height)
        originalAspectFraction = height > 0 ? width / height : 9.0 / 16.0
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
                // 13-22 i1.2: shows "Original" (text, not a ratio) when in original mode.
                Text(state.aspectRatio == "original" ? "Original" : state.aspectRatio)
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

            // 13-22 i8: ALWAYS rendered now (was hidden entirely via `if canUndo`/`if canRedo`,
            // which made the pair appear/disappear as history changed) — `.disabled` +
            // `.opacity` communicate availability instead, matching standard undo/redo
            // conventions: fresh project → both grayed; after an action → undo lit, redo grayed;
            // after an undo → both lit (redo lit only while redoable).
            Button {
                Task { await performUndo() }
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(state.history.canUndo ? 0.85 : 0.3))
                    .frame(width: 32, height: 32)
            }
            .disabled(!state.history.canUndo || state.history.isProcessing)
            .accessibilityLabel("Undo")

            Button {
                Task { await performRedo() }
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(state.history.canRedo ? 0.85 : 0.3))
                    .frame(width: 32, height: 32)
            }
            .disabled(!state.history.canRedo || state.history.isProcessing)
            .accessibilityLabel("Redo")
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
        playerRebuildGeneration &+= 1
        let rebuildGeneration = playerRebuildGeneration
        await refreshOriginalAspectFraction()
        guard rebuildGeneration == playerRebuildGeneration else { return }
        guard let (composition, videoComposition, ranges, isDegraded) = await EditorCompositionBuilder.build(
            clips: state.project.clips, aspectRatio: state.aspectRatio
        ) else { return }
        guard rebuildGeneration == playerRebuildGeneration else { return }
        if isDegraded, !didAttemptCachePurge {
            didAttemptCachePurge = true
            await ClipFileCache.shared.remove(clipIds: state.project.clips.map(\.id))
            guard rebuildGeneration == playerRebuildGeneration else { return }
            await projectManager.refreshLoadedProjectURLs()
            return
        }
        clipRanges = ranges
        scrubFrameLadder.warm(
            project: state.project.clips,
            ranges: ranges,
            at: state.currentTime
        )
        // 13-26 M4: every internal boundary except 0 and the final end — dropLast() removes the
        // LAST range (its .end IS the composition's total duration, explicitly excluded).
        state.clipBoundaries = ranges.dropLast().map(\.end)
        // 13-22 i3: the shared end-clamp's authoritative upper bound — the composition's REAL
        // duration, which can differ from state.totalDuration's logical sum by rounding/trim-math
        // slop. Every scrub/seek path now routes through state.clampTime(_:), which reads this.
        state.playableDuration = composition.duration.seconds

        let item = AVPlayerItem(asset: composition)
        // 13-23 J4: per-clip aspect-fit into the project canvas — a mixed-dimension clip renders
        // pillarboxed/letterboxed instead of stretched to the first clip's shape. Fullscreen
        // shares this same item (13-22 i6.1), so it inherits the treatment automatically.
        item.videoComposition = videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let avPlayer = AVPlayer(playerItem: item)
        // The editor composition is assembled entirely from validated local cache files. Waiting
        // to minimize network stalls can leave composition-backed playback parked indefinitely.
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        // Keep the existing surface alive while cache/composition work is in flight. The old
        // player and new player swap in one main-actor transaction, so a trim commit never
        // flashes through the nil-player placeholder.
        tearDownPlayerObserverOnly()
        videoOutputReadinessObserver.reset()
        previewSurfaceReady = false
        player = avPlayer
        playerVideoOutput = output
        usesComposedVideoOutput = false
        videoOutputRenderer.configure(player: avPlayer, output: output)
        observePlayerItemStatus(item, on: avPlayer)
        observePlayerItemFailure(item, on: avPlayer)

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                // i4.2 (Plan 13-20), extended 13-22 i3: the divider can never read before 00:00 or
                // past the composition's real playable end — playing/scrubbing to the end now
                // settles at `playableDuration - 0.03` and HOLDS that last frame instead of
                // seeking to/past the exact end (which renders as a black frame).
                state.currentTime = state.clampTime(time.seconds)
                if state.isPlaying, time.seconds >= currentPlayEnd - 0.05 {
                    state.isPlaying = false
                    // 13-26 M4: exact-landing seek — playback may have stopped a fraction of a
                    // second into the next clip's black boundary zone (the 0.1s periodic observer
                    // isn't frame-exact); land precisely on currentPlayEnd, nudged off a boundary
                    // if it sits on one, so the paused frame is always the earlier clip's last
                    // frame, never black.
                    let target = CMTime(seconds: state.displayTime(for: currentPlayEnd), preferredTimescale: 600)
                    player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }

        let seekTime = CMTime(seconds: state.currentTime, preferredTimescale: 600)
        await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        guard rebuildGeneration == playerRebuildGeneration, player === avPlayer else { return }
        // A precise scrub landing may have been requeued while this replacement player was being
        // assembled. Its mismatch callback could not drain with no current player, so guarantee a
        // handoff now that the replacement has been installed and primed.
        finishPreciseScrubLandingIfPossible()
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
        // 13-22 i3: clamp to the shared end-clamp bound, not the raw logical total — playing to
        // the very end of the whole timeline now settles at the last real frame instead of trying
        // to reach an exact boundary the composition may not have a frame for.
        return state.clampTime(state.totalDuration)
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

    private func observePlayerItemStatus(_ item: AVPlayerItem, on observedPlayer: AVPlayer) {
        playerItemStatusObservation = item.observe(\.status, options: [.new, .initial]) { item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor in
                    guard player === observedPlayer, observedPlayer.currentItem === item else { return }
                    // A custom videoComposition may not present its first frame until a seek is
                    // issued after readiness. This single exact seek primes the render pipeline.
                    let target = CMTime(seconds: state.currentTime, preferredTimescale: 600)
                    observedPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                        Task { @MainActor in
                            guard player === observedPlayer, observedPlayer.currentItem === item else { return }
                            if state.isPlaying { observedPlayer.play() }
                        }
                    }
                }
            case .failed:
                print("[EditorView] player item failed: \(String(describing: item.error))")
            default:
                break
            }
        }
    }

    /// AVPlayerLayer can fail to PRESENT a live mixed-format AVVideoComposition after the item is
    /// already ready, while AVPlayerItemVideoOutput still produces its correctly transformed
    /// frames. Switch surfaces in-place; never drop the videoComposition, because doing so
    /// stretches later portrait/landscape segments into the first clip's geometry.
    private func observePlayerItemFailure(_ item: AVPlayerItem, on observedPlayer: AVPlayer) {
        playerItemFailureObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { notification in
            let notificationErrorDescription = String(
                describing: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
            )
            Task { @MainActor in
                guard player === observedPlayer, observedPlayer.currentItem === item else { return }
                print(
                    "[EditorView] player item failed to play to end: "
                    + "notificationError=\(notificationErrorDescription) "
                    + "itemError=\(String(describing: item.error)) "
                    + "hasVideoComposition=\(item.videoComposition != nil)"
                )
                guard item.videoComposition != nil,
                      let playerVideoOutput,
                      !usesComposedVideoOutput
                else { return }
                previewSurfaceReady = false
                usesComposedVideoOutput = true
                videoOutputReadinessObserver.observe(playerVideoOutput) {
                    guard player === observedPlayer,
                          self.playerVideoOutput === playerVideoOutput
                    else { return }
                    previewSurfaceReady = true
                }
                videoOutputRenderer.configure(player: observedPlayer, output: playerVideoOutput)
                playerVideoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                let target = CMTime(seconds: state.currentTime, preferredTimescale: 600)
                observedPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor in
                        guard player === observedPlayer else { return }
                        if state.isPlaying { observedPlayer.play() }
                    }
                }
                print("[EditorView] activated composed-frame playback fallback")
            }
        }
    }

    private func tearDownPlayerObserverOnly() {
        playerItemStatusObservation = nil
        if let playerItemFailureObservation {
            NotificationCenter.default.removeObserver(playerItemFailureObservation)
        }
        playerItemFailureObservation = nil
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        playerVideoOutput = nil
        usesComposedVideoOutput = false
        previewSurfaceReady = false
        videoOutputReadinessObserver.reset()
        videoOutputRenderer.reset()
    }

    private func tearDownPlayer() {
        // Prevent a rebuild suspended in asset/cache work from installing a player after the view
        // has disappeared.
        playerRebuildGeneration &+= 1
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
    /// 13-26 M8.3: the new overlay auto-assigns to the LOWEST text row where
    /// [currentTime, currentTime + 3] doesn't overlap any existing overlay (possibly a brand-new
    /// row below the last), and that row is PERSISTED via row_index on the add call.
    private func addDefaultTextOverlay() async {
        let start = state.currentTime, end = state.currentTime + 3
        let row = lowestFreeTextRow(start: start, end: end)
        let idsBefore = Set(state.project.textOverlays.map(\.id))
        do {
            try await projectManager.addTextOverlay(
                text: "Text", xNorm: 0.5, yNorm: 0.5, rowIndex: row, startSeconds: start, endSeconds: end
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
                            text: "Text", xNorm: 0.5, yNorm: 0.5, rowIndex: row, startSeconds: start, endSeconds: end
                        )
                        if let recreated = projectManager.loadedProject?.textOverlays.last { newId = recreated.id }
                    }
                ))
            }
        } catch {
            print("[EditorView] addDefaultTextOverlay error: \(error)")
        }
    }

    /// 13-26 M8.3: lowest text row where [start, end] fits without overlapping any existing
    /// overlay's time range in that row — rows resolved via the SAME effectiveRows helper the
    /// track lays out with. May return one row below the current last (creates a new row).
    private func lowestFreeTextRow(start: Double, end: Double) -> Int {
        let rowsById = TextOverlayTrackRow.effectiveRows(for: state.project.textOverlays)
        var intervalsByRow: [Int: [(Double, Double)]] = [:]
        for overlay in state.project.textOverlays {
            intervalsByRow[rowsById[overlay.id] ?? 0, default: []].append((overlay.startSeconds, overlay.endSeconds))
        }
        var row = 0
        while (intervalsByRow[row] ?? []).contains(where: { start < $0.1 && end > $0.0 }) {
            row += 1
        }
        return row
    }

    /// "Captions" (default bar) — disabled state is enforced by EditorBottomBar itself
    /// (`hasCaptionableMedia`); this is only reachable when enabled. Empty track → auto-generate
    /// from the video clip under the playhead (fallback: first video clip); non-empty → open the
    /// existing Caption Style sheet.
    private func handleCaptionsAction() {
        guard hasCaptionableMedia else { return }
        guard !projectManager.isMutatingClips else {
            showBarToast("Finishing clip reorder…")
            return
        }
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

    /// Caption "Delete All" — signals CaptionTrackRow (via EditorState.deleteAllCaptionsRequested)
    /// to present the SAME bulk-delete confirmation its own long-press affordance already shows,
    /// which calls the SAME projectManager.deleteAllCaptions() (D-13) — no new deletion logic here.
    private func requestDeleteAllCaptions() {
        guard case .caption = state.selection else { return }
        state.deleteAllCaptionsRequested = true
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

/// The normal preview uses `AVPlayerLayer.isReadyForDisplay`. Compositor recovery renders from
/// `AVPlayerItemVideoOutput`, whose matching readiness contract is its pull delegate's media-data
/// callback. Retain this observer independently of the untracked renderer implementation.
@MainActor
private final class EditorVideoOutputReadinessObserver: NSObject, AVPlayerItemOutputPullDelegate {
    private weak var output: AVPlayerItemVideoOutput?
    private var onMediaDataReady: (() -> Void)?
    private let delegateQueue = DispatchQueue(label: "com.fantasia.editor-video-output-readiness")

    func observe(_ output: AVPlayerItemVideoOutput, onMediaDataReady: @escaping () -> Void) {
        reset()
        self.output = output
        self.onMediaDataReady = onMediaDataReady
        output.setDelegate(self, queue: delegateQueue)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
    }

    nonisolated func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        Task { @MainActor [weak self] in
            guard let self, sender === self.output else { return }
            let callback = self.onMediaDataReady
            self.onMediaDataReady = nil
            callback?()
        }
    }

    func reset() {
        output?.setDelegate(nil, queue: nil)
        output = nil
        onMediaDataReady = nil
    }
}

/// Keeps one Edit Studio export attached to its real generation id. Once the existing generation
/// poller marks that exact row complete, this swaps directly into the app's established result
/// surface, which already provides native Share and Save to Photos actions.
private struct EditorExportStatusSheet: View {
    let generationId: String
    @Binding var isPresented: Bool
    @Environment(GenerationManager.self) private var generationManager

    private var generation: GenerationItem? {
        generationManager.generations.first { $0.id == generationId }
    }

    var body: some View {
        Group {
            if let generation, generation.status == .completed {
                GenerationDetailSheet(item: generation, isPresented: $isPresented)
            } else if let generation,
                      generation.status == .failed || generation.status == .quarantined || generation.status == .refunded {
                statusContent(
                    icon: "exclamationmark.triangle",
                    title: "Export couldn’t finish",
                    message: generation.failureMessage ?? "Your project is unchanged. Close this and try exporting again."
                )
            } else {
                statusContent(
                    icon: nil,
                    title: "Exporting your video",
                    message: "You can keep editing or close this sheet. Share and Save to Photos will appear here when it’s ready."
                )
            }
        }
        .task { generationManager.startPolling(forceRefresh: true) }
    }

    private func statusContent(icon: String?, title: String, message: String) -> some View {
        ZStack(alignment: .topTrailing) {
            Color(red: 0.039, green: 0.039, blue: 0.051).ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 34))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
                Spacer()
            }
            .frame(maxWidth: .infinity)

            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.10), in: Circle())
            }
            .padding(18)
            .accessibilityLabel("Close export status")
        }
        .preferredColorScheme(.dark)
    }
}
