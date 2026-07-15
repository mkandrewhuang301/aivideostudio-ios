// TimelineTrackView.swift
// Fantasia
// Phase 13, Plan 12: the REAL filmstrip timeline — ruler, fixed-center playhead, background-scrub
// gesture, the clip row (ClipPillView per clip + inline "+" add-clip tile), and the stacked
// Text/Audio/Caption track-row mount points that plans 13-15 fill in. Replaces plan 11's
// TimelineMountView(state:) placeholder in EditorView.swift.
//
// Gesture mechanics reproduce Spike 001 verbatim (.planning/spikes/001-caption-timing-drag/
// Sources/TimelineView.swift, VALIDATED on-device): content is translated under a FIXED center
// playhead via `.offset()`, never a native scrolling container. Background `DragGesture(minimumDistance: 2)`
// scrubs `state.currentTime`; `ClipPillView`'s `.highPriorityGesture`s (body-move / edge-handle
// trim) win over this background gesture per SwiftUI's topmost-view-at-touch-point hit-testing —
// no manual gesture-priority arbitration needed beyond that, exactly as the spike proved.
//
// Clips are laid out SEQUENTIALLY (adjacent, back-to-back playback) via a plain HStack — unlike
// the freeform-position Text/Audio/Caption pills (plans 13-15), a clip's timeline position is
// always the sum of every earlier clip's trimmed duration, never an independent x/y. Dragging a
// clip's body previews a live visual offset and, on release, PATCHes its `sort_order` to the
// dropped-on neighbor's position — the server is trusted to resequence the rest (same contract
// ProjectManager.updateAudioClip's `sortOrder` param already relies on for audio pill reordering).
//
// Plan 13-20 (i2/i3/i4): visual-parity rework matching the locked sketch pixel-for-pixel.
// - Block height is now 200pt total: an 88pt FIXED region (ruler + clip row — never scrolls,
//   translated only horizontally by `contentOffset`) and a ~112pt vertically-SCROLLABLE tracks
//   viewport below it (Text/Audio/Caption rows). Each text overlay and each audio clip now gets
//   its OWN 28pt row (matches the sketch's per-item stacking, index.html:389/402) instead of
//   sharing one ZStack rail where concurrent items could overlap; Captions stays one shared rail
//   (cues are time-sequential, never overlapping).
// - Left docks (current/total time readout + play button) and the "+" add-clip tile are
//   repositioned/recolored to match the sketch's `.cur-time`/`.play-box`/`.add-btn` exactly.
// - Ruler now labels EVERY second (was every 5s) with a centered label + half-second dot, no tick
//   rectangles. Playhead line now reaches the bottom of the whole 200pt block.

import SwiftUI

struct TimelineTrackView: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState

    // Shared with ClipPillView/TextOverlayPillView/AudioPillView/CaptionPillView's own x-offset
    // math — kept a single constant per 13-20's explicit out-of-scope note (pinch-zoom is future
    // work; this must stay the only place `44` is hard-coded as the timeline's px/second).
    let pxPerSecond: Double = 44

    // MARK: - Layout constants (13-20 i2/i3/i4 — pixel-level source of truth is the locked sketch)

    private let topInset: CGFloat = 6
    private let rulerHeight: CGFloat = 20
    private let rulerToClipSpacing: CGFloat = 4
    private let clipRowHeight: CGFloat = 58
    private let trackRowHeight: CGFloat = 28   // one text/audio item per row (sketch: idx*30, tightened to match pillHeight)
    private let totalBlockHeight: CGFloat = 200
    private let playBoxWidth: CGFloat = 52

    // F4 (Plan 13-21): play-box/cur-time dock background is now trackBackground everywhere — they
    // match the surrounding timeline block instead of the darker canvasBackground shade.
    private let trackBackground = Color(red: 0.078, green: 0.078, blue: 0.098) // #141419 — overall block backdrop
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)              // #8C59FF
    private let rulerDotColor = Color(red: 0.227, green: 0.227, blue: 0.275)   // #3A3A46

    // Fixed region (never scrolls vertically): ruler row + clip row, translated horizontally by
    // the shared `contentOffset` exactly like before.
    private var fixedRegionHeight: CGFloat { topInset + rulerHeight + rulerToClipSpacing + clipRowHeight }
    private var tracksViewportHeight: CGFloat { totalBlockHeight - fixedRegionHeight }

    // Where the ruler row and clip row each start, in the SAME top-leading coordinate space the
    // playhead/left docks use — derived from the shared layout constants above so nothing can
    // silently drift out of sync between the docks and the actual row positions.
    private var rulerRowTop: CGFloat { topInset }
    private var clipRowTop: CGFloat { topInset + rulerHeight + rulerToClipSpacing }
    private var playheadTopY: CGFloat { clipRowTop - 2 } // starts just under the ruler numbers/dots, never over them
    // i4: the playhead line now runs all the way down to the bottom of the whole 200pt block —
    // visually touching the top edge of the bottom bar, spanning the scrollable tracks viewport
    // as a fixed (allowsHitTesting(false)) overlay.
    private var playheadHeight: CGFloat { totalBlockHeight - playheadTopY }

    @State private var scrubDragStartTime: Double? = nil
    @State private var showAddMediaSheet = false
    @State private var isAddingClip = false

    var body: some View {
        GeometryReader { geo in
            let viewportWidth = geo.size.width
            let contentOffset = viewportWidth / 2 - state.currentTime * pxPerSecond
            let contentWidth = max(state.totalDuration * pxPerSecond, viewportWidth)

            ZStack(alignment: .topLeading) {
                trackBackground

                // Fixed-region scrub background — unambiguous (no ScrollView competes here).
                Color.white.opacity(0.04)
                    .frame(height: fixedRegionHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)

                VStack(alignment: .leading, spacing: rulerToClipSpacing) {
                    ruler(contentWidth: contentWidth)
                    clipRow
                }
                .frame(width: contentWidth, alignment: .leading)
                .offset(x: contentOffset, y: topInset)

                // i2: vertically-scrollable tracks viewport — one row per text overlay, one row
                // per audio clip, then the single caption rail, stacking downward. Ruler/clip
                // row/play/+ (above) stay fixed; only this scrolls.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        TextOverlayTrackRow(state: state, pxPerSecond: pxPerSecond, rowHeight: trackRowHeight)
                        AudioTrackRow(state: state, pxPerSecond: pxPerSecond, rowHeight: trackRowHeight)
                        CaptionTrackRow(state: state, pxPerSecond: pxPerSecond)
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .frame(minHeight: tracksViewportHeight, alignment: .top)
                    // Horizontal-scrub passthrough (13-20 i2 Task 4): lets a predominantly-
                    // horizontal drag still scrub the playhead even when it starts inside the
                    // tracks viewport; the ScrollView's own vertical pan still wins genuinely-
                    // vertical drags, and pill `.highPriorityGesture`s (a descendant) still win
                    // over this ancestor `.simultaneousGesture` on their own bodies.
                    .contentShape(Rectangle())
                    .simultaneousGesture(scrubGesture)
                    .offset(x: contentOffset)
                }
                .frame(height: tracksViewportHeight)
                .offset(y: fixedRegionHeight)
            }
            .clipped()
            .overlay(alignment: .top) {
                // Fixed-center playhead (Task B.4) — content (ruler + clip row + track rows)
                // translates under this via .offset() above; the playhead itself never moves.
                // Shortened + pushed down so its top sits just under the ruler numbers/dots at
                // EVERY scroll offset (never overlaps them), with a small rounded nub at its top
                // (sketch's .playhead-line::before). i4: the line now reaches the bottom of the
                // whole 200pt block.
                ZStack {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 0
                    )
                    .fill(Color.white)
                    .frame(width: 11, height: 8)
                    .position(x: viewportWidth / 2, y: playheadTopY)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: playheadHeight)
                        .shadow(color: .white.opacity(0.5), radius: 4)
                        .position(x: viewportWidth / 2, y: playheadTopY + playheadHeight / 2)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                // Left docks (Task B / 13-20 i3) — current/total time over the ruler row.
                // Opaque background so scrolling content passes visually UNDER it. Each dock is
                // its OWN `.overlay()` call (not two views sharing one closure) and `.clipped()`
                // so neither can ever visually bleed into the other's row — two views sharing one
                // overlay closure were found (via simulator screenshot during 13-20 verification)
                // to composite as if sharing one pre-offset layout pass, letting the play-box's
                // opaque background paint over part of this readout's text.
                curTimeReadout
                    .frame(height: rulerHeight)
                    .clipped()
                    .offset(y: rulerRowTop)
            }
            .overlay(alignment: .topLeading) {
                // Play-box over the clip row, exactly like the locked sketch's `.play-box`.
                playBox
                    .frame(height: clipRowHeight)
                    .offset(y: clipRowTop)
            }
            .overlay(alignment: .topLeading) {
                // 13-20 i3.4: vertically centered ON THE CLIP ROW (not the whole 200pt block).
                // `.topTrailing` alignment (tried first) resolves against this container's OWN
                // reported width — which, thanks to the ruler+clipRow VStack's explicit
                // `.frame(width: contentWidth)` child (contentWidth > viewportWidth for any clip
                // longer than one screen), is `contentWidth`, NOT the visible viewport. That
                // silently rendered the tile far off-screen for any project over ~a few seconds
                // (confirmed via simulator screenshot during 13-20 verification — a debug marker
                // only became visible after switching to an explicit `viewportWidth`-based
                // offset, exactly like curTimeReadout/playBox's approach). `.topLeading` + an
                // explicit x offset anchors it to the ACTUAL viewport's trailing edge instead.
                addClipTile
                    .offset(x: viewportWidth - 46 - 8, y: clipRowTop + (clipRowHeight - 46) / 2)
            }
        }
        .frame(height: totalBlockHeight)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAddMediaSheet) {
            MediaPickerSheet(onAdd: handlePickedMedia)
        }
    }

    // MARK: - Background scrub (Spike 001 verbatim, + a dominant-direction guard so a genuinely
    // vertical drag inside the tracks ScrollView never nudges currentTime — 13-20 i2 Task 4)

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                if scrubDragStartTime == nil { scrubDragStartTime = state.currentTime }
                guard let startTime = scrubDragStartTime else { return }
                let deltaTime = -value.translation.width / pxPerSecond
                state.currentTime = min(max(startTime + deltaTime, 0), state.totalDuration)
            }
            .onEnded { _ in scrubDragStartTime = nil }
    }

    // MARK: - Ruler (13-20 i4.3): per the sketch's `renderRuler` — a label EVERY second, centered
    // on its tick x, plus a dot at every half-second. No tick rectangles.

    private func ruler(contentWidth: Double) -> some View {
        let totalSeconds = max(Int(state.totalDuration.rounded(.up)), 1)
        return ZStack(alignment: .topLeading) {
            ForEach(0...totalSeconds, id: \.self) { sec in
                Text(Self.formatTime(Double(sec)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize()
                    .position(x: Double(sec) * pxPerSecond, y: 7)
            }
            ForEach(0..<totalSeconds, id: \.self) { sec in
                Circle()
                    .fill(rulerDotColor)
                    .frame(width: 3, height: 3)
                    .position(x: (Double(sec) + 0.5) * pxPerSecond, y: 16)
            }
        }
        .frame(width: contentWidth, height: rulerHeight, alignment: .topLeading)
    }

    // MARK: - Play-box + current/total time (Task B / 13-20 i3) — left-docked, opaque, content
    // scrolls under.

    private var playBox: some View {
        Button {
            state.isPlaying.toggle()
        } label: {
            ZStack {
                // F4 (Plan 13-21): trackBackground (#141419), not canvasBackground (#0A0A0D) — the
                // play box now matches the surrounding timeline block instead of reading as a
                // shade darker. Right hairline dropped: against the matching background it read as
                // a stray seam rather than a deliberate divider (verified via simulator screenshot).
                trackBackground
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: playBoxWidth)
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
    }

    // Single concatenated Text (`+`), not an HStack of two Texts — this is the correct SwiftUI
    // idiom for one run of mixed-style inline text. The real root cause of the on-device visual
    // bug (confirmed via simulator screenshot during 13-20 verification — "00:" rendered, then a
    // dead gap, then only a couple trailing characters) was `playBox` sharing ONE `.overlay()`
    // closure with this view: SwiftUI composited both as if sharing a single pre-offset layout
    // pass, letting the play-box's opaque background paint over part of this text. Fixed by
    // giving each dock its OWN `.overlay()` call (see body) plus `.clipped()` here as a backstop.
    private var curTimeReadout: some View {
        (
            Text(Self.formatTime(state.currentTime))
                .fontWeight(.bold)
                .foregroundColor(.white)
            + Text(" / \(Self.formatTime(state.totalDuration))")
                .foregroundColor(.white.opacity(0.5))
        )
        .font(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .fixedSize()
        .background(trackBackground) // F4: matches playBox/the timeline block, not canvasBackground
        .overlay(alignment: .trailing) {
            // Trailing 12pt fade so scrolling ruler content slides under it like the sketch's
            // `box-shadow: 12px 0 12px -4px var(--color-bg)`.
            LinearGradient(colors: [trackBackground, trackBackground.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 12)
                .offset(x: 12)
                .allowsHitTesting(false)
        }
    }

    // Copied verbatim from FullscreenEditorPlayerView.swift:222 (13-19 Task B contract: same
    // helper everywhere so "0:00 / 0:09" matches across the Editor, never a second implementation).
    // 13-20 i3.2: minutes now zero-padded (`00:02 / 00:09`, matches the sketch's `fmt` + target
    // screenshot) — was `%d:%02d`.
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Clip row: sequential, adjacent ClipPillViews (SC1/SC2)

    private var sortedClips: [ProjectClip] {
        state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var clipRow: some View {
        HStack(spacing: 3) {
            ForEach(sortedClips) { clip in
                ClipPillView(
                    clip: clip,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .clip(clip.id),
                    onSelect: { selectClip(clip) },
                    onReorder: { translation in handleReorder(clip: clip, translation: translation) },
                    onTrimChange: { newStart, newEnd in
                        Task { await updateClipTrim(clipId: clip.id, start: newStart, end: newEnd) }
                    }
                )
            }
        }
        .frame(height: clipRowHeight, alignment: .leading)
    }

    // MARK: - Clip selection with the C0 snap-to-start rule (13-19 Task C0, exact user spec):
    // selecting a clip the playhead is ALREADY inside leaves the playhead alone; selecting a clip
    // the playhead falls outside of snaps the playhead to that clip's start (the boundary of the
    // previous clip, since clips are adjacent) — never moves the divider itself, only its content.

    private func selectClip(_ clip: ProjectClip) {
        let clips = sortedClips
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else {
            state.select(.clip(clip.id))
            return
        }
        var clipStart = 0.0
        for earlier in clips[..<index] { clipStart += duration(of: earlier) }
        let clipEnd = clipStart + duration(of: clip)

        if !(state.currentTime >= clipStart && state.currentTime < clipEnd) {
            state.currentTime = clipStart
        }
        state.select(.clip(clip.id))
    }

    // MARK: - Inline "+" add-clip tile (D-08/D-09) — fixed at the trailing edge, clips scroll
    // under it per the locked sketch ("+ : fixed square in frame on the right, always visible").

    private var addClipTile: some View {
        Button {
            showAddMediaSheet = true
        } label: {
            ZStack {
                if isAddingClip {
                    ProgressView().tint(accent)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 46, height: 46)
            .background(Color(red: 0.11, green: 0.11, blue: 0.137), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accent.opacity(0.7), lineWidth: 1)
            )
            .shadow(color: accent.opacity(0.35), radius: 8)
        }
        .disabled(isAddingClip)
        .accessibilityLabel("Add clip")
    }

    // MARK: - Clip mutations — reconcile `state.project` from the reloaded `projectManager
    // .loadedProject` after every mutation (EditorState "owns playback/selection state, not
    // persistence" per its own doc comment — this view is the caller responsible for reflecting
    // ProjectManager's persisted result back onto the shared clock).

    private func handlePickedMedia(_ items: [PickedMedia]) {
        guard !items.isEmpty else { return }
        isAddingClip = true
        Task {
            for item in items {
                do {
                    switch item {
                    case .generation(let id, _):
                        try await projectManager.importClip(generationId: id)
                    case .upload(let url, let mediaType):
                        try await projectManager.uploadClip(fileURL: url, mediaType: mediaType)
                    }
                } catch {
                    print("[TimelineTrackView] add clip error: \(error)")
                }
            }
            syncProjectFromManager()
            isAddingClip = false
        }
    }

    private func updateClipTrim(clipId: String, start: Double, end: Double) async {
        do {
            try await projectManager.updateClip(clipId: clipId, trimStart: start, trimEnd: end)
            syncProjectFromManager()
        } catch {
            print("[TimelineTrackView] updateClipTrim error: \(error)")
        }
    }

    /// Live-preview drag ends here: `translation` is the final horizontal drag distance (points).
    /// Converts it to a target index by comparing the dragged clip's projected new center against
    /// every clip's timeline position, then PATCHes the dragged clip's `sort_order` to the target
    /// neighbor's current value — the backend is trusted to resequence the rest, mirroring the
    /// same `sortOrder` reorder contract `ProjectManager.updateAudioClip` already exposes.
    private func handleReorder(clip: ProjectClip, translation: CGFloat) {
        let clips = sortedClips
        guard let currentIndex = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        guard translation != 0 else { return }

        var starts: [Double] = []
        var acc = 0.0
        for c in clips {
            starts.append(acc)
            acc += duration(of: c)
        }

        let deltaSeconds = Double(translation) / pxPerSecond
        let newCenter = starts[currentIndex] + duration(of: clip) / 2 + deltaSeconds

        var targetIndex = clips.count - 1
        for (index, c) in clips.enumerated() {
            if newCenter < starts[index] + duration(of: c) / 2 {
                targetIndex = index
                break
            }
        }
        guard targetIndex != currentIndex, clips.indices.contains(targetIndex) else { return }

        let targetSortOrder = clips[targetIndex].sortOrder
        Task {
            do {
                try await projectManager.updateClip(clipId: clip.id, sortOrder: targetSortOrder)
                syncProjectFromManager()
            } catch {
                print("[TimelineTrackView] reorderClip error: \(error)")
            }
        }
    }

    private func duration(of clip: ProjectClip) -> Double {
        let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
        return max(0, end - clip.trimStartSeconds)
    }

    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }
}
