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
// playing). Now builds the SAME EditorCompositionBuilder composition the inline player uses
// (F1's whole point: ONE shared assembly, not two divergent ones), on a plain `AVPlayer` — no
// looper. It plays through the WHOLE project sequentially exactly once and auto-pauses at the
// end; the periodic time observer clamps to `[0, totalDuration]` instead of writing a raw
// (possibly looped-negative-or-huge) local time.
//
// Still bound to the SAME shared `EditorState.currentTime`/`isPlaying` clock instead of a
// separate, locally-owned time/isPlaying pair, so scrubbing here always stays in sync with the
// inline editor once the user minimizes back. No pan-to-dismiss/zoom (not required here per
// 13-UI-SPEC.md) — a single explicit minimize control instead.
//
// EditorView pauses its own inline AVPlayer while this is presented (and reconciles position back
// on minimize) so the two players' periodic time observers never race writes onto the same
// `EditorState.currentTime` at once — confirmed still correct with this rewrite: only ONE of the
// two AVPlayers (inline XOR fullscreen) is ever playing/observing at a time.
//
// Layers CaptionOverlayView (SC5, live karaoke) and TextOverlayCanvasView (SC3) on top of the
// video, exactly per Delta 6 — the fullscreen surface renders the same overlays the inline preview
// does. TextOverlayCanvasView is read-only here (`.allowsHitTesting(false)`) since fullscreen is a
// preview-only surface, not an editing one.

import SwiftUI
import AVFoundation

@Observable
@MainActor
private final class EditorFullscreenPlayerViewModel {
    private(set) var player: AVPlayer?
    private var timeObserverToken: Any?
    private var isScrubbing = false
    private let state: EditorState

    init(state: EditorState) {
        self.state = state
    }

    /// Async setup (composition assembly awaits each clip's tracks) — builds the SAME multi-clip
    /// composition EditorView.rebuildPlayer() uses (F1), then seeks to wherever the inline
    /// editor's playhead already is (the shared clock), not to 0.
    func load() async {
        guard let (composition, _) = await EditorCompositionBuilder.build(clips: state.project.clips) else { return }

        let item = AVPlayerItem(asset: composition)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        let seekTime = CMTime(seconds: state.currentTime, preferredTimescale: 600)
        await avPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if state.isPlaying { avPlayer.play() }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                let total = self.state.totalDuration
                // Clamp instead of writing the raw observer time (F1) — no looper means this can
                // briefly read past the end right before AVPlayer settles at the item boundary.
                self.state.currentTime = min(max(time.seconds, 0), total)
                if self.state.isPlaying, total > 0, time.seconds >= total - 0.05 {
                    self.state.isPlaying = false
                    self.player?.pause()
                }
            }
        }
    }

    func togglePlayback() {
        if state.isPlaying {
            state.pause()
            player?.pause()
        } else {
            // Replay from the top if we're already sitting at (or past) the end — mirrors CapCut/
            // every video app's "tap play after it finished" convention.
            if state.currentTime >= state.totalDuration - 0.05 {
                state.currentTime = 0
                let time = CMTime(seconds: 0, preferredTimescale: 600)
                player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            state.play()
            player?.play()
        }
    }

    // Pauses playback while the user drags the scrubber, mirroring FullScreenVideoPlayerView's
    // beginScrubbing/endScrubbing so the periodic time observer doesn't fight the live drag.
    func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        player?.pause()
    }

    /// Live-updates the shared clock as the finger moves — the scrubber view reads
    /// `state.currentTime` directly, so this is the ONLY write needed during the drag itself.
    /// `totalDuration` here is the WHOLE project's duration (F1) — the scrubber spans every clip,
    /// not just the fullscreen player's original single asset.
    func updateScrub(fraction: Double, totalDuration: Double) {
        guard totalDuration > 0 else { return }
        state.currentTime = min(max(fraction * totalDuration, 0), totalDuration)
    }

    func endScrubbing() {
        let time = CMTime(seconds: state.currentTime, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        isScrubbing = false
        if state.isPlaying { player?.play() }
    }

    func tearDown() {
        if let timeObserverToken { player?.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
        player?.pause()
    }
}

struct FullscreenEditorPlayerView: View {
    let state: EditorState
    let onMinimize: () -> Void

    @State private var viewModel: EditorFullscreenPlayerViewModel?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // F1: `vm.player` is now optional (composition assembly is async) — both the
                // player surface AND the control bar wait on it, not just the view model's own
                // presence, so nothing renders a stale/blank player mid-load.
                if let vm = viewModel, let avPlayer = vm.player {
                    FillingVideoPlayerView(player: avPlayer, videoGravity: .resizeAspect)
                        .ignoresSafeArea()
                        .overlay {
                            TextOverlayCanvasView(state: state)
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            CaptionOverlayView(state: state)
                        }
                } else {
                    ProgressView().tint(.white)
                }

                VStack {
                    HStack {
                        Spacer()
                        minimizeButton
                    }
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .padding(.trailing, 12)

                    Spacer()

                    if let vm = viewModel, vm.player != nil {
                        playbackControlBar(vm: vm)
                            .padding(.bottom, max(geo.safeAreaInsets.bottom, 16))
                    }
                }
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            let vm = EditorFullscreenPlayerViewModel(state: state)
            viewModel = vm
            Task { await vm.load() }
        }
        .onDisappear {
            viewModel?.tearDown()
            viewModel = nil
        }
    }

    private var minimizeButton: some View {
        Button(action: onMinimize) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel("Minimize")
    }

    // MARK: - Playback control bar: play/pause + scrubber + elapsed/total (mirrors
    // FullScreenVideoPlayerView's playbackControlBar, bound to the shared EditorState clock)

    private func playbackControlBar(vm: EditorFullscreenPlayerViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                vm.togglePlayback()
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            scrubber(vm: vm)

            Text("\(formatTime(state.currentTime)) / \(formatTime(state.totalDuration))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func scrubber(vm: EditorFullscreenPlayerViewModel) -> some View {
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
                        vm.beginScrubbing()
                        let fraction = min(max(value.location.x / width, 0), 1)
                        vm.updateScrub(fraction: fraction, totalDuration: total)
                    }
                    .onEnded { _ in vm.endScrubbing() }
            )
        }
        .frame(height: 24)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
