// FullScreenVideoPlayerView.swift
// Fantasia
// Full-screen AVQueuePlayer with looping, landscape rotation, and dismiss (D-13–D-15, GAL-02).

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
    var failed: Bool = false
    var isPlaying: Bool = true

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
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.failed = true }
        }
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = false
        player.play()
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }
}

// FillingVideoPlayerView is declared in OnboardingVideoView.swift (module-internal).
// Reuse it here rather than redeclaring — same resizeAspectFill behaviour (D-13).

struct FullScreenVideoPlayerView: View {
    let videoUrl: URL
    var generationId: String? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: URLLoopingPlayerViewModel?
    @State private var contentOpacity: Double = 1

    var body: some View {
        ZStack {
            Group {
                Color.black.ignoresSafeArea()

                if let vm = viewModel {
                    if vm.failed {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.7))
                            Text("This video couldn't be loaded")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        // .resizeAspect (letterboxed): the whole generated frame stays visible,
                        // nothing cropped — this is a review/inspect view, not a feed.
                        FillingVideoPlayerView(player: vm.player, videoGravity: .resizeAspect)
                            .ignoresSafeArea()
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel?.togglePlayback() }

            if let vm = viewModel, !vm.failed, !vm.isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.85))
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.22)) {
                            contentOpacity = 0
                        }
                        Task {
                            try? await Task.sleep(for: .seconds(0.22))
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .opacity(contentOpacity)
        .background(TransparentFullScreenBackground())
        .onAppear {
            viewModel = URLLoopingPlayerViewModel(url: videoUrl, generationId: generationId)
            FantasiaAppDelegate.orientationLock = .allButUpsideDown
            UIViewController.attemptRotationToDeviceOrientation()
        }
        .onDisappear {
            viewModel?.player.pause()
            FantasiaAppDelegate.orientationLock = .portrait
            UIViewController.attemptRotationToDeviceOrientation()
        }
        .statusBar(hidden: true)
    }
}
