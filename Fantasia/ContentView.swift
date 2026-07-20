// ContentView.swift
// Fantasia
// Routing order:
//   1. Loading (splash while auth restores/signs in and initial credits resolve)
//   2. First run → OnboardingView
//   3. Onboarding complete → MainTabView

import SwiftUI
import DeviceCheck
import RevenueCat

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(CreditManager.self) private var creditManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(MediaLibraryManager.self) private var mediaLibraryManager
    @Environment(ProjectManager.self) private var projectManager
    @Environment(ThemeManager.self) private var theme
    @State private var minSplashElapsed = false
    // Issue 6: a cold/sleeping Railway backend can make the first GET /api/me take many
    // seconds — without this, State 1b below blocks the splash on it indefinitely. After 3s
    // with no cached balance to fall back on, give up waiting and let MainTabView render;
    // fetchBalance() keeps running and corrects the UI whenever it actually lands.
    @State private var creditsWaitTimedOut = false
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
        productionRouting
        .preferredColorScheme(theme.colorScheme)
        .animation(.easeInOut(duration: 0.35), value: isLaunchLoading)
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
                creditsWaitTimedOut = false
                if let uid = old?.uid {
                    generationManager.clearSnapshot(uid: uid)
                    mediaLibraryManager.clearSnapshot(uid: uid)
                    projectManager.clearSnapshot(uid: uid)
                }
                Task { try? await Purchases.shared.logOut() }
            } else if old == nil && new != nil {
                // Signed in (or cold-launch restore from Keychain — this fires for both).
                // Hydrate from the last-known cached balance synchronously so State 1b above
                // can skip the splash immediately; the real fetchBalance() below corrects it.
                creditManager.hydrateFromCache()
                generationManager.hydrateFromSnapshot()
                mediaLibraryManager.hydrateFromSnapshot()
                projectManager.hydrateFromSnapshot()

                // Issue 6: cap the State 1b splash wait — a cold Railway instance shouldn't
                // freeze the whole app on the first /api/me round trip.
                creditsWaitTimedOut = false
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !creditManager.hasLoaded { creditsWaitTimedOut = true }
                }

                // Identify RC user with Firebase UID so the webhook app_user_id is resolvable
                // to a DB user (otherwise credit grants are silently skipped). This is
                // independent of our own backend, so run it alongside the balance fetch instead
                // of blocking the splash screen on it first.
                Task {
                    async let rcLogin = try? await Purchases.shared.logIn(new!.uid)
                    async let balance: Void = creditManager.fetchBalance()
                    _ = await rcLogin
                    await balance
                    if hasCompletedOnboarding {
                        await claimFreeCreditsIfNeeded()
                    }
                }
            }
        }
        .onChange(of: authManager.accountMergeRevision) { _, _ in
            // Firebase switches from the guest UID to the existing provider UID before
            // POST /api/me/merge runs. The ordinary auth-state callback therefore cannot
            // refresh these collections safely: it can fetch the target account just before
            // the backend moves the guest rows, then mark the empty result as fresh for up to
            // five minutes. This signal is emitted only after /merge returns 204/409.
            Task {
                await generationManager.refresh()
                await mediaLibraryManager.load(forceRefresh: true)
                await projectManager.refreshProjects()
            }
        }
    }

    private var isLaunchLoading: Bool {
        authManager.isLoading || authManager.currentUser == nil || !minSplashElapsed
    }

    @ViewBuilder
    private var productionRouting: some View {
        if shouldSkipToMain {
            MainTabView()
        } else if isLaunchLoading {
            // State 1: Loading — wait for Firebase restore/anonymous sign-in and the minimum splash.
            SplashView()
        } else if authManager.currentUser != nil && !creditManager.hasLoaded && !creditManager.hasCachedState && !creditsWaitTimedOut {
            // State 1b: Authenticated but profile/credits haven't loaded yet, and we have no
            // locally-cached balance to show in the meantime — keep showing splash so
            // MainTabView never renders the 0-credits/free-tier CreditManager defaults
            // before the real GET /api/me response lands. Once hydrateFromCache() has
            // populated state from a previous session (see onChange below), this is skipped
            // and MainTabView renders immediately with the last-known balance; fetchBalance()
            // silently corrects it moments later.
            SplashView()
        } else if !hasCompletedOnboarding {
            // State 2: Authenticated guest on first run — onboarding ends directly in the app.
            OnboardingView(onComplete: {
                hasCompletedOnboarding = true
                Task { await claimFreeCreditsIfNeeded() }
            })
        } else {
            // State 3: Anonymous and provider-linked users share the same app shell.
            MainTabView()
        }
    }

    private func claimFreeCreditsIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "hasClaimedFreeCredits") else { return }
        guard let deviceToken = await generateDeviceCheckToken() else { return }

        do {
            try await APIClient.shared.claimFreeCredits(deviceToken: deviceToken)
            defaults.set(true, forKey: "hasClaimedFreeCredits")
            await creditManager.fetchBalance(force: true)
        } catch {
            // Backend + DeviceCheck are the authoritative idempotency gates. Leave the local
            // flag unset so a later authenticated launch can safely retry a transient failure.
            print("[ContentView] Free-credit claim failed: \(error)")
        }
    }

    private func generateDeviceCheckToken() async -> String? {
        let device = DCDevice.current
        guard device.isSupported else {
            print("[ContentView] DeviceCheck is unavailable; skipping the free-credit claim")
            return nil
        }

        return await withCheckedContinuation { continuation in
            device.generateToken { data, error in
                guard let data else {
                    print("[ContentView] DeviceCheck token generation failed: \(error?.localizedDescription ?? "unknown error")")
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data.base64EncodedString())
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
        .environment(CreditManager())
        .environment(ThemeManager())
}
