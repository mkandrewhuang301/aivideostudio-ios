// CreditManager.swift
// Fantasia
// Holds credit balance state and fetches from GET /api/me.
// Pattern: mirrors AuthManager — @Observable @MainActor final class.
// D-19: refreshes on scenePhase == .active and post-IAP transaction.
// D-16: fillRatio = currentBalance / (subscriptionAllotment + activeTopupBalance)

import SwiftUI

@Observable
@MainActor
final class CreditManager {
    var creditsBalance: Int = 0
    var subscriptionAllotment: Int = 0
    var activeTopupBalance: Int = 0
    var entitlementLevel: EntitlementLevel = .none
    var isLoading: Bool = false

    /// Fill ratio for CircularCreditIndicator (D-16).
    /// = currentBalance / (subscriptionAllotment + activeTopupBalance)
    /// Clamped to [0, 1]. Returns 0 when total allotment is 0 (no subscription yet).
    var fillRatio: Double {
        let total = subscriptionAllotment + activeTopupBalance
        guard total > 0 else { return 0 }
        return min(1.0, Double(creditsBalance) / Double(total))
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
        } catch {
            // Silent on error — stale balance is acceptable; next foreground trigger retries
            print("[CreditManager] fetchBalance error: \(error)")
        }
    }
}
