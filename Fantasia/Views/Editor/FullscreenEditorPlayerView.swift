// FullscreenEditorPlayerView.swift
// Fantasia
// Phase 13, Plan 16: the Editor's in-app fullscreen preview player (SC6) — play/scrub/time/
// minimize, presented as a `.fullScreenCover` from EditorView's controls-row fullscreen button
// (placeholder since plan 11, wired for real here).
//
// Plan 13-21 F1 REWRITE: the original version played only `clips.first` (via AVQueuePlayer +
// AVPlayerLooper, mirroring FullScreenVideoPlayerView's single-asset shape) while writing that
// item's own LOOPED LOCAL time straight onto the shared `state.currentTime` — for any multi-clip
// project this fought the inline player's real back-to-back composition and looked like
// "overlapping media" (clip 0 looping forever under/over whatever the timeline said should be
// playing). That rewrite built the SAME EditorCompositionBuilder composition the inline player
// uses, but on its OWN separate AVPlayer instance.
//
// Plan 13-22 F6 REWRITE (this version): stops building ANYTHING — EditorView now passes its OWN
// live `player` (the SAME AVPlayer instance the inline surface already drives) straight through.
// No new AVPlayerItem, no re-buffer, no re-download: this view opens on the EXACT current frame
// instantly, because it's the identical player object, just rendered through a second
// AVPlayerLayer-backed `FillingVideoPlayerView`. EditorView's own periodic time observer (already
// running on this player) keeps clamping/advancing `state.currentTime` regardless of which
// surface is visible — this view has NO time observer of its own, only play/pause/seek calls
// forwarded onto the shared player, plus a local `isScrubbing` flag. Its drag also marks the
// shared EditorState scrub flag so EditorView's serialized latest-wins seek engine drives this
// surface too, instead of fullscreen changes spawning independent fire-and-forget exact seeks.
// On minimize there is nothing to reconcile — same player, same clock, throughout.
//
// Still bound to the SAME shared `EditorState.currentTime`/`isPlaying` clock instead of a
// separate, locally-owned time/isPlaying pair.
//
// Layers CaptionOverlayView (SC5, live karaoke) and TextOverlayCanvasView (SC3) on top of the
// video, exactly per Delta 6 — the fullscreen surface renders the same overlays the inline preview
// does. TextOverlayCanvasView passes `showsControls: false` (13-22 i6.2) — plain text on video,
// never selection frames/corner buttons/rotation handle, regardless of `state.selection` (this is
// a preview-only surface, not an editing one).
//
// 13-22 i6.3/i13: the minimize button moved OFF its own top-trailing row and INTO the bottom
// playback control bar as the last element (icon `arrow.down.right.and.arrow.up.left`, 24pt
// frame) — the old separate top row is gone entirely.
//
// Item 4 (round 2, Andrew review 2026-07-17): the video layer (`FillingVideoPlayerView`/
// `EditorVideoOutputView`) is `.ignoresSafeArea()`, filling the WHOLE screen, and
// `videoGravity: .resizeAspect` letterboxes the actual video frame WITHIN that full-screen layer
// — but TextOverlayCanvasView/CaptionOverlayView were sized to that same full-screen container,
// so their normalized (x/y norm, caption yOffsetNorm, top/middle/bottom presets) coordinates were
// relative to the FULL SCREEN, not the letterboxed video rect. For any aspect that doesn't match
// the device screen (e.g. a 16:9 project), captions/text landed offset into the letterbox bars
// instead of inside the frame. Fixed: both overlay layers are now sized/positioned to the SAME
// fitted video rect (`AVMakeRect(aspectRatio:insideRect:)`) the inline editor preview
// (EditorView.previewStage) already computes and constrains its own overlay mounts to — passed in
// as `aspectFraction` so this is byte-for-byte the same source of truth, never a second
// independent derivation that could drift. The fitted overlay canvas must be a SIBLING of the
// safe-area-ignoring video layer. Keeping it as that layer's `.overlay` inherits the expanded
// safe-area proposal, so CaptionOverlayView can still resolve against the full screen (putting
// the 16:9 Bottom preset in the lower letterbox) even when an outer frame looks constrained.

import SwiftUI
import AVFoundation

struct FullscreenEditorPlayerView: View {
    let state: EditorState
    /// The SAME AVPlayer EditorView's inline surface drives — see file header. Optional only for
    /// the (should-never-happen) case fullscreen opens before EditorView.rebuildPlayer() has ever
    /// finished once.
    let player: AVPlayer?
    let usesComposedVideoOutput: Bool
    let videoOutputRenderer: EditorVideoOutputRenderer
    /// Item 4 (round 2): the project-canvas aspect fraction (width/height), identical to what
    /// EditorView.previewStage derives via its own `aspectFraction(state.aspectRatio)` — see file
    /// header. Used ONLY to fit the overlay layers to the video's actual letterboxed rect; the
    /// video layer itself already letterboxes correctly on its own via `videoGravity: .resizeAspect`.
    let aspectFraction: CGFloat
    let onMinimize: () -> Void
    /// Item 5 (Andrew review, 2026-07-17): threaded to this view's own TextOverlayCanvasView
    /// mount below — see that mount's `.allowsHitTesting(false)` comment for why this is inert
    /// today (kept for API consistency, not because it's currently reachable).
    var onError: (String) -> Void = { _ in }

    @State private var isScrubbing = false

    /// Item 4 (round 2): the video's aspect-fit rect within `containerSize` (the full-screen
    /// GeometryReader size here; the reader itself ignores safe areas below so it proposes the
    /// exact same canvas as the player layer) — same math `AVMakeRect(aspectRatio:insideRect:)`
    /// always produces, matching what `videoGravity: .resizeAspect` actually draws on screen.
    private func fittedVideoRect(in containerSize: CGSize) -> CGRect {
        guard aspectFraction > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        return AVMakeRect(
            aspectRatio: CGSize(width: aspectFraction, height: 1),
            insideRect: CGRect(origin: .zero, size: containerSize)
        )
    }

    var body: some View {
        GeometryReader { geo in
            let fittedRect = fittedVideoRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                if let player {
                    Group {
                        if usesComposedVideoOutput {
                            EditorVideoOutputView(renderer: videoOutputRenderer)
                        } else {
                            FillingVideoPlayerView(player: player, videoGravity: .resizeAspect)
                        }
                    }
                    .ignoresSafeArea()

                    // Verification item 6: this fixed-size sibling is the ACTUAL coordinate
                    // space proposed to both overlay GeometryReaders. Do not move it back onto
                    // the safe-area-ignoring video view with `.overlay` (see file header).
                    ZStack {
                        // Preview-only surface — none of TextOverlayCanvasView's editing gestures
                        // can fire here, so `onError` remains an API-consistency hook.
                        TextOverlayCanvasView(state: state, showsControls: false, onError: onError)
                            .allowsHitTesting(false)

                        // Caption drag is likewise disabled in this preview-only surface.
                        CaptionOverlayView(state: state, isDraggable: false)
                    }
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .offset(x: fittedRect.minX, y: fittedRect.minY)
                } else {
                    ProgressView().tint(.white)
                }

                VStack {
                    Spacer()
                    if let player {
                        playbackControlBar(player: player)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            // Keeping the root pinned to GeometryReader's exact size makes fittedRect's
            // top-leading offsets deterministic for top, middle, and bottom caption anchors.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // The player already draws through every safe area. The geometry used to fit the caption
        // and text canvas must receive that identical full-screen proposal too; otherwise its
        // vertical center/letterbox rect is computed from a shorter safe-area container and the
        // same persisted yOffsetNorm lands lower relative to the actual video pixels. Controls
        // remain safe because playbackControlBar still pads by geo.safeAreaInsets.bottom above.
        .ignoresSafeArea()
        .statusBar(hidden: true)
    }

    // MARK: - Playback control bar: play/pause + scrubber + elapsed/total + minimize (i6.3/i13 —
    // minimize is now the LAST element here, right of the time text; the capsule's horizontal
    // padding shrank 16 → 12 to make room, the scrubber flexes to fill whatever's left).

    private func playbackControlBar(player: AVPlayer) -> some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback(player: player)
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            // 13-23 J2: matches playBox's zero-press-effect treatment for consistency.
            .buttonStyle(EditorNoPressButtonStyle())

            scrubber(player: player)

            Text("\(formatTime(state.currentTime)) / \(formatTime(state.totalDuration))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()

            Button(action: onMinimize) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(EditorNoPressButtonStyle())
            .accessibilityLabel("Minimize")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func scrubber(player: AVPlayer) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let total = state.totalDuration
            let progress = total > 0 ? min(max(state.currentTime / total, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3)).frame(height: 3)
                Capsule().fill(Color.white).frame(width: width * progress, height: 3)
                Circle().fill(Color.white).frame(width: 10, height: 10)
                    .offset(x: width * progress - 5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginScrubbing(player: player)
                        let fraction = min(max(value.location.x / width, 0), 1)
                        updateScrub(fraction: fraction, totalDuration: total)
                    }
                    .onEnded { _ in endScrubbing(player: player) }
            )
        }
        .frame(height: 24)
    }

    // MARK: - Playback (forwards directly onto the SHARED player — no view-model layer needed
    // once there's no composition to own)

    private func togglePlayback(player: AVPlayer) {
        if state.isPlaying {
            state.pause()
            player.pause()
        } else {
            // Replay from the top if we're already sitting at (or past) the end — mirrors CapCut/
            // every video app's "tap play after it finished" convention.
            if state.currentTime >= state.clampTime(state.totalDuration) - 0.05 {
                state.currentTime = 0
                let time = CMTime(seconds: 0, preferredTimescale: 600)
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            state.play()
            player.play()
        }
    }

    // Pauses playback while the user drags and marks the shared scrub state. EditorView owns the
    // one serialized seek engine for both inline and fullscreen surfaces.
    private func beginScrubbing(player: AVPlayer) {
        guard !isScrubbing else { return }
        isScrubbing = true
        state.isScrubbing = true
        player.pause()
    }

    /// Live-updates the shared clock as the finger moves — the scrubber view reads
    /// `state.currentTime` directly, so this is the ONLY write needed during the drag itself.
    /// Routes through the shared `state.clampTime(_:)` (13-22 i3) so a drag to the very end
    /// settles on the last real frame instead of overshooting the composition's playable range.
    private func updateScrub(fraction: Double, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        state.currentTime = state.clampTime(fraction * totalDuration)
    }

    private func endScrubbing(player: AVPlayer) {
        isScrubbing = false
        // EditorView observes this transition and serializes the precise landing behind any
        // active mid-drag seek, then resumes playback if it was active before the drag.
        state.isScrubbing = false
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
