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
        /// "Was $X" price this tier would cost at the base tier's (worse) credits-per-dollar rate.
        /// nil for the base tier itself, or when live pricing isn't available (offline).
        let regularPriceString: String?
        /// Real % cheaper than the base-tier rate, derived from regularPriceString vs priceString.
        let discountPct: Int?

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
    private let strikeColor = Color(red: 1.0, green: 0.55, blue: 0.40)
    private let discountRed = Color(red: 0.92, green: 0.30, blue: 0.36).opacity(0.30)
    private let discountRedText = Color(red: 1.0, green: 0.62, blue: 0.58)
    private let benefitTextColor = Color.white.opacity(0.62)
    private let benefitCheckColor = Color.white.opacity(0.42)
    private let highlightBorderBright = Color(red: 0.78, green: 0.58, blue: 1.0)
    private let highlightBorderDeep = Color(red: 0.32, green: 0.16, blue: 0.72)
    private let purchaseButtonRadius: CGFloat = 12
    private let cardRadius: CGFloat = 20
    /// Pulls monospaced glyphs closer — SF Mono’s fixed widths read loose without this.
    private let monoTracking: CGFloat = -1.1

    private func techFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    private struct PackMeta {
        let credits: Int
        let badge: String?
    }

    private static let creditsPerVideo720p6s = 54
    private static let creditsPerImage2k = 5

    // Mirrors TOPUP_CREDITS map in aivideostudio-backend/src/routes/webhooks/revenuecat.ts.
    private let packMeta: [String: PackMeta] = [
        "com.fantasiaai.topup_9_99":  PackMeta(credits: 500,  badge: nil),
        "com.fantasiaai.topup_24_99": PackMeta(credits: 1400, badge: nil),
        "com.fantasiaai.topup_49_99": PackMeta(credits: 2900, badge: nil),
        "com.fantasiaai.topup_99_99": PackMeta(credits: 5800, badge: "Most Popular"),
    ]

    private func videoCount720p6s(for credits: Int) -> Int { credits / Self.creditsPerVideo720p6s }
    private func imageCount2k(for credits: Int) -> Int { credits / Self.creditsPerImage2k }

    // Fixed display order (high → low credits) — avoids depending on live price data to sort,
    // so cached-only (offline) packs render in the same order as live ones.
    private let packOrder: [String] = Array(OfferingsManager.topUpProductIds.reversed())
    private static let baseProductId = "com.fantasiaai.topup_9_99"
    private static let allProductIds = OfferingsManager.topUpProductIds

    private var displayPacks: [DisplayPack] {
        // The base tier's live credits-per-dollar rate is the "regular" rate every other tier
        // is discounted against — interpolated fresh from live pricing rather than hardcoded,
        // so the "-N% off" framing stays accurate across storefronts/currencies.
        func livePriceDouble(for id: String) -> Double? {
            if let pkg = offeringsManager.package(for: id) {
                return NSDecimalNumber(decimal: pkg.storeProduct.price).doubleValue
            } else if let prod = offeringsManager.standaloneProduct(for: id) {
                return NSDecimalNumber(decimal: prod.price).doubleValue
            }
            return nil
        }
        let baseCredits = Double(packMeta[Self.baseProductId]?.credits ?? 0)
        let baseCPD: Double? = {
            guard let basePrice = livePriceDouble(for: Self.baseProductId), basePrice > 0, baseCredits > 0 else { return nil }
            return baseCredits / basePrice
        }()

        return packOrder.compactMap { id in
            let credits = Double(packMeta[id]?.credits ?? 0)
            func discountFraming(priceD: Double, formatter: NumberFormatter?) -> (String?, Int?) {
                guard id != Self.baseProductId, let baseCPD, baseCPD > 0, priceD > 0 else { return (nil, nil) }
                let regularPriceD = credits / baseCPD
                guard regularPriceD > priceD,
                      let formatted = formatter?.string(from: NSDecimalNumber(value: regularPriceD)) else { return (nil, nil) }
                let pct = Int(((1 - priceD / regularPriceD) * 100).rounded())
                return (formatted, pct)
            }

            if let pkg = offeringsManager.package(for: id) {
                let priceD = NSDecimalNumber(decimal: pkg.storeProduct.price).doubleValue
                let (regular, pct) = discountFraming(priceD: priceD, formatter: pkg.storeProduct.priceFormatter)
                return DisplayPack(id: id, priceString: pkg.storeProduct.localizedPriceString, livePackage: pkg, liveProduct: nil,
                                    regularPriceString: regular, discountPct: pct)
            } else if let prod = offeringsManager.standaloneProduct(for: id) {
                let priceD = NSDecimalNumber(decimal: prod.price).doubleValue
                let (regular, pct) = discountFraming(priceD: priceD, formatter: prod.priceFormatter)
                return DisplayPack(id: id, priceString: prod.localizedPriceString, livePackage: nil, liveProduct: prod,
                                    regularPriceString: regular, discountPct: pct)
            } else if let cached = offeringsManager.cachedPrice(for: id) {
                return DisplayPack(id: id, priceString: cached, livePackage: nil, liveProduct: nil,
                                    regularPriceString: nil, discountPct: nil)
            }
            return nil
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header bar: large title + X dismiss
                HStack(alignment: .center) {
                    storeHeaderTitle
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
                .padding(.top, 8)
                .padding(.bottom, 10)

                // Content states
                let packs = displayPacks
                if packs.isEmpty && offeringsManager.isRefreshing {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
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
                        VStack(spacing: 10) {
                            ForEach(packs) { pack in
                                packCard(pack)
                            }
                            termsLinksRow
                                .padding(.top, 6)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .task {
            let pm = PurchaseManager(creditManager: creditManager)
            purchaseManager = pm
            // Settle RC identity before the tap so buy() never pays a logIn round-trip on tap.
            Task { await pm.ensureIdentified() }
            // Warm the backend as soon as the store opens — a purchase's post-purchase credit
            // poll (PurchaseManager.runPurchase) has a bounded window, and a cold Railway
            // instance's boot time can eat most of it. Firing this now overlaps the cold boot
            // with the user browsing packs / completing the Apple sign-in sheet.
            Task { await APIClient.shared.pingHealth() }
            // Ensure the top-up product IDs resolve even if they live outside the current
            // offering (or in no offering at all) — see OfferingsManager.refreshIfNeeded.
            await offeringsManager.refreshIfNeeded(ensuring: Self.allProductIds)
        }
    }

    // MARK: - Header

    private var storeHeaderTitle: some View {
        Text("Top Up Credits")
            .font(techFont(.title, weight: .bold))
            .tracking(monoTracking)
            .foregroundStyle(.primary)
            .lineSpacing(0)
    }

    // Credit top-ups are a real IAP purchase point, same class as PaywallView — mirrors its
    // Terms/Privacy link row exactly (2026-07-13, this screen previously had neither).
    private var termsLinksRow: some View {
        HStack(spacing: 4) {
            Link("Terms of Service",
                 destination: URL(string: "https://fantasiaai.app/terms")!)
            Text("·").foregroundStyle(.secondary)
            Link("Privacy Policy",
                 destination: URL(string: "https://fantasiaai.app/privacy")!)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Skeleton

    private var skeletonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 180, height: 32)
            Capsule().fill(Color.white.opacity(0.05)).frame(width: 240, height: 14)
            HStack {
                Capsule().fill(Color.white.opacity(0.07)).frame(width: 72, height: 24)
                Spacer()
                Capsule().fill(Color.white.opacity(0.05)).frame(width: 56, height: 16)
                Capsule().fill(Color.white.opacity(0.06)).frame(width: 44, height: 20)
            }
            Capsule()
                .fill(Color.white.opacity(0.06))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: Color.white.opacity(0.08), radius: 14, y: 0)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
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
                Task { await offeringsManager.refreshIfNeeded(force: true, ensuring: Self.allProductIds) }
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
        let meta = packMeta[pack.id]
        let credits = meta?.credits ?? 0
        let highlighted = meta?.badge != nil

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                packCardTitle(credits: credits, badge: meta?.badge)
                packCardBenefits(credits: credits)
                packPriceRow(pack: pack)
                packPurchaseButton(pack: pack, credits: credits)
            }
            .padding(14)

            if errorId == pack.id {
                Text("Purchase failed. Please try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: cardRadius)
                .fill(highlighted ? accent.opacity(0.10) : Color.white.opacity(0.04))
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay { packCardInnerGlow(highlighted: highlighted) }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .overlay { packCardBorder(highlighted: highlighted) }
        .shadow(color: Color.black.opacity(0.28), radius: 12, y: 6)
        .modifier(PackCardGlow(highlighted: highlighted))
    }

    @ViewBuilder
    private func packCardInnerGlow(highlighted: Bool) -> some View {
        if highlighted {
            ZStack {
                RadialGradient(
                    colors: [accent.opacity(0.20), accent.opacity(0.06), Color.clear],
                    center: .bottomLeading,
                    startRadius: 4,
                    endRadius: 190
                )
                LinearGradient(
                    colors: [highlightBorderBright.opacity(0.10), Color.clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.45)
                )
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func packCardBorder(highlighted: Bool) -> some View {
        if highlighted {
            RoundedRectangle(cornerRadius: cardRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            highlightBorderBright.opacity(0.85),
                            accent.opacity(0.80),
                            highlightBorderDeep.opacity(0.55),
                            highlightBorderDeep.opacity(0.25),
                        ],
                        startPoint: .top,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
        } else {
            RoundedRectangle(cornerRadius: cardRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.34), Color.white.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    private struct PackCardGlow: ViewModifier {
        let highlighted: Bool

        func body(content: Content) -> some View {
            if highlighted {
                content
            } else {
                content
                    .shadow(color: Color.white.opacity(0.10), radius: 18, y: 0)
                    .shadow(color: Color.white.opacity(0.05), radius: 2, y: -1)
            }
        }
    }

    private func packCardTitle(credits: Int, badge: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(credits.formatted())
                .font(techFont(.title2, weight: .bold))
                .tracking(monoTracking)
            Text("Credits")
                .font(techFont(.title2, weight: .bold))
                .tracking(monoTracking)

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accent, in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private func packCardBenefits(credits: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            benefitRow("Up to \(imageCount2k(for: credits)) Image generations at 2k resolution")
            benefitRow("Up to \(videoCount720p6s(for: credits)) video generations at 720p, 6s")
        }
    }

    private func benefitRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(benefitCheckColor)
            Text(text)
                .font(.caption)
                .foregroundStyle(benefitTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func packPriceRow(pack: DisplayPack) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(pack.priceString)
                .font(techFont(.title3, weight: .bold))
                .tracking(monoTracking)
                .foregroundStyle(.primary)

            if let regular = pack.regularPriceString {
                Text(regular)
                    .font(techFont(.title3, weight: .bold))
                    .tracking(monoTracking)
                    .foregroundStyle(strikeColor)
                    .strikethrough(true, color: strikeColor)
            }
            if let pct = pack.discountPct, pct > 0 {
                Text("-\(pct)%")
                    .font(techFont(.caption, weight: .bold))
                    .tracking(monoTracking)
                    .foregroundStyle(discountRedText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(discountRed, in: Capsule())
                    .offset(y: -3)
            }

            Spacer(minLength: 0)
        }
    }

    private func packPurchaseButton(pack: DisplayPack, credits: Int) -> some View {
        let isPurchasing = purchasingId == pack.id
        // Spinner only while a purchase is actually in flight — the button must never be a
        // disabled pre-tap spinner just because the live product hasn't resolved yet (resolved
        // on tap instead, see the else-branch below).
        let showSpinner = isPurchasing

        return Button {
            if let pkg = pack.livePackage {
                Task { await purchase(pkg) }
            } else if let prod = pack.liveProduct {
                Task { await purchase(product: prod) }
            } else {
                // The live product hasn't resolved yet (still loading, or a prior fetch failed).
                // Spin just this button while awaitProduct resolves it — never a dead tap.
                Task {
                    purchasingId = pack.id
                    errorId = nil
                    let ok = await offeringsManager.awaitProduct(for: pack.id)
                    if ok, let pkg = offeringsManager.package(for: pack.id) {
                        await purchase(pkg)                    // sets/clears purchasingId itself
                    } else if ok, let prod = offeringsManager.standaloneProduct(for: pack.id) {
                        await purchase(product: prod)
                    } else {
                        purchasingId = nil
                        errorId = pack.id
                    }
                }
            }
        } label: {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: purchaseButtonRadius)
                    .fill(Color(red: 0.70, green: 0.70, blue: 0.72))
                    .offset(y: 3)
                packPurchaseLabel(showSpinner: showSpinner)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: purchaseButtonRadius))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 45)
        }
        .buttonStyle(.plain)
        .disabled(showSpinner)
        .accessibilityLabel("Purchase \(credits.formatted()) credits for \(pack.priceString)")
        .accessibilityHint("One-time purchase. Credits expire in 90 days.")
    }

    @ViewBuilder
    private func packPurchaseLabel(showSpinner: Bool) -> some View {
        Group {
            if showSpinner {
                ProgressView().tint(.black.opacity(0.7)).scaleEffect(0.9)
            } else {
                Text("Purchase")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(red: 0.09, green: 0.09, blue: 0.11))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
    }

    // MARK: - Actions

    private func purchase(_ package: Package) async {
        let id = package.storeProduct.productIdentifier
        let credits = packMeta[id]?.credits ?? 0
        await runPurchase(id: id) { pm in
            await pm.purchase(package: package, creditsToGrant: credits)
        }
    }

    private func purchase(product: StoreProduct) async {
        let id = product.productIdentifier
        let credits = packMeta[id]?.credits ?? 0
        await runPurchase(id: id) { pm in
            await pm.purchase(product: product, creditsToGrant: credits)
        }
    }

    private func runPurchase(id: String, _ buy: (PurchaseManager) async -> PurchaseOutcome) async {
        guard let pm = purchaseManager else { return }
        purchasingId = id
        errorId = nil
        let outcome = await buy(pm)
        purchasingId = nil
        switch outcome {
        case .credited:
            isPresented = false
        case .pendingWebhook:
            // Purchase succeeded — StoreKit confirmed the transaction — but the credit grant
            // hadn't landed by the time polling gave up (slow webhook / cold backend). This is
            // NOT a failure: never show the red "Purchase failed" copy here, or a paying user
            // gets told their successful purchase failed. Credits will land shortly; the next
            // foreground fetch (ContentView's scenePhase == .active handler) picks them up.
            errorId = nil
            isPresented = false
        case .cancelled:
            break
        case .failed:
            errorId = id
        }
    }
}

#Preview {
    CreditStoreView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
