// ContentView.swift
// Fantasia
// 4-state routing (paywall case removed in 06-06; Phase 7 re-introduces enforcement at Generate button):
//   1. Loading (splash)
//   2. No onboarding completed → OnboardingView
//   3. Not authenticated → SignInView
//   3a. Authenticated, email not verified → CheckInboxView (email/password only; Apple/Google skip this)
//   4. Authenticated → MainTabView
// D-11: Routing order is fixed. hasCompletedOnboarding checked before auth state.

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CreditManager.self) private var creditManager
    @State private var minSplashElapsed = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    // Set true to skip straight to MainTabView — flip back to false before shipping.
    #if DEBUG
    private let debugSkipToMain = false
    #endif

    private var shouldSkipToMain: Bool {
        #if DEBUG
        return debugSkipToMain
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if shouldSkipToMain {
                MainTabView()
            } else if authManager.isLoading || !minSplashElapsed {
                // State 1: Loading — show splash until auth state resolves + 2s minimum
                SplashView()
            } else if !hasCompletedOnboarding {
                // State 2: First ever launch — onboarding
                OnboardingView(onComplete: {
                    hasCompletedOnboarding = true
                })
            } else if authManager.currentUser == nil {
                // State 3: No auth session — sign in
                SignInView()
            } else if let currentUser = authManager.currentUser, !currentUser.isEmailVerified {
                // State 3a (email/password): Account created but email not yet verified.
                // Apple and Google auth users always have isEmailVerified = true, so they skip
                // this state. Without this gate, ContentView would route email-signup users to
                // MainTabView immediately after createUser(), before they verify. (Rule 2: AUTH-02)
                CheckInboxView(email: currentUser.email ?? "")
            } else {
                // State 4: Authenticated + email verified — main app
                // NOTE: Paywall enforcement (AUTH-03) moves to Phase 7's Generate button trigger
                // (creditManager.balance == 0 → fullScreenCover PaywallView per T-06-06-02 accept).
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: authManager.isLoading || !minSplashElapsed)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser == nil)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser?.isEmailVerified)
        .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
        .task {
            try? await Task.sleep(for: .seconds(2))
            minSplashElapsed = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            // D-19: Refresh credit balance every time app comes to foreground
            if newPhase == .active {
                Task { await creditManager.fetchBalance() }
            }
        }
        .onChange(of: authManager.currentUser) { old, new in
            // Fire push permission + flush cached onboarding answers on first sign-in
            if old == nil && new != nil {
                Task { await handleFirstSignIn() }
            }
        }
    }

    private func handleFirstSignIn() async {
        // 1. Native push permission dialog + device token registration (CONTEXT.md: fires immediately after first sign-in)
        await PushNotificationManager.shared.requestPermissionAndRegister()

        // 2. Flush cached onboarding answers (06-05 wrote these to UserDefaults before auth existed)
        if let data = UserDefaults.standard.data(forKey: "pendingOnboardingAnswers"),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            do {
                try await APIClient.shared.updatePreferences(decoded)
                UserDefaults.standard.removeObject(forKey: "pendingOnboardingAnswers")
            } catch {
                print("[ContentView] Failed to flush onboarding preferences: \(error)")
                // Leave the cached data in UserDefaults — best-effort save per CONTEXT.md deferred scope.
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(CreditManager())
}
