// SignInView.swift
// Fantasia
// Cinematic glass sign-in screen — UI-SPEC Screen 2 (Option A, LOCKED per CONTEXT.md).
//
// Layout order (CONTEXT.md items 1-9):
//   1. Video background (onboarding-sample.mp4, 0.85x) + frost overlay (D-04, D-05)
//   2. Wordmark "Fantasia" + tagline
//   3. Glass email field
//   4. Glass password field
//   5. Sign In CTA (gradient, 52pt)
//   6. "Don't have an account? Sign up" link
//   7. "or" divider
//   8. Sign in with Apple (AppleSignInCoordinator → AuthManager.signInWithApple)
//   9. Sign in with Google (AuthManager.signInWithGoogle)

import SwiftUI
import FirebaseAuth
import AuthenticationServices
import AVFoundation

// MARK: - AppleSignInCoordinator

/// Delegate-based coordinator wrapping ASAuthorizationController.
/// ASAuthorizationAppleIDProvider uses a callback-based API, not async/await —
/// this coordinator bridges it into the async SignInView flow.
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var onCompletion: ((Result<ASAuthorizationAppleIDCredential, Error>) -> Void)?

    func start(nonce: String) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce // caller passes sha256(rawNonce) per Apple anti-replay doc

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            Task { @MainActor in
                self.onCompletion?(.success(credential))
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            self.onCompletion?(.failure(error))
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// MARK: - SignInView

struct SignInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var emailError: String? = nil
    @State private var passwordError: String? = nil
    @State private var isAuthLoading = false
    @State private var passwordResetSent = false

    @State private var isSocialAuthLoading = false
    @State private var socialAuthError: String? = nil

    @State private var showSignUp = false

    // X button returns to onboarding — without this there is no way back from
    // sign-in once onboarding is marked complete (ContentView routes by this flag).
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    @Environment(AuthManager.self) private var authManager

    @FocusState private var emailFocused: Bool
    @FocusState private var passwordFocused: Bool

    // Video background — reuse LoopingPlayerViewModel from OnboardingVideoView (same pattern).
    @State private var videoViewModel = LoopingPlayerViewModel(videoName: "onboarding-sample")

    // Apple sign-in coordinator (holds delegate reference strongly to survive callback).
    @State private var appleCoordinator = AppleSignInCoordinator()

    // MARK: - Design tokens (UI-SPEC Screen 2)
    private let ctaGradient = LinearGradient(
        colors: [Color(red: 0.545, green: 0.427, blue: 0.839), Color(red: 0.357, green: 0.561, blue: 0.851)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    private let purpleAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        NavigationStack {
            ZStack {
                videoBackground
                frostOverlay
                mainContent
                backToOnboardingButton
            }
            .ignoresSafeArea()
            // Forward reference: SignUpView created in plan 06-04.
            .navigationDestination(isPresented: $showSignUp) {
                // TODO(06-04): Replace stub with real SignUpView once plan 06-04 lands.
                // This wiring is intentionally pre-registered so 06-04 only needs to
                // supply the destination — no changes to SignInView required.
                Text("Sign Up — Coming in 06-04")
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Background layers

    private var videoBackground: some View {
        FillingVideoPlayerView(player: videoViewModel.player)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            .onAppear {
                // D-04: 0.85x playback rate — slow enough not to distract, visibly moving.
                videoViewModel.player.rate = 0.85
            }
            .onDisappear {
                videoViewModel.player.pause()
            }
    }

    /// D-05: `rgba(6, 4, 14, 0.63)` tint + .ultraThinMaterial approximating blur(23) saturate(1.25).
    private var frostOverlay: some View {
        ZStack {
            Color(red: 6.0 / 255, green: 4.0 / 255, blue: 14.0 / 255)
                .opacity(0.63)
            Rectangle()
                .fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    // MARK: - Main scroll content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 80)
                wordmarkBlock
                Spacer().frame(height: 36)
                fieldsSection
                Spacer().frame(height: 16)
                ctaButton
                Spacer().frame(height: 14)
                signUpLink
                Spacer().frame(height: 24)
                orDivider
                Spacer().frame(height: 16)
                socialButtons
                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Sub-views

    private var wordmarkBlock: some View {
        VStack(spacing: 6) {
            Text("Fantasia")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Text("Bring your creativity to life.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .multilineTextAlignment(.center)
    }

    private var fieldsSection: some View {
        VStack(spacing: 12) {
            GlassTextField(
                placeholder: "Email",
                text: $email,
                isSecure: false,
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                isFocused: $emailFocused
            )
            if let emailError {
                Text(emailError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GlassTextField(
                placeholder: "Password",
                text: $password,
                isSecure: true,
                textContentType: .password,
                isFocused: $passwordFocused
            )
            if let passwordError {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            forgotPasswordSection
        }
    }

    private var forgotPasswordSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await sendPasswordReset() }
            } label: {
                Text("Forgot password?")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isAuthLoading)

            if passwordResetSent {
                Text("Reset email sent to \(email). Check your inbox.")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var ctaButton: some View {
        let isEmpty = email.isEmpty || password.isEmpty
        return Button {
            Task { await submitEmailAuth() }
        } label: {
            Group {
                if isAuthLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Sign In")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background {
                ctaGradient
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: purpleAccent.opacity(0.45), radius: 24, y: 4)
        }
        .disabled(isEmpty || isAuthLoading)
        .opacity(isEmpty || isAuthLoading ? 0.5 : 1.0)
    }

    private var signUpLink: some View {
        HStack(spacing: 4) {
            Text("Don't have an account?")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
            Button("Sign up") {
                showSignUp = true
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(purpleAccent)
        }
    }

    private var orDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
            Text("or")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.4))
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(height: 1)
        }
    }

    private var socialButtons: some View {
        VStack(spacing: 12) {
            SocialSignInButton(provider: .apple, action: {
                Task { await handleAppleSignIn() }
            }, isLoading: isSocialAuthLoading)

            SocialSignInButton(provider: .google, action: {
                Task { await handleGoogleSignIn() }
            }, isLoading: isSocialAuthLoading)

            if let socialAuthError {
                Text(socialAuthError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var backToOnboardingButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    hasCompletedOnboarding = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Back to onboarding")
                .padding(.trailing, 24)
            }
            Spacer()
        }
        .padding(.top, 56)
    }

    // MARK: - Auth Actions (email/password — preserved verbatim from Phase 2)

    private func submitEmailAuth() async {
        guard !email.isEmpty, !password.isEmpty else { return }
        isAuthLoading = true
        emailError = nil
        passwordError = nil

        do {
            _ = try await Auth.auth().signIn(withEmail: email, password: password)
            // AuthManager listener fires automatically
        } catch let error as NSError {
            let code = AuthErrorCode(rawValue: error.code)
            switch code {
            case .wrongPassword, .invalidCredential, .userNotFound:
                // Newer Firebase SDKs return invalidCredential for both wrong password and
                // non-existent accounts (userNotFound kept for older SDK compat).
                // Try createUser: if emailAlreadyInUse → wrong password; if success → new account.
                do {
                    _ = try await Auth.auth().createUser(withEmail: email, password: password)
                } catch let createError as NSError {
                    let createCode = AuthErrorCode(rawValue: createError.code)
                    switch createCode {
                    case .weakPassword:
                        passwordError = "Password must be at least 6 characters"
                    case .emailAlreadyInUse:
                        passwordError = "Incorrect password"
                    default:
                        emailError = "Account creation failed. Try again."
                    }
                }
            case .invalidEmail:
                emailError = "Enter a valid email address"
            case .tooManyRequests:
                emailError = "Too many attempts. Please wait and try again."
            case .networkError:
                emailError = "Network error. Check your connection."
            default:
                emailError = "Sign-in failed. Please try again."
            }
        }
        isAuthLoading = false
    }

    private func sendPasswordReset() async {
        guard !email.isEmpty else {
            emailError = "Enter your email address first."
            return
        }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
            passwordResetSent = true
        } catch {
            emailError = "Could not send reset email. Check the address and try again."
        }
    }

    // MARK: - Social Auth Actions

    private func handleGoogleSignIn() async {
        isSocialAuthLoading = true
        socialAuthError = nil
        do {
            try await authManager.signInWithGoogle()
        } catch {
            socialAuthError = error.localizedDescription
        }
        isSocialAuthLoading = false
    }

    /// Bridges ASAuthorizationController's delegate callbacks into async/await.
    /// T-06-03-01: nonce generated fresh per attempt, sha256-hashed before being sent
    /// in the ASAuthorizationAppleIDRequest — matches Apple's documented anti-replay pattern.
    private func handleAppleSignIn() async {
        isSocialAuthLoading = true
        socialAuthError = nil
        let nonce = authManager.generateNonce()
        let hashedNonce = authManager.sha256(nonce)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            appleCoordinator.onCompletion = { result in
                Task { @MainActor in
                    switch result {
                    case .success(let credential):
                        do {
                            try await authManager.signInWithApple(credential: credential)
                        } catch {
                            socialAuthError = error.localizedDescription
                        }
                    case .failure(let error):
                        socialAuthError = error.localizedDescription
                    }
                    isSocialAuthLoading = false
                    continuation.resume()
                }
            }
            appleCoordinator.start(nonce: hashedNonce)
        }
    }
}

#Preview {
    SignInView()
        .environment(AuthManager())
}
