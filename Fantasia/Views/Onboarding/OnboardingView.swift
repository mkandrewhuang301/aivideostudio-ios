// OnboardingView.swift
// Fantasia
// Container for the 2-screen onboarding flow.
// Plain conditional switch (not TabView) — TabView's .page style always animates as a
// horizontal slide; a short scale+fade ("coming toward you") is used instead, no sideways motion.
// UI-SPEC: No page indicators. No swipe — navigation is button-only (Continue / back).
// D-12: Exactly 2 screens. "Get Started" on screen 2 calls onComplete() → ContentView advances.

import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage: Int = 0

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .opacity
        )
    }

    var body: some View {
        ZStack {
            if currentPage == 0 {
                OnboardingVideoView(onContinue: {
                    withAnimation(.easeOut(duration: 0.18)) {
                        currentPage = 1
                    }
                })
                .transition(pageTransition)
            } else {
                OnboardingFeaturesView(
                    onGetStarted: {
                        onComplete()
                    },
                    onBack: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            currentPage = 0
                        }
                    }
                )
                .transition(pageTransition)
            }
        }
        .ignoresSafeArea()
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
