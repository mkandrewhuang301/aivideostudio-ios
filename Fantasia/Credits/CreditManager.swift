// CreditManager.swift
// Fantasia
// Holds credit balance state and fetches from GET /api/me.
// Pattern: mirrors AuthManager — @Observable @MainActor final class.
// D-19: refreshes on scenePhase == .active and post-IAP transaction.
// D-16: fillRatio = currentBalance / (entitlementLevel.monthlyCredits + activeTopupBalance)

import SwiftUI
import FirebaseAuth

/// Codable snapshot persisted to UserDefaults so a returning user's last-known balance can
/// render instantly on launch instead of blocking on a GET /api/me round trip (see hasCachedState).
private struct CachedBalance: Codable {
    let creditsBalance: Int
    let subscriptionAllotment: Int
    let activeTopupBalance: Int
    let entitlementLevel: EntitlementLevel
}

@Observable
@MainActor
final class CreditManager {
    var creditsBalance: Int = 0
    var subscriptionAllotment: Int = 0
    var activeTopupBalance: Int = 0
    var entitlementLevel: EntitlementLevel = .none
    var isLoading: Bool = false
    /// True once a fetch has completed (success or failure) for the current session.
    /// Lets callers distinguish "not loaded yet" from "confirmed 0 credits / free tier".
    var hasLoaded: Bool = false
    /// True once a locally-cached balance (from a previous session) has been loaded into state.
    /// Lets ContentView skip blocking the splash on the network fetch for returning users —
    /// the real GET /api/me response still lands shortly after and silently corrects any drift.
    var hasCachedState: Bool = false

    private static func cacheKey(for uid: String) -> String { "creditManager.cachedBalance.\(uid)" }

    /// Hydrates state from the last-known balance cached for the current Firebase user, if any.
    /// Call on sign-in restore, before/alongside fetchBalance() — never a substitute for the
    /// real fetch, just fills the gap while it's in flight so the splash doesn't have to block.
    func hydrateFromCache() {
        guard let uid = Auth.auth().currentUser?.uid,
              let data = UserDefaults.standard.data(forKey: Self.cacheKey(for: uid)),
              let cached = try? JSONDecoder().decode(CachedBalance.self, from: data) else { return }
        creditsBalance = cached.creditsBalance
        subscriptionAllotment = cached.subscriptionAllotment
        activeTopupBalance = cached.activeTopupBalance
        entitlementLevel = cached.entitlementLevel
        hasCachedState = true
    }

    private func persistCache() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let cached = CachedBalance(
            creditsBalance: creditsBalance,
            subscriptionAllotment: subscriptionAllotment,
            activeTopupBalance: activeTopupBalance,
            entitlementLevel: entitlementLevel
        )
        guard let data = try? JSONEncoder().encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey(for: uid))
    }

    /// Plan allotment + active top-ups — the "denominator" for balance display. 0 = no plan/top-ups.
    var totalCreditsPossible: Int { entitlementLevel.monthlyCredits + activeTopupBalance }

    /// Fill ratio for CircularCreditIndicator (D-16).
    /// max = plan's monthly credit allotment + any active top-up balance.
    /// Falls back to full/empty when there is no plan and no top-ups (free users with seeded credits).
    var fillRatio: Double {
        let total = entitlementLevel.monthlyCredits + activeTopupBalance
        if total > 0 {
            return min(1.0, Double(creditsBalance) / Double(total))
        }
        return creditsBalance > 0 ? 1.0 : 0.0
    }

    func reset() {
        creditsBalance = 0
        subscriptionAllotment = 0
        activeTopupBalance = 0
        entitlementLevel = .none
        hasLoaded = false
        hasCachedState = false
    }

    /// Fetch current credit state from GET /api/me.
    /// Called on app foreground (D-19) and immediately after any IAP transaction.
    func fetchBalance() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let response: MeResponse = try await APIClient.shared.authorizedRequest(path: "api/me")
            creditsBalance = response.creditsBalance
            subscriptionAllotment = response.subscriptionAllotment
            activeTopupBalance = response.activeTopupBalance
            entitlementLevel = EntitlementLevel(rawValue: response.entitlementLevel ?? "") ?? .none
            // Perf: persist so the next cold launch can render instantly via hydrateFromCache()
            // instead of ContentView blocking the splash on this same network round trip.
            persistCache()
        } catch {
            // Silent on error — stale balance is acceptable; next foreground trigger retries
            print("[CreditManager] fetchBalance error: \(error)")
        }
        // Set on both success and failure — this flag means "a fetch attempt finished",
        // not "succeeded". Otherwise a network error would leave ContentView stuck on
        // the splash screen forever waiting for hasLoaded to flip.
        hasLoaded = true
    }
}
