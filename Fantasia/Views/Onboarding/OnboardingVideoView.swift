// OnboardingVideoView.swift
// Fantasia
// Onboarding screen 1: Full-bleed bundled video with gradient fallback.
// D-12: autoplay, loop, muted, no controls. Falls back to LinearGradient if asset missing.
// RESEARCH.md Pitfall 7: AVPlayer nil URL is handled gracefully.

import SwiftUI
import AVKit
import AVFoundation

// LoopingPlayerViewModel manages AVQueuePlayer + AVPlayerLooper for seamless looping.
// AVPlayerLooper requires AVQueuePlayer (not AVPlayer). Purpose-built for this pattern.
@Observable
@MainActor
final class LoopingPlayerViewModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    var hasVideo: Bool = false

    init(videoName: String) {
        player = AVQueuePlayer()
        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mp4") else {
            // Asset not yet bundled — gradient fallback shows (RESEARCH.md Pitfall 7)
            return
        }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        hasVideo = true
    }
}

struct OnboardingVideoView: View {
    var onContinue: () -> Void

    @State private var videoViewModel = LoopingPlayerViewModel(videoName: "onboarding-sample")

    private let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.059, green: 0.059, blue: 0.067),
                 Color(red: 0.04, green: 0.04, blue: 0.05)],
        startPoint: .top, endPoint: .bottom
    )
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        ZStack {
            // Layer 1: Background gradient (always visible — shows if video is missing)
            backgroundGradient
                .ignoresSafeArea()

            // Layer 2: AVPlayer video (only if asset is available)
            if videoViewModel.hasVideo {
                VideoPlayer(player: videoViewModel.player)
                    .disabled(true)            // No playback controls (D-12)
                    .ignoresSafeArea()
                    .accessibilityHidden(true) // Decorative content (UI-SPEC accessibility)
                    .onDisappear {
                        videoViewModel.player.pause()
                    }
            }

            // Layer 3: Bottom gradient scrim for text legibility
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.5)
                .ignoresSafeArea()
            }

            // Layer 4: Wordmark + tagline + Continue button, pinned to bottom
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fantasia")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.white)

                    Text("Cinematic AI videos. From a single thought.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 32) // xl

                Button {
                    onContinue()
                } label: {
                    Text("Continue →")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                }
                .accessibilityLabel("Continue to next step")
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
    }
}
