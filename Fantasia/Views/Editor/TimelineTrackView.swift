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
    /// F12 (Plan 13-21): the empty-state "+ Add audio" placeholder taps through to here — opens
    /// the SAME AddAudioSheet EditorBottomBar's Audio action already owns (EditorView is the
    /// source of truth for `showAddAudioSheet`, this view has no sheet-presentation state of its
    /// own for it).
    let onAddAudio: () -> Void
    /// F12: the empty-state text placeholder taps through to here — the SAME
    /// `addDefaultTextOverlay()` EditorBottomBar's Text action already calls.
    let onAddDefaultText: () -> Void
    /// F16/F17 (Plan 13-21): fires once CoverPickerSheet has actually persisted a new cover — the
    /// caller (EditorView) reconciles state.project from projectManager.loadedProject and shows
    /// the "Cover updated" toast (this view has no toast machinery of its own for it, mirrors the
    /// onAddAudio/onAddDefaultText closure-threading pattern above).
    let onCoverUpdated: () -> Void

    // F5 (Plan 13-21): now forwards to the shared `state.pxPerSecond` (moved off this file's old
    // hard-coded `let pxPerSecond: Double = 44` so the pinch gesture below and every pill/row/ruler
    // consumer — all of which already read `pxPerSecond` from this view — see the SAME live value).
    private var pxPerSecond: Double { state.pxPerSecond }

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
    // 13-22 i2: this IS what the block looked like with the old #141419 base PLUS the fixed
    // region's separate `Color.white.opacity(0.04)` overlay (the two colors pre-blended) — that
    // overlay is now deleted and every consumer (block backdrop, playBox, curTimeReadout, tracks
    // region) reads this ONE value, so nothing reads "darker" than anything else anymore.
    private let trackBackground = Color(red: 0.115, green: 0.115, blue: 0.134) // ~#1D1D22
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)              // #8C59FF
    private let rulerDotColor = Color(red: 0.227, green: 0.227, blue: 0.275)   // #3A3A46
    // F12: left rail tile fill (~#1E1E22) — reference image IMG_0428 2.jpg's ♪/T icon squares.
    private let railTileFill = Color(red: 0.118, green: 0.118, blue: 0.133)
    // Sized to fit the existing 28pt trackRowHeight (13-20's locked row height) rather than the
    // reference image's literal "~40pt" — a 40pt tile would overlap the row above/below at this
    // compact row height; 26pt keeps the same rounded-square glyph-tile language within the row.
    private let railTileSize: CGFloat = 26

    // Fixed region (never scrolls vertically): ruler row + clip row, translated horizontally by
    // the shared `contentOffset` exactly like before.
    private var fixedRegionHeight: CGFloat { topInset + rulerHeight + rulerToClipSpacing + clipRowHeight }
    private var tracksViewportHeight: CGFloat { totalBlockHeight - fixedRegionHeight }

    // F13: row-count-driven section heights — audio/text always reserve at least ONE row (the
    // empty-state placeholder occupies it when there are zero items), captions stays its own
    // fixed single shared rail (CaptionTrackRow's own internal `rowHeight`, 30pt).
    private var audioRowCount: Int { max(1, state.project.audioClips.count) }
    private var textRowCount: Int { max(1, state.project.textOverlays.count) }
    private var audioSectionHeight: CGFloat { CGFloat(audioRowCount) * trackRowHeight }
    private var textSectionHeight: CGFloat { CGFloat(textRowCount) * trackRowHeight }
    private let captionRailHeight: CGFloat = 30
    private var rowsContentHeight: CGFloat { audioSectionHeight + textSectionHeight + captionRailHeight }
    private var maxTracksScrollY: CGFloat { max(0, rowsContentHeight - tracksViewportHeight) }

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
    @State private var showCoverPicker = false

    // F13: manual vertical scroll for the tracks viewport — replaces the ScrollView(.vertical) +
    // .simultaneousGesture(scrubGesture) combination (confirmed via simulator repro to never
    // actually scroll: the ScrollView's own vertical pan gesture and the background scrub gesture
    // fight over the same touch, and the ScrollView wins hit-testing before the scrub gesture ever
    // sees a vertical drag, so `tracksScrollY` — driven entirely by hand below — never moved).
    // Content is translated under the fixed rail/playhead via `-tracksScrollY`, matching the
    // existing translate-under-fixed-playhead architecture the horizontal scrub already uses.
    @State private var tracksScrollY: CGFloat = 0
    @State private var tracksDragAxis: Axis? = nil
    @State private var tracksScrubStartTime: Double? = nil
    @State private var tracksScrollStartY: CGFloat? = nil

    // F5: pinch-to-zoom start value, captured on the gesture's first change.
    @State private var pinchStartPxPerSecond: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let viewportWidth = geo.size.width
            let contentOffset = viewportWidth / 2 - state.currentTime * pxPerSecond
            let contentWidth = max(state.totalDuration * pxPerSecond, viewportWidth)

            ZStack(alignment: .topLeading) {
                // 13-22 i2: ONE uniform gray backs the whole 200pt block now — this single fill
                // covers ruler row / clip row / tracks viewport alike (see trackBackground's doc
                // comment). The old separate `Color.white.opacity(0.04)` rectangle that used to
                // sit OVER just the fixed region is gone; its gesture/tap responsibility moves to
                // the transparent hit-target immediately below (paints nothing — trackBackground
                // above already covers this area visually).
                trackBackground

                // Fixed-region scrub hit-target — unambiguous (no ScrollView competes here).
                // F11 (Plan 13-21): a plain tap (no movement, so scrubGesture's DragGesture never
                // fires) now also deselects — pills' own .onTapGesture still wins for taps that
                // land on THEM specifically (SwiftUI's descendant-first hit-testing, same contract
                // this whole file already relies on for drag-vs-scrub arbitration).
                Color.clear
                    .frame(height: fixedRegionHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)
                    .onTapGesture { state.select(.none) }

                VStack(alignment: .leading, spacing: rulerToClipSpacing) {
                    ruler(contentWidth: contentWidth)
                    clipRow(viewportWidth: viewportWidth)
                }
                .frame(width: contentWidth, alignment: .leading)
                .offset(x: contentOffset, y: topInset)

                // F12+F13: manual tracks viewport — Audio rows ABOVE Text rows (reference image
                // order), then the single Caption rail, stacking downward. Ruler/clip row/play/+
                // (above) stay fixed. Vertical scroll is fully manual (F13 — see tracksScrollY's
                // doc comment); horizontal scrub still works via the SAME axis-locked gesture.
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            AudioTrackRow(state: state, pxPerSecond: pxPerSecond, rowHeight: trackRowHeight)
                            TextOverlayTrackRow(state: state, pxPerSecond: pxPerSecond, rowHeight: trackRowHeight)
                            CaptionTrackRow(state: state, pxPerSecond: pxPerSecond)
                        }

                        // 13-22 i11 (user decision): rail tiles (♪/T) + empty-state placeholders
                        // now live in CONTENT coordinates — same ZStack, same offset transform as
                        // the pills above — so they scroll away with the clips as you scrub
                        // deeper, instead of staying pinned to the viewport.
                        railOverlay
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .offset(x: contentOffset, y: -tracksScrollY)
                }
                .frame(width: viewportWidth, height: tracksViewportHeight, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(tracksGesture)
                .onTapGesture { state.select(.none) } // F11: plain tap on empty tracks background deselects
                .offset(y: fixedRegionHeight)
            }
            .clipped()
            // F5: pinch-to-zoom over the WHOLE timeline block (ruler + clip row + tracks viewport),
            // simultaneous with every other gesture here — `contentOffset`/`-tracksScrollY` above
            // both derive from `state.currentTime`/`pxPerSecond`, not a separate scroll-position
            // variable, so changing `pxPerSecond` alone re-centers the content around the
            // screen-fixed playhead automatically (no separate "anchor at playhead" math needed).
            .simultaneousGesture(magnificationGesture)
            .overlay(alignment: .top) {
                // Fixed-center playhead (Task B.4) — content (ruler + clip row + track rows)
                // translates under this via .offset() above; the playhead itself never moves.
                // Shortened + pushed down so its top sits just under the ruler numbers/dots at
                // EVERY scroll offset (never overlaps them), with a small rounded nub at its top
                // (sketch's .playhead-line::before). i4: the line now reaches the bottom of the
                // whole 200pt block.
                ZStack {
                    // 13-22 i9: nub shrunk 11×8 → 8×6 and moved up 2pt so it reads as a small cap
                    // sitting just above the ruler row, its bottom edge meeting the line's top.
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 0
                    )
                    .fill(Color.white)
                    .frame(width: 8, height: 6)
                    .position(x: viewportWidth / 2, y: playheadTopY - 2)

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
        .sheet(isPresented: $showCoverPicker) {
            CoverPickerSheet(project: state.project, onCoverSet: onCoverUpdated)
        }
    }

    // MARK: - Background scrub (Spike 001 verbatim, + a dominant-direction guard). Used by the
    // FIXED region only (ruler + clip row) — the tracks viewport below has its OWN axis-locked
    // gesture (tracksGesture, F13) since it also needs to scroll vertically.

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                if scrubDragStartTime == nil { scrubDragStartTime = state.currentTime }
                guard let startTime = scrubDragStartTime else { return }
                let deltaTime = -value.translation.width / pxPerSecond
                state.currentTime = state.clampTime(startTime + deltaTime)
            }
            .onEnded { _ in scrubDragStartTime = nil }
    }

    // MARK: - Tracks viewport gesture (F13, Plan 13-21) — ONE background DragGesture over the
    // whole tracks region with axis lock decided on the FIRST change: a predominantly-horizontal
    // drag scrubs `state.currentTime` (identical math to scrubGesture above); a predominantly-
    // vertical drag adjusts `tracksScrollY` instead. The axis is locked for the remainder of that
    // drag (never re-evaluated mid-gesture) so a diagonal finger wobble can't flip modes partway
    // through. Pills' `.highPriorityGesture`s (descendants) still win over this ancestor gesture on
    // their own bodies — same SwiftUI hit-testing contract every other pill/background gesture
    // pair in this file already relies on.

    private var tracksGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if tracksDragAxis == nil {
                    tracksDragAxis = abs(value.translation.width) >= abs(value.translation.height) ? .horizontal : .vertical
                    switch tracksDragAxis {
                    case .horizontal: tracksScrubStartTime = state.currentTime
                    case .vertical: tracksScrollStartY = tracksScrollY
                    default: break
                    }
                }
                switch tracksDragAxis {
                case .horizontal:
                    guard let startTime = tracksScrubStartTime else { return }
                    let deltaTime = -value.translation.width / pxPerSecond
                    state.currentTime = state.clampTime(startTime + deltaTime)
                case .vertical:
                    guard let startY = tracksScrollStartY else { return }
                    let newY = startY - value.translation.height
                    tracksScrollY = min(max(newY, 0), maxTracksScrollY)
                default:
                    break
                }
            }
            .onEnded { _ in
                tracksDragAxis = nil
                tracksScrubStartTime = nil
                tracksScrollStartY = nil
            }
    }

    // MARK: - Pinch-to-zoom (F5, Plan 13-21)

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if pinchStartPxPerSecond == nil {
                    pinchStartPxPerSecond = state.pxPerSecond
                    state.isZooming = true
                }
                guard let start = pinchStartPxPerSecond else { return }
                state.pxPerSecond = min(max(start * value, 12), 120)
            }
            .onEnded { _ in
                pinchStartPxPerSecond = nil
                state.isZooming = false
            }
    }

    // MARK: - Ruler (F5, Plan 13-21): ADAPTIVE label interval — the first of [1, 2, 5, 10, 30, 60]
    // seconds where `interval * pxPerSecond >= 56` (labels never crowd closer than ~56pt apart).
    // At the default 44px/s that's 2s labels; pinch in far enough and it steps down to 1s, pinch
    // out and it steps up through 5s/10s/30s/60s. A dot marks the MIDPOINT between each pair of
    // labels (was: a fixed dot every 0.5s, independent of the label interval — 13-20 i4.3).

    private static let labelIntervalCandidates: [Double] = [1, 2, 5, 10, 30, 60]

    private var labelInterval: Double {
        Self.labelIntervalCandidates.first { $0 * pxPerSecond >= 56 } ?? Self.labelIntervalCandidates.last!
    }

    private func ruler(contentWidth: Double) -> some View {
        let interval = labelInterval
        let totalSeconds = max(state.totalDuration, 1)
        let lastLabelSec = (totalSeconds / interval).rounded(.up) * interval
        let labelCount = max(Int((lastLabelSec / interval).rounded()) + 1, 1)

        return ZStack(alignment: .topLeading) {
            ForEach(0..<labelCount, id: \.self) { i in
                let sec = Double(i) * interval
                Text(Self.formatTime(sec))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize()
                    .position(x: sec * pxPerSecond, y: 7)
            }
            ForEach(0..<max(labelCount - 1, 0), id: \.self) { i in
                let midSec = (Double(i) + 0.5) * interval
                Circle()
                    .fill(rulerDotColor)
                    .frame(width: 3, height: 3)
                    // 13-22 i9: dots now sit on the SAME centerline as the labels (y:7) — one row
                    // reading label · dot · label · dot, instead of a separate lower dot row.
                    .position(x: midSec * pxPerSecond, y: 7)
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
        // 13-22 i9: 11 → 9pt, identical to the ruler labels' font, and vertically repositioned so
        // its text sits on the SAME line as the ruler labels (center y ≈ 7 within the 20pt ruler
        // row) instead of centering in the full row height (which read "too low").
        .font(.system(size: 9, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .fixedSize()
        .frame(height: rulerHeight, alignment: .top)
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

    private func clipRow(viewportWidth: CGFloat) -> some View {
        // 13-22 i3: spacing 3 → 0 — every clip-gap pixel the old `spacing: 3` inserted was pixel
        // math the time↔pixel conversion never accounted for, so the visual strip end drifted
        // `3×(N−1)`pt past `totalDuration*pxPerSecond` (compounding with clip count) and the
        // playhead could never quite reach the last scene. Visual separation between adjacent
        // clips now comes from ClipPillView's own 1pt leading-edge divider instead of a real gap.
        HStack(spacing: 0) {
            ForEach(sortedClips) { clip in
                ClipPillView(
                    clip: clip,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .clip(clip.id),
                    isZooming: state.isZooming,
                    onSelect: { selectClip(clip) },
                    onReorder: { translation in handleReorder(clip: clip, translation: translation) },
                    onTrimChange: { newStart, newEnd in
                        Task { await updateClipTrim(clipId: clip.id, start: newStart, end: newEnd) }
                    }
                )
            }
        }
        .frame(height: clipRowHeight, alignment: .leading)
        .overlay(alignment: .leading) {
            // F16 (Plan 13-21), repositioned 13-22 i10: cover card in CONTENT coordinates just
            // left of t=0 — scrolls WITH the clips (contentOffset already applies to the whole
            // ruler+clipRow VStack this clipRow lives in). The gap is now COMPUTED from the
            // viewport so at t=00:00 the card's LEFT edge lands ~8pt right of the play-box
            // (previously a fixed 6pt gap sat the card almost flush against the play-box).
            coverCard.offset(x: -(coverCardWidth + coverCardGap(viewportWidth: viewportWidth)))
        }
    }

    // MARK: - F16: cover card (content-space, just left of t=0)

    private let coverCardWidth: CGFloat = 52

    // 13-22 i10: at t=0, contentOffset == viewportWidth/2 (the playhead sits screen-centered), so
    // content-x 0 (the first clip's leading edge) renders at screen-x viewportWidth/2. The
    // play-box dock occupies screen-x [0, playBoxWidth]. Solving for the gap that lands the cover
    // card's LEFT edge at screen-x (playBoxWidth + 8) yields this formula; `max(6, ...)` keeps a
    // sane minimum gap on very narrow viewports.
    private func coverCardGap(viewportWidth: CGFloat) -> CGFloat {
        max(6, viewportWidth / 2 - playBoxWidth - coverCardWidth - 8)
    }

    private var coverCard: some View {
        Button {
            showCoverPicker = true
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let urlString = state.project.thumbnailUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color(red: 0.11, green: 0.11, blue: 0.137)
                        }
                    }
                } else {
                    Color(red: 0.11, green: 0.11, blue: 0.137)
                }

                HStack(spacing: 3) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Cover")
                        .font(.system(size: 11, weight: .semibold))
                        .underline()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.45))
            }
            .frame(width: coverCardWidth, height: clipRowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose project cover")
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

        // F10 (Plan 13-21): keeps the EXACT "always snap to clipStart when outside" rule (not the
        // generic nearest-boundary EditorState.snapPlayhead behavior every other pill type uses —
        // clips are adjacent/back-to-back, so clipStart doubles as the boundary with the PREVIOUS
        // clip; snapping there is intentional even if the playhead was already past clipEnd), now
        // wrapped in the same animated-glide treatment (withAnimation — contentOffset derives from
        // currentTime, so the timeline glides instead of jumping).
        if !(state.currentTime >= clipStart && state.currentTime < clipEnd) {
            withAnimation(.easeInOut(duration: 0.25)) {
                state.currentTime = state.clampTime(clipStart)
            }
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

    // MARK: - 13-22 i11 rail: ♪/T tiles + empty-state placeholders, now in CONTENT coordinates
    // (user decision, locked 2026-07-15: they scroll away with the clips — previously pinned in
    // viewport coordinates via a separate translate-with-tracksScrollY-only layer). Reference
    // frames f04/f10-f16's rail layout: tiles sit just LEFT of the first scene (content x < 0).

    private var railOverlay: some View {
        ZStack(alignment: .topLeading) {
            railTile(systemName: "music.note")
                .frame(height: trackRowHeight, alignment: .center)
                .offset(x: -(railTileSize + 8))

            if state.project.audioClips.isEmpty {
                audioPlaceholderPill
                    .frame(height: trackRowHeight, alignment: .center)
            }

            railTile(systemName: "textformat")
                .frame(height: trackRowHeight, alignment: .center)
                .offset(x: -(railTileSize + 8), y: audioSectionHeight)

            if state.project.textOverlays.isEmpty {
                textPlaceholderRow
                    .frame(height: trackRowHeight, alignment: .center)
                    .offset(y: audioSectionHeight)
            }
        }
    }

    private func railTile(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(railTileFill)
            .frame(width: railTileSize, height: railTileSize)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
    }

    // 13-22 i11.3: width is now EXACTLY `state.totalDuration * pxPerSecond` (was
    // `.frame(maxWidth: .infinity)`, which — because this pill's row lived inside a
    // viewport-width-constrained VStack — silently stretched the BUTTON's own tappable shape to
    // the full viewport width, the root cause of "random taps open the audio sheet"). The Button
    // wraps exactly this sized shape now, so the tap target IS the pill, nothing wider.
    private let placeholderPillHeight: CGFloat = 24

    // "＋ Add audio" — grey rounded pill spanning [0, video end], tap opens the SAME AddAudioSheet
    // the bottom bar's Audio action opens (onAddAudio, owned by EditorView).
    private var audioPlaceholderPill: some View {
        Button(action: onAddAudio) {
            Text("＋ Add audio")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: max(state.totalDuration * pxPerSecond, 60), height: placeholderPillHeight, alignment: .leading)
                .padding(.leading, 10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add audio")
    }

    // Empty grey rounded row spanning [0, video end], tap adds the default "Text" overlay at the
    // playhead (onAddDefaultText, owned by EditorView — the exact same call EditorBottomBar's Text
    // action already makes).
    private var textPlaceholderRow: some View {
        Button(action: onAddDefaultText) {
            Color.white.opacity(0.06)
                .frame(width: max(state.totalDuration * pxPerSecond, 60), height: placeholderPillHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add text")
    }

    // MARK: - Clip mutations — reconcile `state.project` from the reloaded `projectManager
    // .loadedProject` after every mutation (EditorState "owns playback/selection state, not
    // persistence" per its own doc comment — this view is the caller responsible for reflecting
    // ProjectManager's persisted result back onto the shared clock).

    private func handlePickedMedia(_ items: [PickedMedia]) {
        guard !items.isEmpty else { return }
        isAddingClip = true
        let idsBefore = Set(state.project.clips.map(\.id))
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
            // F8: one "add" record per NEW clip actually added (a multi-select add can add
            // several at once) — undo soft-deletes it, redo restores it. Adding a clip back via
            // re-import isn't attempted on redo (the source generation/upload may no longer be
            // available) — restore is always possible since the R2 object is kept either way.
            let newIds = Set(state.project.clips.map(\.id)).subtracting(idsBefore)
            for newId in newIds {
                state.history.record(UndoableAction(
                    label: "Add clip",
                    undo: { try await projectManager.deleteClip(clipId: newId) },
                    redo: { try await projectManager.restoreClip(clipId: newId) }
                ))
            }
        }
    }

    // F8: trim-handle drags fire `onTrimChange` CONTINUOUSLY (every `.onChanged`, not just on
    // release) — recording an UndoableAction on every call would flood the history with dozens of
    // near-duplicate entries per gesture. Debounced instead: the FIRST change of a drag captures
    // the clip's pre-drag (start,end) as "before"; each subsequent change resets a short timer;
    // once the timer fires (drag has settled), ONE record is committed spanning "before" →
    // whatever the LATEST values were.
    @State private var trimBeforeByClip: [String: (start: Double, end: Double)] = [:]
    @State private var trimDebounceTasks: [String: Task<Void, Never>] = [:]

    private func updateClipTrim(clipId: String, start: Double, end: Double) async {
        if trimBeforeByClip[clipId] == nil, let clip = state.project.clips.first(where: { $0.id == clipId }) {
            let beforeEnd = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
            trimBeforeByClip[clipId] = (clip.trimStartSeconds, beforeEnd)
        }
        do {
            try await projectManager.updateClip(clipId: clipId, trimStart: start, trimEnd: end)
            syncProjectFromManager()
        } catch {
            print("[TimelineTrackView] updateClipTrim error: \(error)")
        }
        scheduleTrimUndoCommit(clipId: clipId, after: (start, end))
    }

    private func scheduleTrimUndoCommit(clipId: String, after: (start: Double, end: Double)) {
        trimDebounceTasks[clipId]?.cancel()
        trimDebounceTasks[clipId] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let before = trimBeforeByClip[clipId] else { return }
            trimBeforeByClip[clipId] = nil
            trimDebounceTasks[clipId] = nil
            state.history.record(UndoableAction(
                label: "Trim clip",
                undo: { try await projectManager.updateClip(clipId: clipId, trimStart: before.start, trimEnd: before.end) },
                redo: { try await projectManager.updateClip(clipId: clipId, trimStart: after.start, trimEnd: after.end) }
            ))
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
        // F8: reorder fires ONCE at drag release (unlike trim), so this records directly — no
        // debounce needed. Best-effort undo: re-PATCHes the dragged clip's OWN sort_order back to
        // its pre-drag value (a multi-clip reorder cascade on the server isn't fully replayed in
        // reverse for every OTHER clip it may have resequenced — acceptable v1 tradeoff, matches
        // typical editor undo scope).
        let previousSortOrder = clip.sortOrder
        Task {
            do {
                try await projectManager.updateClip(clipId: clip.id, sortOrder: targetSortOrder)
                syncProjectFromManager()
                state.history.record(UndoableAction(
                    label: "Reorder clip",
                    undo: { try await projectManager.updateClip(clipId: clip.id, sortOrder: previousSortOrder) },
                    redo: { try await projectManager.updateClip(clipId: clip.id, sortOrder: targetSortOrder) }
                ))
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
