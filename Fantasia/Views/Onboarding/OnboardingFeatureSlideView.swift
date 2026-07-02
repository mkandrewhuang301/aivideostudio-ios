// OnboardingFeatureSlideView.swift
// Fantasia
// Full-screen feature carousel slide (slides 2-4 of onboarding).
// Mirrors OnboardingVideoView aesthetic: full-bleed video (with gradient fallback),
// bottom scrim, headline + subtitle, glass CTA, 4-dot carousel indicator.

import SwiftUI
import AVKit
import AVFoundation

struct OnboardingFeatureSlide {
    let videoName: String?
    let headline: String
    let subtitle: String
    let ctaLabel: String
}

struct OnboardingFeatureSlideView: View {
    let slide: OnboardingFeatureSlide
    let pageIndex: Int
    let totalPages: Int
    var onContinue: () -> Void

    @State private var videoViewModel: LoopingPlayerViewModel?

    private let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.059, green: 0.059, blue: 0.067),
                 Color(red: 0.04, green: 0.04, blue: 0.05)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            if let vm = videoViewModel, vm.hasVideo {
                FillingVideoPlayerView(player: vm.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onDisappear { vm.player.pause() }
            }

            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.55)
                .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text(slide.headline)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(3)

                    Text(slide.subtitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 32)

                Button { onContinue() } label: {
                    Text(slide.ctaLabel)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            ZStack {
                                Color.white.opacity(0.15)
                                Rectangle().fill(.ultraThinMaterial)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        }
                }
                .accessibilityLabel(slide.ctaLabel)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                carouselDots
                    .padding(.top, 14)
                    .padding(.bottom, 48)
            }
        }
        .onAppear {
            if let name = slide.videoName {
                videoViewModel = LoopingPlayerViewModel(videoName: name)
            }
        }
    }

    private var carouselDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<totalPages, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == pageIndex ? 1 : 0.3))
                    .frame(width: i == pageIndex ? 16 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.25), value: pageIndex)
    }
}
