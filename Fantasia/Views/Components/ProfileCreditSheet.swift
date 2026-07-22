// ProfileCreditSheet.swift
// Fantasia
// Profile bottom sheet: identity, credits, actions, account management.

import SwiftUI
import AuthenticationServices

struct ProfileCreditSheet: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(ThemeManager.self) private var theme
    @Environment(OfferingsManager.self) private var offeringsManager
    @Binding var isPresented: Bool

    @State private var showCreditStore = false
    @State private var showSignInSheet = false
    @State private var showManageSubscription = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showAppleReauthentication = false
    @State private var showDeleteFailure = false
    @State private var isDeleting = false
    @State private var appleRawNonce: String?
    @State private var existingAccountPassword = ""

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var displayName: String {
        if authManager.currentUser?.isAnonymous == true {
            return "Guest"
        }
        return authManager.currentUser?.displayName
            ?? authManager.currentUser?.email?.components(separatedBy: "@").first
            ?? "Account"
    }

    private var tierLabel: String {
        switch creditManager.entitlementLevel {
        case .pro:      return "Pro"
        case .basic:    return "Basic"
        case .creator:  return "Creator"
        case .none:     return "Free"
        }
    }

    private var filledDots: Int {
        Int((creditManager.fillRatio * 22).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    identityBlock
                    creditsBlock
                    if authManager.currentUser?.isAnonymous == true {
                        signInNudge
                    }
                    menuSection
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            // Cheap head start on the top-up products before the user taps into the store —
            // no-op if already warm (see OfferingsManager.refreshIfNeeded).
            await offeringsManager.refreshIfNeeded(ensuring: OfferingsManager.topUpProductIds)
        }
        .fullScreenCover(isPresented: $showCreditStore) {
            CreditStoreView(isPresented: $showCreditStore)
                .environment(creditManager)
        }
        .fullScreenCover(isPresented: $showManageSubscription) {
            ManageSubscriptionView(isPresented: $showManageSubscription)
                .environment(creditManager)
        }
        .sheet(isPresented: $showSignInSheet) {
            signInSheet
                .presentationDetents([.height(340)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAppleReauthentication) {
            appleReauthenticationSheet
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
        .alert("Delete Account?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                if authManager.isAppleLinkedUser {
                    showAppleReauthentication = true
                } else {
                    Task { await performAccountDeletion() }
                }
            }
        } message: {
            Text("Your account, \(creditManager.creditsBalance) credits, all videos, projects, and uploads will be permanently deleted. This can't be undone.\nAn active subscription is not cancelled by this — manage it in Settings › Apple ID › Subscriptions.")
        }
        .alert("Couldn't delete your account. Check your connection and try again.", isPresented: $showDeleteFailure) {
            Button("OK") {}
        }
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Deleting…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .interactiveDismissDisabled(isDeleting)
    }

    // MARK: - Guest sign-in (nudge + mini-sheet)

    private var signInNudge: some View {
        Button {
            showSignInSheet = true
        } label: {
            Text("Sign in to save your progress ›")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentText)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -8)
    }

    private var signInSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text("Save your progress")
                        .font(.title3.weight(.semibold))
                    Text("Sign in to keep your videos and credits if you switch devices. Your guest progress carries over.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let email = authManager.pendingEmailMergeAddress {
                    existingEmailMergeForm(email: email)
                } else {
                    VStack(spacing: 10) {
                        Button {
                            Task { await linkProvider(.apple) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "apple.logo")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Sign in with Apple")
                                    .font(.body.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(.black)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await linkProvider(.google) }
                        } label: {
                            HStack(spacing: 8) {
                                Image("google_logo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 17, height: 17)
                                Text("Sign in with Google")
                                    .font(.body.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(.primary)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.surfaceBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .disabled(authManager.isLinking)
                    .overlay {
                        if authManager.isLinking {
                            ProgressView()
                                .tint(theme.textTertiary)
                        }
                    }
                }

                if let linkError = authManager.linkError {
                    Text(linkError.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Sign-in error: \(linkError.localizedDescription)")
                }

                Text("You can keep using the app as a guest anytime.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onChange(of: authManager.currentUser?.isAnonymous) { _, isAnonymous in
            if isAnonymous == false { showSignInSheet = false }
        }
    }

    private func linkProvider(_ provider: LinkProvider) async {
        try? await authManager.linkOrMerge(provider: provider, creditManager: creditManager)
        if authManager.currentUser?.isAnonymous == false {
            showSignInSheet = false
        }
    }

    private func existingEmailMergeForm(email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This email already has a Fantasia password account. Enter that password once to merge this guest account and add Google sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(email)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            SecureField("Fantasia password", text: $existingAccountPassword)
                .textContentType(.password)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.surfaceBorder, lineWidth: 0.5))

            HStack(spacing: 10) {
                Button("Cancel") {
                    existingAccountPassword = ""
                    authManager.cancelPendingEmailMerge()
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        do {
                            try await authManager.completePendingEmailMerge(
                                password: existingAccountPassword,
                                creditManager: creditManager
                            )
                            existingAccountPassword = ""
                        } catch {
                            // AuthManager exposes the precise recoverable error below the form.
                        }
                    }
                } label: {
                    if authManager.isLinking {
                        ProgressView()
                    } else {
                        Text("Merge & Continue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(existingAccountPassword.isEmpty || authManager.isLinking)
            }
        }
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Identity

    /// Light lavender for dark mode, falls back to `accent` in light mode for contrast.
    private var accentText: Color {
        theme.isLight ? accent : Color(red: 0.71, green: 0.58, blue: 1.0)
    }

    private var identityBlock: some View {
        HStack(spacing: 14) {
            CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(tierLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Credits

    private var creditsBlock: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Credits")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(creditManager.totalCreditsPossible > 0
                     ? "\(creditManager.creditsBalance) / \(creditManager.totalCreditsPossible) remaining"
                     : "\(creditManager.creditsBalance) remaining")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 22),
                spacing: 0
            ) {
                ForEach(0..<22, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? accent : theme.surfaceStrong)
                        .frame(height: 6)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Credit balance: \(filledDots) of 22")

            Button {
                showCreditStore = true
            } label: {
                Text("Top Up Credits")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.65, green: 0.45, blue: 1.0),
                                     Color(red: 0.40, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .shadow(color: accent.opacity(0.4), radius: 10, x: 0, y: 4)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Menu section

    private var menuSection: some View {
        VStack(spacing: 0) {
            // Primary actions card
            VStack(spacing: 0) {
                menuRow(icon: "creditcard.fill", iconColor: accent, label: "Manage Subscription") {
                    showManageSubscription = true
                }

                rowDivider

                menuRow(icon: "star.fill", iconColor: Color(red: 1.0, green: 0.8, blue: 0.15), label: "Rate Fantasia") {
                    AppReview.requestOrOpenStorePage()
                }
            }
            .padding(.horizontal, 12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.surfaceBorder, lineWidth: 0.5))

            if authManager.currentUser?.isAnonymous != true {
                // Dashed separator
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0.5))
                        path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                    }
                    .stroke(theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .frame(height: 1)
                .padding(.horizontal, 4)
                .padding(.vertical, 10)

                // Account actions card
                VStack(spacing: 0) {
                    Button { showSignOutConfirm = true } label: {
                        HStack(spacing: 12) {
                            iconContainer(systemName: "rectangle.portrait.and.arrow.right", color: .red.opacity(0.9))
                            Text("Sign Out")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)

                    rowDivider

                    Button { showDeleteConfirm = true } label: {
                        HStack(spacing: 12) {
                            iconContainer(systemName: "trash.fill", color: .red.opacity(0.9))
                            Text("Delete Account")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                }
                .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.15), lineWidth: 0.5))
                .alert("Sign out of Fantasia?", isPresented: $showSignOutConfirm) {
                    Button("Sign Out", role: .destructive) {
                        Task { try? await authManager.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }

    // MARK: - Account deletion

    private var appleReauthenticationSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 32))
                .foregroundStyle(accent)

            VStack(spacing: 6) {
                Text("Confirm it's you")
                    .font(.title3.weight(.semibold))
                Text("Sign in with Apple again to permanently delete your account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SignInWithAppleButton(.continue) { request in
                let rawNonce = authManager.generateNonce()
                appleRawNonce = rawNonce
                request.requestedScopes = [.email, .fullName]
                request.nonce = authManager.sha256(rawNonce)
            } onCompletion: { result in
                handleAppleReauthentication(result)
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 50)
        }
        .padding(24)
    }

    private func handleAppleReauthentication(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let rawNonce = appleRawNonce,
                  let codeData = credential.authorizationCode,
                  let authorizationCode = String(data: codeData, encoding: .utf8) else {
                showAppleReauthentication = false
                showDeleteFailure = true
                return
            }

            Task {
                do {
                    try await authManager.signInWithApple(credential: credential, rawNonce: rawNonce)
                    showAppleReauthentication = false
                    await performAccountDeletion(appleAuthorizationCode: authorizationCode)
                } catch {
                    print("[ProfileCreditSheet] Apple re-authentication failed: \(error)")
                    showAppleReauthentication = false
                    showDeleteFailure = true
                }
            }
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                print("[ProfileCreditSheet] Apple re-authentication failed: \(error)")
                showDeleteFailure = true
            }
            showAppleReauthentication = false
        }
    }

    private func performAccountDeletion(appleAuthorizationCode: String? = nil) async {
        guard authManager.currentUser?.isAnonymous == false, !isDeleting else { return }
        let deletingUid = authManager.currentUser?.uid
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await authManager.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
            if let deletingUid {
                creditManager.clearAccountCache(uid: deletingUid)
                ListSnapshotStore.clearAll(uid: deletingUid)
            }
            creditManager.reset()
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "hasCompletedOnboarding")
            defaults.removeObject(forKey: "hasClaimedFreeCredits")
            defaults.removeObject(forKey: "hasRequestedPushOnGenerate")
            isPresented = false
        } catch {
            print("[ProfileCreditSheet] Account deletion failed: \(error)")
            showDeleteFailure = true
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Fantasia · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 20) {
                Link(destination: URL(string: "https://fantasiaai.app/privacy")!) {
                    Text("Privacy Policy")
                        .underline()
                }
                Link(destination: URL(string: "https://fantasiaai.app/terms")!) {
                    Text("Terms of Service")
                        .underline()
                }
            }
            .font(.caption2)
            .foregroundStyle(theme.textTertiary)
            .tint(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - Row helpers

    private func menuRow(icon: String, iconColor: Color, label: String, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                iconContainer(systemName: icon, color: iconColor)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .tint(theme.textTertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func iconContainer(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: 0.5)
            .padding(.leading, 42)
    }

}
