// FullScreenVideoPlayerView.swift
// Fantasia
// Full-screen AVQueuePlayer with looping, landscape rotation, and dismiss (D-13–D-15, GAL-02).

import SwiftUI
import AVFoundation

// URL-based looping player ViewModel — analog of OnboardingVideoView's LoopingPlayerViewModel
// but init(url:) instead of init(videoName:), and audio is NOT muted (full-screen has audio).
@Observable
@MainActor
private final class URLLoopingPlayerViewModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?

    init(url: URL) {
        player = AVQueuePlayer()
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = false
        player.play()
    }
}

// FillingVideoPlayerView is declared in OnboardingVideoView.swift (module-internal).
// Reuse it here rather than redeclaring — same resizeAspectFill behaviour (D-13).

struct FullScreenVideoPlayerView: View {
    let videoUrl: URL
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: URLLoopingPlayerViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let vm = viewModel {
                FillingVideoPlayerView(player: vm.player)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
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
        .onAppear {
            viewModel = URLLoopingPlayerViewModel(url: videoUrl)
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
