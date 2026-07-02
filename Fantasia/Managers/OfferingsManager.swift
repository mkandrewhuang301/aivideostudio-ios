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
    private(set) var isRefreshing = false

    // Only hit the network this often in the background — reopening the top-up/
    // paywall screen should never force a fresh fetch on its own.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let lastFetchKey = "offerings.lastFetchDate"
    private static let priceCacheKey = "offerings.cachedPrices"

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

    /// Cheap to call from every screen's `.task {}` — only actually reaches the
    /// network if we have nothing in memory yet or the last fetch is stale.
    func refreshIfNeeded(force: Bool = false) async {
        if packages.isEmpty, let cached = Purchases.shared.cachedOfferings {
            apply(cached)
        }

        let isStale = lastFetchDate.map { Date().timeIntervalSince($0) > Self.refreshInterval } ?? true
        guard force || isStale else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        if let offerings = try? await Purchases.shared.offerings() {
            apply(offerings)
            lastFetchDate = Date()
        }
    }

    private func apply(_ offerings: Offerings) {
        guard let available = offerings.current?.availablePackages, !available.isEmpty else { return }
        packages = available
        persistPrices(from: available)
    }

    private func persistPrices(from packages: [Package]) {
        for pkg in packages {
            cachedPrices[pkg.storeProduct.productIdentifier] = pkg.storeProduct.localizedPriceString
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
