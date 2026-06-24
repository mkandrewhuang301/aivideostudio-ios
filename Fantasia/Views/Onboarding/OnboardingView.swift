// OnboardingView.swift
// Fantasia
// Container for the 2-screen onboarding flow.
// Uses TabView with .tabViewStyle(.page) for programmatic page navigation.
// UI-SPEC: No page indicators (UIPageControl hidden). No back affordance.
// D-12: Exactly 2 screens. "Get Started" on screen 2 calls onComplete() → ContentView advances.

import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage: Int = 0

    var body: some View {
        TabView(selection: $currentPage) {
            OnboardingVideoView(onContinue: {
                withAnimation(.easeInOut(duration: 0.35)) {
                    currentPage = 1
                }
            })
            .tag(0)

            OnboardingFeaturesView(onGetStarted: {
                onComplete()
            })
            .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never)) // Hide page dots (D-12: no page indicator)
        .ignoresSafeArea()
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
