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
    @State private var projectManager = ProjectManager()
    @State private var formatRegistryManager = FormatRegistryManager()
    @State private var characterRegistryManager = CharacterRegistryManager()
    @State private var ratesManager = RatesManager()
    @State private var offeringsManager = OfferingsManager()
    @State private var themeManager = ThemeManager()
    // Keeps the Railway backend awake during an active session. Railway's Serverless sleep
    // triggers after exactly 10 minutes with ZERO outbound traffic (fixed, not configurable —
    // confirmed via Railway docs). Generation polling already produces traffic while a job is
    // in flight, but idle periods (e.g. composing a prompt) have none, so anything touched next
    // — like the @-mention References panel — paid a ~7s cold-boot penalty on a plain network
    // call. Pinging /health every 4 minutes (well under the 10-minute window) while foregrounded
    // keeps the instance warm without materially increasing usage. Swift Concurrency only, per
    // CLAUDE.md — no Timer.
    @State private var keepWarmTask: Task<Void, Never>? = nil

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
                .environment(projectManager)
                .environment(formatRegistryManager)
                .environment(characterRegistryManager)
                .environment(ratesManager)
                .environment(offeringsManager)
                .environment(themeManager)
                .task {
                    // Deferred off init() so this runs after the first frame is already on
                    // screen — splash shows instantly, Firebase/RevenueCat set up behind it.
                    // IMPORTANT: FirebaseApp.configure() MUST run before any Auth.auth() call.
                    Task { await ratesManager.load() }  // public endpoint — fire in parallel with auth setup
                    Task { await formatRegistryManager.loadIfNeeded() } // public registry — same launch posture
                    Task { await characterRegistryManager.loadIfNeeded() } // public Cast registry
                    startKeepWarmLoop()  // belt-and-suspenders: scenePhase's .active onChange isn't guaranteed to fire on cold launch
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
                    Task {
                        await offeringsManager.refreshIfNeeded(ensuring: OfferingsManager.topUpProductIds) // throttled — see OfferingsManager
                        // Sandbox StoreKit fetches fail intermittently — retry with backoff so the
                        // store is usually instant by the time the user opens it.
                        for delaySec in [2.0, 4.0] {
                            let missing = OfferingsManager.topUpProductIds.filter { !offeringsManager.hasProduct(for: $0) }
                            if missing.isEmpty { break }
                            try? await Task.sleep(for: .seconds(delaySec))
                            await offeringsManager.refreshIfNeeded(force: true, ensuring: OfferingsManager.topUpProductIds)
                        }
                        // Debug-only visibility into whether the launch prefetch actually resolved
                        // purchasable products — a silent failure/timeout here (e.g. sandbox
                        // flakiness) is exactly what makes CreditStoreView's button feel "stuck"
                        // later, since it then has to do the full fetch itself.
                        if AppConfig.nodeEnv != "production" {
                            let missing = OfferingsManager.topUpProductIds.filter { !offeringsManager.hasProduct(for: $0) }
                            if missing.isEmpty {
                                print("[FantasiaApp] launch prefetch: all top-up products resolved")
                            } else {
                                print("[FantasiaApp] launch prefetch: still missing products \(missing) — CreditStoreView will need to fetch on open")
                            }
                        }
                    }

                    // Listen for RevenueCat entitlement updates in real time (RESEARCH.md Pattern 5)
                    let purchaseManager = PurchaseManager(creditManager: creditManager)
                    await purchaseManager.listenForEntitlementUpdates()

                    // Pre-warm the keyboard so the first tap on the Generate prompt box doesn't
                    // hitch. Standalone/offscreen — does NOT touch the frozen composer positioning.
                    KeyboardWarmer.warmUp()
                }
                .onOpenURL { url in
                    // Required for Google Sign-In OAuth redirect back into the app.
                    GIDSignIn.sharedInstance.handle(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await ratesManager.loadIfNeeded() } // no-op unless stale (>1h)
                        Task { await formatRegistryManager.loadIfNeeded() } // no-op unless stale (>1h)
                        Task { await characterRegistryManager.loadIfNeeded() } // no-op unless stale (>1h)
                        Task { await offeringsManager.refreshIfNeeded(ensuring: OfferingsManager.topUpProductIds) } // no-op unless stale
                        generationManager.resumePollingIfNeeded() // no-op unless a job is active
                        startKeepWarmLoop()
                    } else if phase == .background {
                        generationManager.stopPolling()
                        stopKeepWarmLoop()   // let the backend sleep while we're not in the foreground
                    }
                }
        }
    }

    /// Pings immediately, then every 4 minutes for as long as the app stays foregrounded.
    /// No-op if a loop is already running (background→active transitions and the initial
    /// launch's scenePhase callback can otherwise both try to start one).
    private func startKeepWarmLoop() {
        guard keepWarmTask == nil else { return }
        keepWarmTask = Task {
            while !Task.isCancelled {
                await APIClient.shared.pingHealth()
                try? await Task.sleep(for: .seconds(240))
            }
        }
    }

    private func stopKeepWarmLoop() {
        keepWarmTask?.cancel()
        keepWarmTask = nil
    }
}
