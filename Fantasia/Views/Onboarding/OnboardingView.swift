// OnboardingView.swift
// Fantasia
// Container for the 5-screen onboarding flow: video intro + 4 bubble-picker question screens.
// Screen 0: OnboardingVideoView (keep identical to Phase 3).
// Screens 1-4: BubblePickerView driven by currentPage.
// Q4 is conditional on the Q2 answer stored in answers["useCase"].
// Answers are cached to UserDefaults under "pendingOnboardingAnswers" for 06-06 post-auth persistence.

import SwiftUI

struct OnboardingView: View {
    var onComplete: () -> Void

    @State private var currentPage: Int = 0
    @State private var answers: [String: Set<String>] = [:]

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var conditionalQ4: OnboardingQuestion {
        OnboardingQuestionBank.conditionalQuestion(for: answers["useCase"] ?? [])
    }

    var body: some View {
        ZStack {
            Group {
                switch currentPage {
                case 0:
                    OnboardingVideoView(onContinue: { advance() })
                case 1:
                    questionScreen(OnboardingQuestionBank.q1)
                case 2:
                    questionScreen(OnboardingQuestionBank.q2)
                case 3:
                    questionScreen(OnboardingQuestionBank.q3)
                default:
                    questionScreen(conditionalQ4)
                }
            }
            .transition(pageTransition)
        }
        .ignoresSafeArea()
    }

    private func questionScreen(_ question: OnboardingQuestion) -> some View {
        ZStack {
            backgroundLayer
            BubblePickerView(
                question: question,
                onNext: { selections in
                    answers[question.id] = selections
                    advance()
                },
                onSkip: { advance() }
            )
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 6.0/255, green: 4.0/255, blue: 14.0/255)
            Color(red: 6.0/255, green: 4.0/255, blue: 14.0/255).opacity(0.63)
                .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    // Persists answers to UserDefaults so 06-06 can read them back after first sign-in
    // without changing OnboardingView's onComplete() signature.
    private func persistAnswersIfComplete() {
        guard currentPage >= 4 else { return }
        let encodable = answers.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: "pendingOnboardingAnswers")
        }
    }

    private func advance() {
        persistAnswersIfComplete()
        withAnimation(.easeOut(duration: 0.18)) {
            if currentPage >= 4 {
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
