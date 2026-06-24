// PurchaseManager.swift
// Fantasia
// Manages RevenueCat IAP transactions: purchase, restore, entitlement stream.
// Pattern: @Observable @MainActor final class (same as AuthManager, CreditManager).
// D-14: Custom SwiftUI paywall — RevenueCat used for transactions only, not built-in UI.
// RESEARCH.md Pitfall 2: Purchases.configure() called once in FantasiaApp.init() — not here.

import SwiftUI
import RevenueCat

@Observable
@MainActor
final class PurchaseManager {
    var isLoading: Bool = false
    var purchaseError: String? = nil

    private var creditManager: CreditManager

    init(creditManager: CreditManager) {
        self.creditManager = creditManager
    }

    /// Purchase a RevenueCat Package (subscription or top-up consumable).
    /// On success, fetches updated balance (D-19).
    func purchase(package: Package) async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let (_, customerInfo, _) = try await Purchases.shared.purchase(package: package)
            updateEntitlement(from: customerInfo)
            await creditManager.fetchBalance() // D-19: refresh post-purchase
        } catch ErrorCode.purchaseCancelledError {
            // User cancelled — silent, not an error (UI-SPEC interaction contract)
        } catch ErrorCode.paymentPendingError {
            purchaseError = "Purchase pending approval."
        } catch {
            purchaseError = "Purchase failed. Try again or restore."
        }
    }

    /// Restore previous purchases (PAY-07).
    func restorePurchases() async {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            updateEntitlement(from: customerInfo)
            await creditManager.fetchBalance()
        } catch {
            purchaseError = "Restore failed. Please try again."
        }
    }

    /// Listen for RevenueCat entitlement updates in real time (RESEARCH.md Pattern 5).
    /// Call this from a .task {} modifier in FantasiaApp or a long-lived view.
    func listenForEntitlementUpdates() async {
        for await newCustomerInfo in Purchases.shared.customerInfoStream {
            updateEntitlement(from: newCustomerInfo)
        }
    }

    private func updateEntitlement(from customerInfo: CustomerInfo) {
        if customerInfo.entitlements["pro"]?.isActive == true {
            creditManager.entitlementLevel = .pro
        } else if customerInfo.entitlements["basic"]?.isActive == true {
            creditManager.entitlementLevel = .basic
        } else {
            creditManager.entitlementLevel = .none
        }
    }
}
