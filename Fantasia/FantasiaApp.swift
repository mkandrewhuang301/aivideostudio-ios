// FantasiaApp.swift
// Fantasia

import SwiftUI
import FirebaseCore
import RevenueCat
import GoogleSignIn

@main
struct FantasiaApp: App {
    @UIApplicationDelegateAdaptor(FantasiaAppDelegate.self) var appDelegate
    @State private var authManager: AuthManager
    @State private var creditManager = CreditManager()

    init() {
        // UIWindow's default backgroundColor is black. Between the launch-screen snapshot
        // being dismissed and SwiftUI's first frame painting, that default shows through —
        // set it to match LaunchScreen.storyboard / SplashView so the gap is invisible.
        UIWindow.appearance().backgroundColor = UIColor(red: 0.085, green: 0.085, blue: 0.17, alpha: 1)

        // AuthManager() no longer touches Firebase in its own init (see start()) — safe to
        // construct here without FirebaseApp.configure() having run yet. This keeps init()
        // free of Firebase/RevenueCat setup so the splash paints before any of that runs.
        _authManager = State(initialValue: AuthManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(creditManager)
                .task {
                    // Deferred off init() so this runs after the first frame is already on
                    // screen — splash shows instantly, Firebase/RevenueCat set up behind it.
                    // IMPORTANT: FirebaseApp.configure() MUST run before any Auth.auth() call.
                    FirebaseApp.configure()
                    GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                        clientID: FirebaseApp.app()?.options.clientID ?? ""
                    )
                    authManager.start()

                    // Configure RevenueCat AFTER Firebase so Firebase UID is potentially available.
                    // Configured with nil appUserID here (anonymous user) per RESEARCH.md Pitfall 2.
                    // AuthManager calls Purchases.shared.logIn(uid) when currentUser is set.
                    Purchases.logLevel = AppConfig.nodeEnv == "production" ? .error : .debug
                    Purchases.configure(
                        withAPIKey: AppConfig.revenueCatApiKey,
                        appUserID: nil // Set to Firebase UID in AuthManager after auth state restores
                    )

                    // Listen for RevenueCat entitlement updates in real time (RESEARCH.md Pattern 5)
                    let purchaseManager = PurchaseManager(creditManager: creditManager)
                    await purchaseManager.listenForEntitlementUpdates()
                }
        }
    }
}
