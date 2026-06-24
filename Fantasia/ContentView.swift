// ContentView.swift
// Fantasia
// 5-state routing:
//   1. Loading (splash)
//   2. No onboarding completed → OnboardingView
//   3. Not authenticated → SignInView
//   4. Authenticated, no subscription → PaywallView (AUTH-03: hard paywall)
//   5. Authenticated, active subscription → MainTabView
// D-11: Routing order is fixed. hasCompletedOnboarding checked before auth state.

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CreditManager.self) private var creditManager
    @State private var minSplashElapsed = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if authManager.isLoading || !minSplashElapsed {
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
            } else if creditManager.entitlementLevel == .none {
                // State 4: Authenticated but no active subscription — hard paywall (AUTH-03)
                PaywallView()
            } else {
                // State 5: Authenticated + active subscription — main app
                MainTabView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: authManager.isLoading || !minSplashElapsed)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser == nil)
        .animation(.easeInOut(duration: 0.35), value: creditManager.entitlementLevel)
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
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(CreditManager())
}
