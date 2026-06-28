// CheckInboxView.swift
// Fantasia
// Email-verification holding screen — UI-SPEC Screen 4 (LOCKED per CONTEXT.md).
//
// Shown after successful Auth.auth().createUser + sendEmailVerification.
// Also shown by ContentView routing when currentUser.isEmailVerified == false.
//
// Layout (top to bottom):
//   1. Same video + frost background as sign-up/sign-in screens
//   2. envelope.fill SF Symbol — 48pt, primary gradient fill
//   3. "Check your inbox" 24pt bold title
//   4. Two-tone: "We sent a verification link to" (dim) / {email} (white)
//   5. Resend feedback message (shown after resend attempt)
//   6. "Resend email" outline button (border only, no fill) — 48pt
//   7. "Already verified? Sign in →" 12pt link — signs out so ContentView routes to SignInView

import SwiftUI
import FirebaseAuth

struct CheckInboxView: View {
    let email: String

    @State private var videoViewModel = LoopingPlayerViewModel(videoName: "onboarding-sample")
    @State private var isResending = false
    @State private var resendMessage: String? = nil

    // Design tokens (UI-SPEC primary gradient)
    private let ctaGradient = LinearGradient(
        colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                 Color(red: 0.357, green: 0.561, blue: 0.851)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Body

    var body: some View {
        ZStack {
            videoBackground
            frostOverlay

            VStack(spacing: 16) {
                Spacer()

                // envelope.fill SF Symbol — 48pt, primary gradient (UI-SPEC Screen 4)
                Image(systemName: "envelope.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(ctaGradient)
                    .accessibilityHidden(true)

                Text("Check your inbox")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                // Two-tone text: dim label + bright email address
                VStack(spacing: 4) {
                    Text("We sent a verification link to")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text(email)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .multilineTextAlignment(.center)

                if let resendMessage {
                    Text(resendMessage)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }

                resendButton
                    .padding(.top, 8)

                // "Already verified? Sign in →" — signs out so ContentView routes back to SignInView.
                // signOut() works whether this view is shown from ContentView routing (top-level)
                // or from within the SignUpView navigation stack.
                Button {
                    try? Auth.auth().signOut()
                } label: {
                    Text("Already verified? Sign in →")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.top, 8)
                // 44pt effective tap area via surrounding padding

                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // D-04: 0.85x playback rate
            videoViewModel.player.rate = 0.85
        }
    }

    // MARK: - Background layers

    private var videoBackground: some View {
        Group {
            if videoViewModel.hasVideo {
                FillingVideoPlayerView(player: videoViewModel.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onDisappear {
                        videoViewModel.player.pause()
                    }
            }
        }
    }

    /// D-05: rgba(6, 4, 14, 0.63) + .ultraThinMaterial
    private var frostOverlay: some View {
        ZStack {
            Color(red: 6.0 / 255, green: 4.0 / 255, blue: 14.0 / 255)
                .opacity(0.63)
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    // MARK: - Resend button

    /// Outline-only button (border, no fill) per UI-SPEC Screen 4.
    private var resendButton: some View {
        Button {
            Task { await resendVerification() }
        } label: {
            Group {
                if isResending {
                    ProgressView().tint(.white)
                } else {
                    Text("Resend email")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            }
        }
        .disabled(isResending)
        // T-06-04-01: Firebase Auth enforces server-side rate limits on resend; no client-side
        // rate limiting added.
    }

    // MARK: - Resend action

    private func resendVerification() async {
        isResending = true
        resendMessage = nil
        do {
            try await Auth.auth().currentUser?.sendEmailVerification()
            resendMessage = "Verification email resent."
        } catch {
            resendMessage = "Could not resend. Try again shortly."
        }
        isResending = false
    }
}

#Preview {
    CheckInboxView(email: "user@example.com")
}
