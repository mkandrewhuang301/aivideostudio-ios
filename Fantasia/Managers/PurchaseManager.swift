// PurchaseManager.swift
// Fantasia
// Manages RevenueCat IAP transactions: purchase, restore, entitlement stream.
// Pattern: @Observable @MainActor final class (same as AuthManager, CreditManager).
// D-14: Custom SwiftUI paywall — RevenueCat used for transactions only, not built-in UI.
// RESEARCH.md Pitfall 2: Purchases.configure() called once in FantasiaApp.init() — not here.

import SwiftUI
import RevenueCat
import FirebaseAuth

/// Result of a purchase attempt, distinguishing "succeeded, credits confirmed" from
/// "succeeded, but the webhook grant hasn't landed yet" — these must NOT be treated the same
/// in the UI (the latter is not a failure and must never show error copy).
enum PurchaseOutcome {
    case credited
    /// Purchase succeeded (StoreKit confirmed it) but the credit balance hadn't increased by
    /// the time polling gave up. Credits will land once the RC webhook fires; the next
    /// foreground fetch will pick them up.
    case pendingWebhook
    case cancelled
    case failed
}

@Observable
@MainActor
final class PurchaseManager {
    var isLoading: Bool = false
    var purchaseError: String? = nil

    private var creditManager: CreditManager

    init(creditManager: CreditManager) {
        self.creditManager = creditManager
    }

    /// Settle RC identity (logIn as the Firebase UID) BEFORE the user taps Purchase, so buy() goes
    /// straight to the StoreKit sheet with no logIn round-trip on the tap. Returns true if RC is now
    /// identified as the current Firebase UID.
    @discardableResult
    func ensureIdentified() async -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        if Purchases.shared.appUserID == uid { return true }
        _ = try? await Purchases.shared.logIn(uid)
        return Purchases.shared.appUserID == uid
    }

    /// Purchase a RevenueCat Package (subscription or top-up consumable).
    /// On success, fetches updated balance (D-19).
    /// - Parameter creditsToGrant: known credit amount for a top-up pack (0 for subscriptions),
    ///   so the balance can be reflected optimistically the instant StoreKit confirms — see
    ///   CreditManager.applyOptimisticTopUp.
    @discardableResult
    func purchase(package: Package, creditsToGrant: Int = 0) async -> PurchaseOutcome {
        await runPurchase(creditsToGrant: creditsToGrant) { try await Purchases.shared.purchase(package: package) }
    }

    /// Purchase a raw StoreProduct — used for top-up consumables that aren't attached to a
    /// RevenueCat offering (see OfferingsManager's direct-product fallback). Same post-purchase
    /// balance-poll semantics as the Package path.
    @discardableResult
    func purchase(product: StoreProduct, creditsToGrant: Int = 0) async -> PurchaseOutcome {
        await runPurchase(creditsToGrant: creditsToGrant) { try await Purchases.shared.purchase(product: product) }
    }

    /// Shared purchase flow for both the Package and StoreProduct entry points.
    @discardableResult
    private func runPurchase(creditsToGrant: Int, _ buy: () async throws -> (StoreTransaction?, CustomerInfo, Bool)) async -> PurchaseOutcome {
        isLoading = true
        purchaseError = nil
        defer { isLoading = false }

        // Guard: never let a purchase be attributed to an anonymous RC user — the webhook keys
        // credit grants off app_user_id == firebase_uid (revenuecat.ts SELECT ... WHERE
        // firebase_uid = ...), so an anonymous purchase is silently dropped server-side and the
        // user pays without ever receiving credits. ContentView's logIn(uid) call is fire-and-
        // forget (`try?`), so it may not have completed yet by the time the user taps Purchase.
        guard let firebaseUid = Auth.auth().currentUser?.uid else {
            purchaseError = "Please sign in again before purchasing."
            return .failed
        }
        if Purchases.shared.appUserID != firebaseUid {
            _ = try? await Purchases.shared.logIn(firebaseUid)
        }
        // Hard stop: a charge attributed to $RCAnonymousID grants nothing server-side and never
        // recovers. A retryable pre-purchase error is strictly better than money-in / zero-credits-out.
        guard Purchases.shared.appUserID == firebaseUid else {
            purchaseError = "Couldn't verify your account. Please try again."
            return .failed
        }

        // Captured before the purchase so the background credit poll below waits for the balance
        // to actually increase — not just for it to become nonzero.
        let balanceBefore = creditManager.creditsBalance

        do {
            let (_, customerInfo, _) = try await buy()   // StoreKit confirmed the transaction
            updateEntitlement(from: customerInfo)
            if creditsToGrant > 0 {
                // Synchronous, no `await` before pollForCreditsInBackground spawns its Task below
                // — guarantees the floor is set before that task's first fetchBalance() runs.
                creditManager.applyOptimisticTopUp(credits: creditsToGrant)
            }
            pollForCreditsInBackground(after: balanceBefore, creditsToGrant: creditsToGrant)   // non-blocking — sheet can close now
            return .credited
        } catch ErrorCode.purchaseCancelledError {
            // User cancelled — silent, not an error (UI-SPEC interaction contract)
            return .cancelled
        } catch ErrorCode.paymentPendingError {
            purchaseError = "Purchase pending approval."
            return .failed
        } catch {
            purchaseError = "Purchase failed. Try again or restore."
            return .failed
        }
    }

    /// Background credit reconciliation after a confirmed purchase. Polls until the purchase is
    /// reconciled or the retry budget is spent; ContentView's foreground fetchBalance is the
    /// final backstop. Unstructured + unretained on purpose: it must outlive runPurchase()
    /// returning. PurchaseManager is @MainActor, so creditManager access stays isolated.
    ///
    /// Confirmed in production: RC webhook delivery + a cold Railway boot can exceed 20s, so a
    /// short fixed window let the grant land in the DB with no automatic client refresh — the
    /// user had to background/foreground the app themselves to see it. Poll quickly at first,
    /// then back off, for a ~100s total budget before handing off to the scenePhase-active /
    /// cold-launch backstops.
    ///
    /// For a top-up (`creditsToGrant > 0`), the balance already shows the optimistic post-
    /// purchase total (see CreditManager.applyOptimisticTopUp) — "reconciled" here means the
    /// floor has cleared, i.e. a real server value confirmed it either way. Subscriptions have
    /// no optimistic floor, so "reconciled" falls back to the original balance-increased check.
    private func pollForCreditsInBackground(after before: Int, creditsToGrant: Int) {
        Task {
            await creditManager.fetchBalance(force: true)
            let intervals: [Double] = Array(repeating: 2, count: 10) + Array(repeating: 5, count: 16)
            for interval in intervals {
                let reconciled = creditsToGrant > 0
                    ? !creditManager.hasPendingOptimisticTopUp
                    : creditManager.creditsBalance > before
                if reconciled { return }
                try? await Task.sleep(for: .seconds(interval))
                await creditManager.fetchBalance(force: true)
            }
            if creditsToGrant > 0 {
                await creditManager.giveUpOnOptimisticTopUp()
            }
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
        if customerInfo.entitlements["creator"]?.isActive == true {
            creditManager.entitlementLevel = .creator
        } else if customerInfo.entitlements["pro"]?.isActive == true {
            creditManager.entitlementLevel = .pro
        } else if customerInfo.entitlements["basic"]?.isActive == true {
            creditManager.entitlementLevel = .basic
        }
        // When RC has no active entitlement, defer to the server value from /api/me
        // rather than overriding — the server is the source of truth via the RC webhook.
    }
}
