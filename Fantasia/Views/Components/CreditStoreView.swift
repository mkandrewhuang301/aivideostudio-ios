// CreditStoreView.swift
// Fantasia
// Full-screen credit store presenting top-up credit packs (PAY-02).
// Presented via .fullScreenCover from ProfileCreditSheet.
// Pattern: @Binding var isPresented: Bool — matches PaywallView (NOT @Environment(\.dismiss)).

import SwiftUI
import RevenueCat

struct CreditStoreView: View {
    @Binding var isPresented: Bool
    @Environment(CreditManager.self) private var creditManager
    @Environment(OfferingsManager.self) private var offeringsManager
    @State private var purchaseManager: PurchaseManager?
    @State private var purchasingId: String? = nil
    @State private var errorId: String? = nil

    /// A pack ready to render — backed by a live RevenueCat Package or a directly-fetched
    /// StoreProduct when available, or the last locally-cached price when offline
    /// (purchase is disabled in that last case).
    private struct DisplayPack: Identifiable {
        let id: String
        let priceString: String
        let livePackage: Package?
        let liveProduct: StoreProduct?

        /// Whether this pack can be purchased right now (has a live Package or StoreProduct).
        var isPurchasable: Bool { livePackage != nil || liveProduct != nil }
        /// Localized numeric price, or 0 when only a cached string is available.
        var priceDouble: Double {
            if let pkg = livePackage { return NSDecimalNumber(decimal: pkg.storeProduct.price).doubleValue }
            if let prod = liveProduct { return NSDecimalNumber(decimal: prod.price).doubleValue }
            return 0
        }
    }

    private let accent  = Color(red: 0.55, green: 0.35, blue: 1.0)
    private let bgColor = Color(red: 0.059, green: 0.059, blue: 0.067)

    private struct PackMeta {
        let credits: Int
        let videoCount: Int
        let savingsPct: Int?   // nil = base tier; positive = % more credits/$ vs base
        let badge: String?
    }

    // Mirrors TOPUP_CREDITS map in aivideostudio-backend/src/routes/webhooks/revenuecat.ts.
    // videoCount: credits / 45 (Seedance Mini 10s 720p, per feedback_seedance_mini_reference.md).
    // savingsPct: (creditsPerDollar / baseTierCPD - 1) × 100; base = 500 credits / $9.99 ≈ 50 c/$.
    private let packMeta: [String: PackMeta] = [
        "com.fantasiaai.topup_9_99":  PackMeta(credits: 500,  videoCount: 11,  savingsPct: nil, badge: nil),
        "com.fantasiaai.topup_24_99": PackMeta(credits: 1400, videoCount: 31,  savingsPct: 12,  badge: "Popular"),
        "com.fantasiaai.topup_49_99": PackMeta(credits: 2900, videoCount: 64,  savingsPct: 16,  badge: "Best Value"),
        "com.fantasiaai.topup_99_99": PackMeta(credits: 5800, videoCount: 128, savingsPct: 16,  badge: nil),
    ]

    // Fixed display order (ascending price) — avoids depending on live price data to sort,
    // so cached-only (offline) packs render in the same order as live ones.
    private let packOrder = OfferingsManager.topUpProductIds

    private var displayPacks: [DisplayPack] {
        packOrder.compactMap { id in
            if let pkg = offeringsManager.package(for: id) {
                return DisplayPack(id: id, priceString: pkg.storeProduct.localizedPriceString, livePackage: pkg, liveProduct: nil)
            } else if let prod = offeringsManager.standaloneProduct(for: id) {
                return DisplayPack(id: id, priceString: prod.localizedPriceString, livePackage: nil, liveProduct: prod)
            } else if let cached = offeringsManager.cachedPrice(for: id) {
                return DisplayPack(id: id, priceString: cached, livePackage: nil, liveProduct: nil)
            }
            return nil
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar: title + X dismiss
                HStack {
                    Text("Top Up Credits")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)   // sits just below the safe-area inset
                .padding(.bottom, 20)

                // Content states
                let packs = displayPacks
                if packs.isEmpty && offeringsManager.isRefreshing {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(0..<4, id: \.self) { _ in skeletonCard }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                    }
                } else if packs.isEmpty {
                    Spacer()
                    errorView
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(packs) { pack in
                                packCard(pack)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                    }
                }
            }
        }
        .task {
            let pm = PurchaseManager(creditManager: creditManager)
            purchaseManager = pm
            // Ensure the top-up product IDs resolve even if they live outside the current
            // offering (or in no offering at all) — see OfferingsManager.refreshIfNeeded.
            await offeringsManager.refreshIfNeeded(ensuring: packOrder)
        }
    }

    // MARK: - Skeleton

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 130, height: 20)
                Capsule().fill(Color.white.opacity(0.06)).frame(width: 90, height: 16)
                Capsule().fill(Color.white.opacity(0.05)).frame(width: 64, height: 16)
            }
            Capsule().fill(Color.white.opacity(0.05)).frame(width: 210, height: 12)
            HStack {
                Capsule().fill(Color.white.opacity(0.04)).frame(width: 60, height: 12)
                Spacer()
                Capsule().fill(Color.white.opacity(0.07)).frame(width: 44, height: 16)
            }
            Capsule()
                .fill(Color.white.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Error

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Couldn't load packages")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Check your connection and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await offeringsManager.refreshIfNeeded(force: true, ensuring: packOrder) }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: 48)
            .padding(.horizontal, 40)
            .background(accent, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Pack Card

    @ViewBuilder
    private func packCard(_ pack: DisplayPack) -> some View {
        let productId = pack.id
        let price     = pack.priceString
        let priceD    = pack.priceDouble
        let meta      = packMeta[productId]
        let credits   = meta?.credits ?? 0
        // $1 = X credits — dynamic from RevenueCat price; handles localisation.
        // 0 when only a cached price string is available (offline) — pill hidden below.
        let cpd       = priceD > 0 ? Int(Double(credits) / priceD) : 0
        let isPurchasing = purchasingId == productId
        let hadError     = errorId == productId
        let isOffline    = !pack.isPurchasable
        // Both "Popular" and "Best Value" get accent border per D-08 key decisions
        let highlighted  = meta?.badge == "Popular" || meta?.badge == "Best Value"

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {

                // Row 1: [CREDIT AMOUNT bold] [$1=X credits dark pill] [+N% value accent pill]
                HStack(spacing: 8) {
                    Text("\(credits.formatted()) Credits")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    // Dark pill — "$1 = X credits"
                    if cpd > 0 {
                        Text("$1 = \(cpd) credits")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.75))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }

                    // Accent pill — "+N% value" (nil for base tier)
                    if let pct = meta?.savingsPct {
                        Text("+\(pct)% value")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(accent, in: Capsule())
                    }

                    Spacer(minLength: 0)
                }

                // Row 2: [~N Seedance Mini videos · Expires in 90 days] (secondary)
                if let vc = meta?.videoCount {
                    Text("~\(vc) Seedance Mini videos · Expires in 90 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Row 3: [badge pill left] [price right]
                HStack {
                    if let badge = meta?.badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge == "Best Value" ? .white : accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                badge == "Best Value" ? accent : accent.opacity(0.2),
                                in: Capsule()
                            )
                    }
                    Spacer()
                    Text(price)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }

                // Purchase button — full-width, white fill, dark text, height 52
                // Only this card's button shows ProgressView; other cards remain interactive
                // Offline (cached price only, no live Package yet): tapping reconnects instead
                // of purchasing — StoreKit needs a live product to start a transaction.
                Button {
                    if let pkg = pack.livePackage {
                        Task { await purchase(pkg) }
                    } else if let prod = pack.liveProduct {
                        Task { await purchase(product: prod) }
                    } else {
                        Task { await offeringsManager.refreshIfNeeded(force: true, ensuring: packOrder) }
                    }
                } label: {
                    Group {
                        if isPurchasing || (isOffline && offeringsManager.isRefreshing) {
                            ProgressView().tint(.black).scaleEffect(0.9)
                        } else if isOffline {
                            Text("Reconnect")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.black)
                        } else {
                            Text("Purchase")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                }
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .disabled(isPurchasing || (isOffline && offeringsManager.isRefreshing))
                .accessibilityLabel(
                    isOffline
                        ? "Reconnect to purchase \(credits.formatted()) credits"
                        : "Purchase \(credits.formatted()) credits for \(price)"
                )
                .accessibilityHint("One-time purchase. Credits expire in 90 days.")
            }
            .padding(16)

            // Inline error below card content
            if hadError {
                Text("Purchase failed. Please try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    highlighted ? accent.opacity(0.4) : Color.white.opacity(0.08),
                    lineWidth: highlighted ? 1.5 : 0.5
                )
        }
    }

    // MARK: - Actions

    private func purchase(_ package: Package) async {
        await runPurchase(id: package.storeProduct.productIdentifier) { pm in
            await pm.purchase(package: package)
        }
    }

    private func purchase(product: StoreProduct) async {
        await runPurchase(id: product.productIdentifier) { pm in
            await pm.purchase(product: product)
        }
    }

    private func runPurchase(id: String, _ buy: (PurchaseManager) async -> Void) async {
        guard let pm = purchaseManager else { return }
        purchasingId = id
        errorId = nil
        await buy(pm)
        purchasingId = nil
        if pm.purchaseError != nil {
            errorId = id
        } else {
            isPresented = false
        }
    }
}

#Preview {
    CreditStoreView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
