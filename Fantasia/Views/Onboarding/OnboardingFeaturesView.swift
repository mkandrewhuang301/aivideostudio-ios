// OnboardingFeaturesView.swift
// Fantasia
// Onboarding screen 2: 3 feature lines + "Get Started" CTA.
// D-12: No back button. "Get Started" sets hasCompletedOnboarding via onGetStarted callback.

import SwiftUI

struct OnboardingFeaturesView: View {
    var onGetStarted: () -> Void

    private let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.10, blue: 0.18), Color(red: 0.07, green: 0.07, blue: 0.16)],
        startPoint: .top, endPoint: .bottom
    )
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private struct Feature {
        let icon: String
        let text: String
    }

    private let features: [Feature] = [
        Feature(icon: "text.cursor",         text: "Generate from text or image"),
        Feature(icon: "slider.horizontal.3", text: "Choose your model and parameters"),
        Feature(icon: "photo.stack",         text: "Gallery of everything you've created"),
    ]

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 64) // 3xl — from top safe area

                VStack(alignment: .leading, spacing: 32) { // xl between sections
                    // Wordmark block
                    VStack(alignment: .leading, spacing: 8) { // sm
                        Text("Fantasia")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Everything you need to create.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    // Feature list
                    VStack(alignment: .leading, spacing: 32) { // xl between rows
                        ForEach(features, id: \.text) { feature in
                            HStack(alignment: .top, spacing: 16) { // md
                                Image(systemName: feature.icon)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(feature.text)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24) // lg

                Spacer()

                // CTA
                VStack(spacing: 16) { // md
                    Button {
                        onGetStarted()
                    } label: {
                        Text("Get Started")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48) // 2xl above safe area
            }
        }
    }
}
