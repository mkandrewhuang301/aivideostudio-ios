// ContentView.swift
// Fantasia
// Routing order:
//   1. Loading (splash)
//   2. Authenticated + email verified → MainTabView (skip onboarding entirely)
//   3. Authenticated + email not verified → CheckInboxView (email/password only)
//   4. Not authenticated + no onboarding → OnboardingView (first launch)
//   5. Not authenticated + onboarding done → SignInView

import SwiftUI
import RevenueCat

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
            } else if authManager.currentUser != nil && !creditManager.hasLoaded && !creditManager.hasCachedState {
                // State 1b: Authenticated but profile/credits haven't loaded yet, and we have no
                // locally-cached balance to show in the meantime — keep showing splash so
                // MainTabView never renders the 0-credits/free-tier CreditManager defaults
                // before the real GET /api/me response lands. Once hydrateFromCache() has
                // populated state from a previous session (see onChange below), this is skipped
                // and MainTabView renders immediately with the last-known balance; fetchBalance()
                // silently corrects it moments later.
                SplashView()
            } else if let currentUser = authManager.currentUser, currentUser.isEmailVerified {
                // State 2: Authenticated + verified — skip onboarding, go straight to app
                MainTabView()
            } else if let currentUser = authManager.currentUser, !currentUser.isEmailVerified {
                // State 3: Email/password sign-up, not yet verified (Apple/Google always skip this)
                CheckInboxView(email: currentUser.email ?? "")
            } else if !hasCompletedOnboarding {
                // State 4: Unauthenticated, first launch — show onboarding before sign-in
                OnboardingView(onComplete: { hasCompletedOnboarding = true })
            } else {
                // State 5: Unauthenticated, onboarding already seen — sign in
                SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: authManager.isLoading || !minSplashElapsed)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser == nil)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser?.isEmailVerified)
        .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
        .animation(.easeInOut(duration: 0.35), value: creditManager.hasLoaded)
        .animation(.easeInOut(duration: 0.35), value: creditManager.hasCachedState)
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            minSplashElapsed = true
        }
        .onChange(of: scenePhase) { _, newPhase in
            // D-19: Refresh credit balance every time app comes to foreground
            if newPhase == .active {
                Task { await creditManager.fetchBalance() }
            }
        }
        .onChange(of: authManager.currentUser) { old, new in
            if new == nil {
                // Signed out — clear stale credit state and reset RC to anonymous user
                creditManager.reset()
                Task { try? await Purchases.shared.logOut() }
            } else if old == nil && new != nil {
                // Signed in (or cold-launch restore from Keychain — this fires for both).
                // Hydrate from the last-known cached balance synchronously so State 1b above
                // can skip the splash immediately; the real fetchBalance() below corrects it.
                creditManager.hydrateFromCache()

                // Identify RC user with Firebase UID so the webhook app_user_id is resolvable
                // to a DB user (otherwise credit grants are silently skipped). This is
                // independent of our own backend, so run it alongside the balance fetch instead
                // of blocking the splash screen on it first.
                Task {
                    async let rcLogin = try? await Purchases.shared.logIn(new!.uid)
                    async let balance: Void = creditManager.fetchBalance()
                    _ = await rcLogin
                    await balance
                    await handleFirstSignIn()
                }
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
