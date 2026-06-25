// SignInView.swift
// Fantasia
//
// TODO: Add Sign in with Apple once Apple Developer Program activates (Phase 7)

import SwiftUI
import FirebaseAuth

struct SignInView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var emailError: String? = nil
    @State private var passwordError: String? = nil
    @State private var isAuthLoading = false
    @State private var showPassword = false
    @State private var passwordResetSent = false

    // X button returns to onboarding — without this there's no way back from
    // sign-in once onboarding is marked complete (ContentView routes by this flag).
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    @Environment(AuthManager.self) private var authManager

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email, password
    }

    private let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.10, blue: 0.18), Color(red: 0.07, green: 0.07, blue: 0.16)],
        startPoint: .top, endPoint: .bottom
    )
    private let surfaceColor = Color(red: 0.15, green: 0.15, blue: 0.25)
    private let dominantColor = Color(red: 0.10, green: 0.10, blue: 0.18)
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 48)
                    logoBlock
                    Spacer().frame(height: 24)
                    signInCard
                    Spacer().frame(height: 16)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        hasCompletedOnboarding = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Back to onboarding")
                    .padding(.trailing, 24)
                }
                Spacer()
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Sub-views

    private var logoBlock: some View {
        VStack(spacing: 8) {
            Text("Fantasia")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Generate stunning AI videos")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var signInCard: some View {
        VStack(spacing: 16) {
            emailFieldGroup
            passwordFieldGroup
            forgotPasswordSection
            signInButton
        }
        .padding(24)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }

    private var emailFieldGroup: some View {
        VStack(spacing: 4) {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(8)
                .background(dominantColor, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            focusedField == .email ? accent.opacity(0.5) : Color.secondary.opacity(0.3),
                            lineWidth: 1
                        )
                }
                .focused($focusedField, equals: .email)
                .accessibilityLabel(emailError.map { "Email, \($0)" } ?? "Email")

            if let emailError {
                Text(emailError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var passwordFieldGroup: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                passwordInputField
                eyeToggleButton
            }
            .background(dominantColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        focusedField == .password ? accent.opacity(0.5) : Color.secondary.opacity(0.3),
                        lineWidth: 1
                    )
            }

            if let passwordError {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var passwordInputField: some View {
        if showPassword {
            TextField("Password", text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .padding(8)
                .focused($focusedField, equals: .password)
                .accessibilityLabel(passwordError.map { "Password, \($0)" } ?? "Password")
        } else {
            SecureField("Password", text: $password)
                .textContentType(.password)
                .font(.body)
                .padding(8)
                .focused($focusedField, equals: .password)
                .accessibilityLabel(passwordError.map { "Password, \($0)" } ?? "Password")
        }
    }

    private var eyeToggleButton: some View {
        Button {
            if !UIAccessibility.isReduceMotionEnabled {
                withAnimation { showPassword.toggle() }
            } else {
                showPassword.toggle()
            }
        } label: {
            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                .foregroundStyle(.secondary)
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
    }

    private var forgotPasswordSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await sendPasswordReset() }
            } label: {
                Text("Forgot password?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isAuthLoading)

            if passwordResetSent {
                Text("Reset email sent to \(email). Check your inbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var signInButton: some View {
        Button {
            Task { await submitEmailAuth() }
        } label: {
            Group {
                if isAuthLoading {
                    ProgressView().tint(.white)
                } else {
                    Text("Sign In").font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(.white)
            .background(accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .disabled(email.isEmpty || password.isEmpty || isAuthLoading)
        .opacity(email.isEmpty || password.isEmpty || isAuthLoading ? 0.5 : 1.0)
    }

    // MARK: - Auth Actions

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
                // non-existent accounts (userNotFound is kept for older SDK compat).
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
}

#Preview {
    SignInView()
        .environment(AuthManager())
}
