// FantasiaApp.swift
// Fantasia

import SwiftUI
import FirebaseCore
import RevenueCat

@main
struct FantasiaApp: App {
    @State private var authManager: AuthManager
    @State private var creditManager = CreditManager()

    init() {
        // IMPORTANT: FirebaseApp.configure() MUST run first — Auth.auth() crashes otherwise.
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())

        // Configure RevenueCat AFTER Firebase so Firebase UID is potentially available.
        // Configured with nil appUserID here (anonymous user) per RESEARCH.md Pitfall 2.
        // AuthManager calls Purchases.shared.logIn(uid) when currentUser is set.
        Purchases.logLevel = AppConfig.nodeEnv == "production" ? .error : .debug
        Purchases.configure(
            withAPIKey: AppConfig.revenueCatApiKey,
            appUserID: nil // Set to Firebase UID in AuthManager after auth state restores
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(creditManager)
                .task {
                    // Listen for RevenueCat entitlement updates in real time (RESEARCH.md Pattern 5)
                    let purchaseManager = PurchaseManager(creditManager: creditManager)
                    await purchaseManager.listenForEntitlementUpdates()
                }
        }
    }
}
