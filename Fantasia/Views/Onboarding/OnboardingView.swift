// OnboardingView.swift
// Fantasia
// 4-slide feature carousel onboarding.
// Slide 0: OnboardingVideoView (text-to-cinematic video, existing).
// Slides 1-3: OnboardingFeatureSlideView — motion transfer, try-on, ads/social.
// After slide 3: onComplete() → straight into app (deferred sign-in).

import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage: Int = 0

    private let featureSlides: [OnboardingFeatureSlide] = [
        .init(
            videoName: "onboarding-motion-transfer",
            headline: "Bring any image to life",
            subtitle: "Upload a photo and transform it into fluid, cinematic motion.",
            ctaLabel: "Continue →"
        ),
        .init(
            videoName: "onboarding-tryon",
            headline: "Try on any look instantly",
            subtitle: "See yourself wearing any outfit, style, or vibe.",
            ctaLabel: "Continue →"
        ),
        .init(
            videoName: "onboarding-social",
            headline: "Content that stops the scroll",
            subtitle: "Cinematic ads, reels, and clips — generated in seconds.",
            ctaLabel: "Get Started"
        ),
    ]

    private let totalPages = 4

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .opacity
        )
    }

    var body: some View {
        ZStack {
            Group {
                switch currentPage {
                case 0:
                    OnboardingVideoView(onContinue: { advance() })
                default:
                    let slideIndex = currentPage - 1
                    OnboardingFeatureSlideView(
                        slide: featureSlides[slideIndex],
                        activeDotIndex: slideIndex,
                        dotCount: featureSlides.count,
                        onContinue: { advance() }
                    )
                }
            }
            .id(currentPage)
            .transition(pageTransition)
        }
        .ignoresSafeArea()
        .task {
            // Issue 6: warm the backend during onboarding so it's already awake by the time a
            // first-launch user reaches sign-in.
            await APIClient.shared.pingHealth()
        }
    }

    private func advance() {
        withAnimation(.easeOut(duration: 0.18)) {
            if currentPage >= totalPages - 1 {
                onComplete()
            } else {
                currentPage += 1
            }
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
