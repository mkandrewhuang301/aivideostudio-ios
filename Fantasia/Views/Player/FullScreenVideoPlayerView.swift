// FullScreenVideoPlayerView.swift
// Fantasia
// Full-screen AVQueuePlayer with looping, landscape rotation, and dismiss (D-13–D-15, GAL-02).
// YouTube-style chrome: tap the video to toggle controls (auto-hides after 3s while playing),
// tap the letterbox to hide, center play/pause toggles playback without hiding chrome, and the
// bottom bar is anchored to the video's own aspect-fit rect rather than the screen bottom.

import SwiftUI
import AVFoundation

// URL-based looping player ViewModel — analog of OnboardingVideoView's LoopingPlayerViewModel
// but init(url:) instead of init(videoName:), and audio is NOT muted (full-screen has audio).
// Observes the player item's status so a load failure (e.g. expired presigned URL, network
// error) surfaces as a visible error state instead of leaving the screen permanently black.
@Observable
@MainActor
private final class URLLoopingPlayerViewModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var timeObserverToken: Any?
    private var isScrubbing = false
    private var wasPlayingBeforeScrub = false
    var failed: Bool = false
    var isPlaying: Bool = true
    var currentTime: Double = 0
    var duration: Double = 0
    /// Natural (untransformed) pixel size of the video — becomes non-zero once the item loads.
    /// Drives the aspect-fit video rect used to anchor the bottom bar and route letterbox taps.
    var naturalSize: CGSize = .zero

    init(url: URL, generationId: String?) {
        player = AVQueuePlayer()
        // Play from disk if we've already downloaded this generation's video — instant,
        // no network wait. Otherwise stream from the (rotating) presigned URL and warm the
        // cache in the background so the next open is instant.
        let playbackURL: URL
        if let id = generationId, let cached = VideoCache.shared.cachedURL(for: id) {
            playbackURL = cached
        } else {
            playbackURL = url
            if let id = generationId {
                VideoCache.shared.prefetch(id: id, remoteURL: url)
            }
        }
        let item = AVPlayerItem(url: playbackURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = false
        // Silent-switch fix: the app's default .ambient audio session category mutes
        // playback whenever the ringer switch is on silent, even with volume turned up.
        // .playback ignores the switch — required for a video player with sound. Scoped
        // here rather than app launch so the muted onboarding/feed surfaces never
        // interrupt the user's background audio (e.g. Spotify); opening this full-screen
        // player is the moment taking over audio is expected.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()

        // Observe the player's currentItem, not the templateItem passed to AVPlayerLooper —
        // the looper manages its own item copies internally, so the templateItem's own
        // status/duration KVO never reliably fires once looping is set up.
        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor in self?.failed = true }
        }
        durationObservation = player.observe(\.currentItem?.duration, options: [.new, .initial]) { [weak self] player, _ in
            guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite else { return }
            Task { @MainActor in self?.duration = seconds }
        }
        presentationSizeObservation = player.observe(\.currentItem?.presentationSize, options: [.new, .initial]) { [weak self] player, _ in
            guard let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return }
            Task { @MainActor in self?.naturalSize = size }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    // Pauses playback while the user drags the scrubber so it doesn't fight the periodic
    // time observer, then resumes (if it was playing) once the drag ends.
    func beginScrubbing() {
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        player.pause()
    }

    func endScrubbing() {
        // Seek the current item, not the queue player: AVPlayerLooper tracks item-boundary
        // notifications to manage its loop queue, and a player-level seek desyncs that state
        // (the visible frame drifts from the reported scrubber position). Item-level seeks
        // don't touch the queue, so the looper stays consistent.
        let time = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.currentItem?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
        isScrubbing = false
        if wasPlayingBeforeScrub { player.play() }
    }

    func detachTimeObserver() {
        if let timeObserverToken { player.removeTimeObserver(timeObserverToken) }
        timeObserverToken = nil
        durationObservation = nil
        presentationSizeObservation = nil
    }
}

// FillingVideoPlayerView is declared in OnboardingVideoView.swift (module-internal).
// Reuse it here rather than redeclaring — same resizeAspectFill behaviour (D-13).

// Custom scrubber, not the system Slider — SwiftUI's Slider thumb is a fixed system size
// with no supported way to shrink it, so this draws its own small thumb + track for the
// QuickTime-style bar's proportions.
private struct ScrubberView: View {
    var vm: URLLoopingPlayerViewModel
    var trackColor: Color = .white
    var onInteract: () -> Void = {}
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let progress = vm.duration > 0 ? min(max(vm.currentTime / vm.duration, 0), 1) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor.opacity(0.3))
                    .frame(height: 3)
                Capsule()
                    .fill(trackColor)
                    .frame(width: width * progress, height: 3)
                Circle()
                    .fill(trackColor)
                    .frame(width: 10, height: 10)
                    .offset(x: width * progress - 5)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            vm.beginScrubbing()
                        }
                        onInteract()
                        let fraction = min(max(value.location.x / width, 0), 1)
                        vm.currentTime = fraction * vm.duration
                    }
                    .onEnded { _ in
                        isDragging = false
                        vm.endScrubbing()
                        onInteract()
                    }
            )
        }
        .frame(height: 24)
    }
}

struct FullScreenVideoPlayerView: View {
    let videoUrl: URL
    var generationId: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    @State private var viewModel: URLLoopingPlayerViewModel?
    @State private var contentOpacity: Double = 1
    @State private var isDismissing = false
    @State private var dragOffset: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let dismissDistanceThreshold: CGFloat = 120
    // Legacy path only (see dismissDragGesture below) — SwiftUI DragGesture has no true
    // velocity, so this is calibrated against predictedEndTranslation - translation instead.
    private let dismissVelocityThreshold: CGFloat = 800
    // Native path (ZoomPanScrollView) — true gesture velocity in points/second, a different
    // scale than the legacy approximation above, so calibrated separately.
    private let nativeDismissVelocityThreshold: CGFloat = 1200

    /// 0...1 progress of an in-flight swipe-to-dismiss drag (mirrors FullScreenImageView).
    /// Divisor is larger than the 120pt dismiss-distance threshold so the live fade lags
    /// behind the finger — a full swipe-to-dismiss drag no longer fully fades the background
    /// until well past the point where the dismiss itself would already commit.
    private var dismissProgress: CGFloat {
        guard zoomScale <= 1.01 else { return 0 }
        return min(1, abs(dragOffset.height) / 500)
    }

    /// Drives the background/chrome "reveal" fade. While dragging, tracks live drag distance
    /// (dismissProgress) for real-time feedback. Once the dismiss is committed, switches to
    /// contentOpacity instead — dismissProgress saturates almost immediately once the exit
    /// animation starts moving past its 300pt cap, which made the reveal fade feel instant
    /// no matter how long the fly-out animation was. contentOpacity animates independently
    /// (see performDismiss) so the fade can be slower than the fly-out.
    private var revealOpacity: CGFloat {
        isDismissing ? contentOpacity : (1 - dismissProgress)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = videoRect(containerSize: geo.size)

            ZStack {
                // Pinned full-screen and outside the scaled/offset Group below (mirrors
                // FullScreenImageView): only fades via opacity as the drag progresses. If this
                // moved/scaled together with the video it would shrink and slide away from
                // it, exposing a hard black-rectangle edge against the transparent cover
                // (TransparentFullScreenBackground) partway through the swipe-to-dismiss drag.
                theme.background.ignoresSafeArea()
                    .opacity(revealOpacity)

                Group {
                    if let vm = viewModel {
                        if vm.failed {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 28))
                                    .foregroundStyle(theme.textSecondary)
                                Text("This video couldn't be loaded")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(dismissDragGesture)
                            .simultaneousGesture(SpatialTapGesture().onEnded { _ in toggleControls() })
                        } else {
                            // .resizeAspect (letterboxed): the whole generated frame stays visible,
                            // nothing cropped — this is a review/inspect view, not a feed. Sized to
                            // the AVPlayerLayer's own PlayerView class (FillingVideoPlayerView.swift)
                            // rather than duplicating an AVPlayerLayer-backed UIView here.
                            ZoomPanScrollView(
                                makeContentView: {
                                    let view = FillingVideoPlayerView.PlayerView()
                                    view.playerLayer.videoGravity = .resizeAspect
                                    return view
                                },
                                updateContentView: { (view: FillingVideoPlayerView.PlayerView) in
                                    view.playerLayer.player = vm.player
                                },
                                contentSize: rect.size,
                                onUnzoomedPan: { translation, velocity, state in
                                    handleUnzoomedPan(translation: translation, velocity: velocity, state: state)
                                },
                                onSingleTap: { toggleControls() },
                                onZoomChanged: { zoomScale = $0 }
                            )
                            .ignoresSafeArea()
                        }
                    }
                }
                .scaleEffect(1 - dismissProgress * 0.15)
                .offset(dragOffset)

                // Loading spinner while the video buffers (before its first frame /
                // presentationSize is known). Tinted theme.textPrimary so it reads black in
                // light mode and white in dark mode — mirrors FullScreenImageView.
                if let vm = viewModel, !vm.failed, vm.naturalSize == .zero {
                    ProgressView()
                        .tint(theme.textPrimary)
                        .opacity(revealOpacity)
                }

                if let vm = viewModel, !vm.failed, controlsVisible {
                    centerPlayPauseButton(vm: vm)
                        .position(x: rect.midX, y: rect.midY)
                        .transition(.opacity)
                        .opacity(revealOpacity)
                }

                // Close button stays visible even when the rest of the chrome (center
                // play/pause + scrubber) is toggled off by a tap, so the user always has an
                // exit affordance. Only fades out during a swipe-to-dismiss drag, mirroring
                // FullScreenImageView.
                VStack {
                    HStack {
                        Spacer()
                        closeButton
                    }
                    Spacer()
                }
                // Ignore the top safe area (status bar is hidden here) so the X rides up to
                // roughly where the detail sheet's ("pullover") close button sat before the
                // user tapped into full screen, rather than sitting a full inset lower. The
                // trailing alignment keeps it clear of the centered notch / Dynamic Island.
                .ignoresSafeArea()
                .opacity(revealOpacity)

                if let vm = viewModel, !vm.failed, vm.duration > 0, controlsVisible {
                    playbackControlBar(vm: vm)
                        // Anchored to the video's own aspect-fit rect, not the screen bottom —
                        // for a 16:9 video in portrait this sits just under the letterboxed
                        // frame instead of floating far below it against black space.
                        .position(
                            x: geo.size.width / 2,
                            y: min(rect.maxY - 48, geo.size.height - 60)
                        )
                        .transition(.opacity)
                        .opacity(revealOpacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        }
        .background(TransparentFullScreenBackground())
        .onAppear {
            viewModel = URLLoopingPlayerViewModel(url: videoUrl, generationId: generationId)
            FantasiaAppDelegate.orientationLock = .allButUpsideDown
            UIViewController.attemptRotationToDeviceOrientation()
            scheduleAutoHide()
        }
        .onDisappear {
            hideTask?.cancel()
            viewModel?.detachTimeObserver()
            viewModel?.player.pause()
            // Hand audio focus back so any app we interrupted (e.g. Spotify) resumes.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            FantasiaAppDelegate.orientationLock = .portrait
            UIViewController.attemptRotationToDeviceOrientation()
        }
        .statusBar(hidden: true)
    }

    // Aspect-fit rect of the video within the container — drives both the bottom bar's
    // position and letterbox-vs-video tap routing. Falls back to the full container before
    // presentationSize loads.
    private func videoRect(containerSize: CGSize) -> CGRect {
        guard let size = viewModel?.naturalSize, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        return AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: containerSize))
    }

    private func toggleControls() {
        setControlsVisible(!controlsVisible)
    }

    private func setControlsVisible(_ visible: Bool) {
        guard controlsVisible != visible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = visible }
        if visible {
            scheduleAutoHide()
        } else {
            hideTask?.cancel()
        }
    }

    // Auto-hides chrome after 3s of playback with no interaction; never hides while paused.
    // Swift Concurrency only — no Timer (CLAUDE.md).
    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, viewModel?.isPlaying == true else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    // Swipe down (or up) to dismiss, requiring a predominantly-vertical drag so it doesn't
    // fight the scrubber's horizontal drag or the tap-to-toggle-controls gesture.
    // Legacy SwiftUI-gesture path — only reachable in the vm.failed branch above, where there's
    // no video to zoom so ZoomPanScrollView (and its native pan) isn't in the view tree.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = .zero }
                    return
                }
                let velocity = abs(value.predictedEndTranslation.height - value.translation.height)
                evaluateDismissDrag(translation: value.translation, velocityHeight: velocity, velocityThreshold: dismissVelocityThreshold)
            }
    }

    // Driven by ZoomPanScrollView's UIPanGestureRecognizer, which only forwards while unzoomed —
    // zoomed-in panning is handled natively by the UIScrollView itself. Mirrors dismissDragGesture
    // above but reads real gesture velocity instead of DragGesture's predictedEndTranslation.
    private func handleUnzoomedPan(translation: CGSize, velocity: CGSize, state: UIGestureRecognizer.State) {
        switch state {
        case .began, .changed:
            guard abs(translation.height) > abs(translation.width) else { return }
            dragOffset = translation
        case .ended, .cancelled:
            guard abs(translation.height) > abs(translation.width) else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = .zero }
                return
            }
            evaluateDismissDrag(translation: translation, velocityHeight: velocity.height, velocityThreshold: nativeDismissVelocityThreshold)
        default:
            break
        }
    }

    private func evaluateDismissDrag(translation: CGSize, velocityHeight: CGFloat, velocityThreshold: CGFloat) {
        if abs(translation.height) > dismissDistanceThreshold || abs(velocityHeight) > velocityThreshold {
            let exitHeight: CGFloat = translation.height > 0 ? 900 : -900
            performDismiss(exitOffset: CGSize(width: translation.width, height: exitHeight))
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = .zero }
        }
    }

    private func performDismiss(exitOffset: CGSize) {
        // Snapshot the live drag-based fade into contentOpacity (no animation — this is just
        // a baseline handoff) before switching revealOpacity over to it, so there's no visual
        // jump at the moment of release.
        var noAnimation = Transaction()
        noAnimation.disablesAnimations = true
        withTransaction(noAnimation) { contentOpacity = 1 - dismissProgress }
        isDismissing = true

        // Fly-out (position) stays quick; the reveal fade runs slower and independently so
        // the background doesn't finish fading before the video has visibly moved.
        withAnimation(.easeOut(duration: 0.22)) {
            dragOffset = exitOffset
        }
        withAnimation(.easeOut(duration: 0.45)) {
            contentOpacity = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            dismiss()
        }
    }

    private var closeButton: some View {
        Button {
            performDismiss(exitOffset: dragOffset)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(theme.textPrimary.opacity(0.85))
                .padding(20)
        }
    }

    // Semi-transparent circled play/pause overlaid on the video — tapping it toggles playback
    // without hiding chrome (only the background/letterbox taps toggle/hide chrome).
    private func centerPlayPauseButton(vm: URLLoopingPlayerViewModel) -> some View {
        Button {
            vm.togglePlayback()
            if vm.isPlaying { scheduleAutoHide() } else { hideTask?.cancel() }
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
    }

    // QuickTime-style bar: play/pause on the left, scrubber in the middle, elapsed/total on
    // the right. Dragging the scrubber pauses tracking of live playback time until release
    // (see beginScrubbing/endScrubbing) so the thumb doesn't jump under the user's finger.
    @ViewBuilder
    private func playbackControlBar(vm: URLLoopingPlayerViewModel) -> some View {
        HStack(spacing: 12) {
            Button {
                vm.togglePlayback()
                if vm.isPlaying { scheduleAutoHide() } else { hideTask?.cancel() }
            } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            ScrubberView(vm: vm, trackColor: theme.textPrimary, onInteract: scheduleAutoHide)

            Text("\(formatTime(vm.currentTime)) / \(formatTime(vm.duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.textPrimary.opacity(0.85))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
