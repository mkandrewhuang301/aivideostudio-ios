// OfferingsManager.swift
// Fantasia
// Shared cache for RevenueCat offerings (top-up packs + subscription plans).
// Injected once at the app level so CreditStoreView/PaywallView reuse the same
// in-memory package list instead of each hitting the network on every appearance.
// Prices are additionally persisted to UserDefaults so they render offline after
// a cold relaunch — RevenueCat's own offerings cache is in-memory only and does
// not survive a process restart.

import Foundation
import RevenueCat

@Observable
@MainActor
final class OfferingsManager {
    private(set) var packages: [Package] = []
    /// Products fetched directly (not via any offering) as a fallback — keyed by productIdentifier.
    /// Populated by `refreshIfNeeded(ensuring:)` for required IDs missing from every offering.
    private(set) var standaloneProducts: [String: StoreProduct] = [:]
    private(set) var isRefreshing = false

    // Only hit the network this often in the background — reopening the top-up/
    // paywall screen should never force a fresh fetch on its own.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let lastFetchKey = "offerings.lastFetchDate"
    private static let priceCacheKey = "offerings.cachedPrices"

    // Mirrors CreditStoreView.packOrder — shared so the app-launch prefetch can ensure these
    // specific consumables are purchasable without CreditStoreView existing yet.
    static let topUpProductIds = [
        "com.fantasiaai.topup_9_99",
        "com.fantasiaai.topup_24_99",
        "com.fantasiaai.topup_49_99",
        "com.fantasiaai.topup_99_99",
    ]

    private var lastFetchDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastFetchKey) }
    }

    /// productIdentifier -> last known localized price string. Populated on every
    /// successful fetch, read back on cold launch before any network call resolves.
    private(set) var cachedPrices: [String: String]

    init() {
        cachedPrices = Self.loadCachedPrices()
    }

    func cachedPrice(for productId: String) -> String? {
        cachedPrices[productId]
    }

    func package(for productId: String) -> Package? {
        packages.first { $0.storeProduct.productIdentifier == productId }
    }

    /// A directly-fetched product for `productId`, when it isn't available through any offering.
    func standaloneProduct(for productId: String) -> StoreProduct? {
        standaloneProducts[productId]
    }

    /// True once we have a purchasable StoreProduct for `productId` from any source.
    func hasProduct(for productId: String) -> Bool {
        package(for: productId) != nil || standaloneProducts[productId] != nil
    }

    /// Cheap to call from every screen's `.task {}` — only actually reaches the
    /// network if we have nothing in memory yet or the last fetch is stale.
    ///
    /// `ensuring:` lists product IDs the caller *must* be able to purchase. If any are
    /// still missing after loading offerings, they're fetched directly via
    /// `Purchases.shared.products(_:)`. This is what makes the top-up store resilient to
    /// RevenueCat setups where the consumable packs aren't attached to an offering at all.
    func refreshIfNeeded(force: Bool = false, ensuring requiredIds: [String] = []) async {
        if packages.isEmpty, let cached = Purchases.shared.cachedOfferings {
            apply(cached)
        }

        let isStale = lastFetchDate.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        let missingRequired = requiredIds.contains { !hasProduct(for: $0) }
        // lastFetchDate persists across relaunch (UserDefaults) but packages doesn't (memory
        // only) — without this, a relaunch within the 6h window sees isStale == false and
        // returns immediately with an empty package list, so the real network fetch only starts
        // when a screen's .task runs with `ensuring:`, i.e. exactly when the user is staring at
        // the skeleton.
        guard force || packages.isEmpty || isStale || missingRequired else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        if let offerings = try? await Purchases.shared.offerings() {
            apply(offerings)
            lastFetchDate = Date()
        }

        // Fallback: fetch any still-missing required products directly from StoreKit/RC.
        let stillMissing = requiredIds.filter { !hasProduct(for: $0) }
        if !stillMissing.isEmpty {
            let fetched = await Purchases.shared.products(stillMissing)
            for product in fetched {
                standaloneProducts[product.productIdentifier] = product
            }
            persistPrices(fromProducts: fetched)
        }
    }

    private func apply(_ offerings: Offerings) {
        // Aggregate packages across ALL offerings, not just `current`.
        //
        // RevenueCat allows only ONE offering to be `current`. Our subscription paywall
        // is the current offering, while the consumable top-up packs (com.fantasiaai.topup_*)
        // live in a SEPARATE offering. Reading only `offerings.current` silently dropped every
        // top-up package, so CreditStoreView always fell through to "Couldn't load packages"
        // even online — while PaywallView worked because subscriptions are in `current`.
        //
        // Dedupe by productIdentifier (a product can appear in more than one offering).
        // `current` is visited first so its packages win any tie — irrelevant to lookups by
        // id, but keeps ordering stable.
        var seen = Set<String>()
        var collected: [Package] = []
        let orderedOfferings = [offerings.current].compactMap { $0 }
            + offerings.all.values.filter { $0.identifier != offerings.current?.identifier }
        for offering in orderedOfferings {
            for pkg in offering.availablePackages where seen.insert(pkg.storeProduct.productIdentifier).inserted {
                collected.append(pkg)
            }
        }

        guard !collected.isEmpty else { return }
        packages = collected
        persistPrices(fromProducts: collected.map { $0.storeProduct })
    }

    private func persistPrices(fromProducts products: [StoreProduct]) {
        guard !products.isEmpty else { return }
        for product in products {
            cachedPrices[product.productIdentifier] = product.localizedPriceString
        }
        if let data = try? JSONEncoder().encode(cachedPrices) {
            UserDefaults.standard.set(data, forKey: Self.priceCacheKey)
        }
    }

    private static func loadCachedPrices() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: priceCacheKey),
              let prices = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return prices
    }
}
