// FantasiaApp.swift
// Fantasia

import SwiftUI
import FirebaseCore
import RevenueCat
import GoogleSignIn

@main
struct FantasiaApp: App {
    @UIApplicationDelegateAdaptor(FantasiaAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var authManager: AuthManager
    @State private var creditManager = CreditManager()
    @State private var generationManager = GenerationManager()
    @State private var mediaLibraryManager = MediaLibraryManager()
    @State private var ratesManager = RatesManager()
    @State private var offeringsManager = OfferingsManager()
    @State private var themeManager = ThemeManager()

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
                .environment(generationManager)
                .environment(mediaLibraryManager)
                .environment(ratesManager)
                .environment(offeringsManager)
                .environment(themeManager)
                .task {
                    // Deferred off init() so this runs after the first frame is already on
                    // screen — splash shows instantly, Firebase/RevenueCat set up behind it.
                    // IMPORTANT: FirebaseApp.configure() MUST run before any Auth.auth() call.
                    Task { await ratesManager.load() }  // public endpoint — fire in parallel with auth setup
                    FirebaseApp.configure()
                    GIDSignIn.sharedInstance.configuration = GIDConfiguration(
                        clientID: FirebaseApp.app()?.options.clientID ?? ""
                    )
                    authManager.start()

                    // Configure RevenueCat AFTER Firebase so Firebase UID is potentially available.
                    // Configured with nil appUserID here (anonymous user) per RESEARCH.md Pitfall 2.
                    // ContentView.onChange(currentUser) calls Purchases.shared.logIn(uid) on sign-in.
                    Purchases.logLevel = AppConfig.nodeEnv == "production" ? .error : .debug
                    Purchases.configure(
                        withAPIKey: AppConfig.revenueCatApiKey,
                        appUserID: nil // Set to Firebase UID in AuthManager after auth state restores
                    )
                    // ensuring: top-up ids so the launch prefetch (not just the stale-cache check)
                    // covers the consumable packs — they live in a separate offering from `current`.
                    Task { await offeringsManager.refreshIfNeeded(ensuring: OfferingsManager.topUpProductIds) } // throttled — see OfferingsManager

                    // Listen for RevenueCat entitlement updates in real time (RESEARCH.md Pattern 5)
                    let purchaseManager = PurchaseManager(creditManager: creditManager)
                    await purchaseManager.listenForEntitlementUpdates()
                }
                .onOpenURL { url in
                    // Required for Google Sign-In OAuth redirect back into the app.
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await ratesManager.loadIfNeeded() } // no-op unless stale (>1h)
                        Task { await offeringsManager.refreshIfNeeded(ensuring: OfferingsManager.topUpProductIds) } // no-op unless stale
                        generationManager.resumePollingIfNeeded() // no-op unless a job is active
                    } else if phase == .background {
                        generationManager.stopPolling()
                    }
                }
        }
    }
}
