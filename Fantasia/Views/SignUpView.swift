// SignUpView.swift
// Fantasia
// Sign-up form — UI-SPEC Screen 3 (LOCKED per CONTEXT.md).
//
// Layout (top to bottom):
//   1. Video background (onboarding-sample.mp4, 0.85x) + frost overlay (D-04, D-05)
//   2. "Create account" 24pt bold title
//   3. Email glass field
//   4. Password glass field
//   5. Confirm Password glass field
//   6. Passwords-do-not-match inline error (shown when mismatch)
//   7. Firebase error message (shown on submit failure)
//   8. "Create Account" gradient CTA (disabled until email non-empty + passwords match)
//   [← Back] chevron button overlay (top-left)
//
// On success: Auth.auth().createUser + sendEmailVerification, then navigate to CheckInboxView.
// ContentView routing check (!isEmailVerified) will also gate the user at that screen.

import SwiftUI
import FirebaseAuth

struct SignUpView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String? = nil
    @State private var isLoading = false
    @State private var navigateToCheckInbox = false

    // Video background — same pattern as SignInView (LoopingPlayerViewModel + FillingVideoPlayerView)
    @State private var videoViewModel = LoopingPlayerViewModel(videoName: "onboarding-sample")

    @Environment(\.dismiss) private var dismiss

    // Three independent FocusState booleans — GlassTextField's isFocused is
    // FocusState<Bool>.Binding; a single-enum approach is not supported by the API
    // (confirmed in 06-03 SUMMARY decision).
    @FocusState private var emailFocused: Bool
    @FocusState private var passwordFocused: Bool
    @FocusState private var confirmPasswordFocused: Bool

    // MARK: - Design tokens (UI-SPEC Screen 3 — identical to SignInView)
    private let ctaGradient = LinearGradient(
        colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                 Color(red: 0.357, green: 0.561, blue: 0.851)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    private let purpleAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

    // MARK: - Validation

    private var passwordsMatch: Bool {
        !password.isEmpty && password == confirmPassword
    }

    private var canSubmit: Bool {
        !email.isEmpty && passwordsMatch && !isLoading
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            videoBackground
            frostOverlay
            formContent
            backButton
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $navigateToCheckInbox) {
            CheckInboxView(email: email)
        }
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

    /// D-05: rgba(6, 4, 14, 0.63) tint + .ultraThinMaterial approximating blur(23) saturate(1.25).
    private var frostOverlay: some View {
        ZStack {
            Color(red: 6.0 / 255, green: 4.0 / 255, blue: 14.0 / 255)
                .opacity(0.63)
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    // MARK: - Form content

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                Spacer().frame(height: 80)

                Text("Create account")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Spacer().frame(height: 8)

                GlassTextField(
                    placeholder: "Email",
                    text: $email,
                    isSecure: false,
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    isFocused: $emailFocused
                )

                GlassTextField(
                    placeholder: "Password",
                    text: $password,
                    isSecure: true,
                    textContentType: .newPassword,
                    isFocused: $passwordFocused
                )

                GlassTextField(
                    placeholder: "Confirm Password",
                    text: $confirmPassword,
                    isSecure: true,
                    textContentType: .newPassword,
                    isFocused: $confirmPasswordFocused
                )

                // Inline passwords-mismatch warning — only shown after user has typed
                if !confirmPassword.isEmpty && !passwordsMatch {
                    Text("Passwords do not match")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Firebase error message — T-06-04-02: generic strings only (no raw Firebase text)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                createAccountButton
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Create Account button

    private var createAccountButton: some View {
        Button {
            Task { await submitSignUp() }
        } label: {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Create Account")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(ctaGradient, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: purpleAccent.opacity(0.45), radius: 24, y: 4)
        }
        .disabled(!canSubmit)
        .opacity(canSubmit ? 1.0 : 0.5)
        // 44pt minimum touch target satisfied by the 52pt frame height
    }

    // MARK: - Back button overlay

    private var backButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
            Spacer()
        }
    }

    // MARK: - Sign-up submission

    /// Creates a Firebase account, sends verification email, then navigates to CheckInboxView.
    ///
    /// ContentView's email-verification routing gate (!isEmailVerified → CheckInboxView) handles
    /// the case where ContentView routes away before this navigation fires. Either way, the user
    /// lands on CheckInboxView.
    ///
    /// T-06-04-02: AuthErrorCode switch maps to generic user-facing strings —
    /// raw Firebase error text is never displayed to the user.
    private func submitSignUp() async {
        guard canSubmit else { return }
        isLoading = true
        errorMessage = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            try await result.user.sendEmailVerification()
            // navigateToCheckInbox fires the NavigationStack push within SignInView's stack.
            // If ContentView has already routed away (due to currentUser becoming non-nil),
            // the ContentView-level isEmailVerified routing gate catches the user at CheckInboxView.
            navigateToCheckInbox = true
        } catch let error as NSError {
            let code = AuthErrorCode(rawValue: error.code)
            switch code {
            case .weakPassword:
                errorMessage = "Password must be at least 6 characters"
            case .emailAlreadyInUse:
                errorMessage = "An account with this email already exists"
            case .invalidEmail:
                errorMessage = "Enter a valid email address"
            default:
                errorMessage = "Sign-up failed. Please try again."
            }
        }
        isLoading = false
    }
}

#Preview {
    NavigationStack { SignUpView() }
}
