// PaywallView.swift
// Fantasia
// Custom paywall screen (D-14: NOT RevenueCat built-in component).
// AUTH-03: Hard gate — no dismiss affordance. Only exits: purchase success or restore success.
// D-02: Annual pre-selected. D-13: Monthly/Annual toggle + Basic/Pro/Creator cards stacked.
// D-15: Restore purchases + Terms/Privacy links required.

import SwiftUI
import RevenueCat

enum BillingPeriod: String, CaseIterable {
    case monthly = "Monthly"
    case annual  = "Annual"
}

struct PaywallView: View {
    @Binding var isPresented: Bool
    @Environment(CreditManager.self) private var creditManager
    @Environment(OfferingsManager.self) private var offeringsManager
    @State private var purchaseManager: PurchaseManager?
    @State private var selectedPeriod: BillingPeriod = .annual   // D-02: annual pre-selected
    @State private var purchasingPlanId: String? = nil
    @State private var isRestoring: Bool = false
    @State private var restoreMessage: String? = nil
    @State private var errorMessage: String? = nil

    private let accent   = Color(red: 0.55, green: 0.35, blue: 1.0) // #8C59FF
    private let bgColor  = Color(red: 0.059, green: 0.059, blue: 0.067) // #0F0F11

    // MARK: — Plan Data

    private struct PlanData {
        let productId: String
        let monthlyDisplayPrice: String   // fallback if RevenueCat offline
        let annualEquivPrice: String      // per-month equivalent for annual
        let strikethroughMonthlyPrice: String? // shown when annual selected
        let billingNote: String?          // e.g. "Billed $95.88 annually"
        let credits: String               // e.g. "500 credits/month"
        let features: [String]
    }

    private let planData: [String: (monthly: PlanData, annual: PlanData)] = [
        "Basic": (
            monthly: PlanData(
                productId: "com.fantasiaai.basic_monthly",
                monthlyDisplayPrice: "$9.99",
                annualEquivPrice: "$9.99",
                strikethroughMonthlyPrice: nil,
                billingNote: nil,
                credits: "500 credits/month",
                features: [
                    "720p generation",
                    "Standard queue",
                    "500 credits/month (~7 videos)"
                ]
            ),
            annual: PlanData(
                productId: "com.fantasiaai.basic_yearly",
                monthlyDisplayPrice: "$7.99",
                annualEquivPrice: "$7.99",
                strikethroughMonthlyPrice: "$9.99",
                billingNote: "Billed $95.88 annually",
                credits: "500 credits/month",
                features: [
                    "720p generation",
                    "Standard queue",
                    "500 credits/month (~7 videos)"
                ]
            )
        ),
        "Pro": (
            monthly: PlanData(
                productId: "com.fantasiaai.pro_monthly",
                monthlyDisplayPrice: "$24.99",
                annualEquivPrice: "$24.99",
                strikethroughMonthlyPrice: nil,
                billingNote: nil,
                credits: "1,400 credits/month",
                features: [
                    "Up to 1080p resolution",
                    "Priority queue",
                    "1,400 credits/month (~21 videos)",
                    "All models"
                ]
            ),
            annual: PlanData(
                productId: "com.fantasiaai.pro_yearly",
                monthlyDisplayPrice: "$19.99",
                annualEquivPrice: "$19.99",
                strikethroughMonthlyPrice: "$24.99",
                billingNote: "Billed $239.88 annually",
                credits: "1,400 credits/month",
                features: [
                    "Up to 1080p resolution",
                    "Priority queue",
                    "1,400 credits/month (~21 videos)",
                    "All models"
                ]
            )
        ),
        "Creator": (
            monthly: PlanData(
                productId: "com.fantasiaai.creator_monthly",
                monthlyDisplayPrice: "$99.99",
                annualEquivPrice: "$99.99",
                strikethroughMonthlyPrice: nil,
                billingNote: nil,
                credits: "5,800 credits/month",
                features: [
                    "Up to 1080p resolution",
                    "Highest priority queue",
                    "5,800 credits/month (~87 videos)",
                    "All models"
                ]
            ),
            annual: PlanData(
                productId: "com.fantasiaai.creator_yearly",
                monthlyDisplayPrice: "$79.99",
                annualEquivPrice: "$79.99",
                strikethroughMonthlyPrice: "$99.99",
                billingNote: "Billed $959.88 annually",
                credits: "5,800 credits/month",
                features: [
                    "Up to 1080p resolution",
                    "Highest priority queue",
                    "5,800 credits/month (~87 videos)",
                    "All models"
                ]
            )
        )
    ]

    // MARK: — Helpers

    private func currentData(for tier: String) -> PlanData? {
        guard let pair = planData[tier] else { return nil }
        return selectedPeriod == .monthly ? pair.monthly : pair.annual
    }

    private func package(for productId: String) -> Package? {
        offeringsManager.package(for: productId)
    }

    private func displayPrice(for data: PlanData) -> String {
        if let pkg = package(for: data.productId) {
            return pkg.storeProduct.localizedPriceString
        }
        // Offline fallback: locally-cached last-known price, else the hardcoded default.
        return offeringsManager.cachedPrice(for: data.productId) ?? data.monthlyDisplayPrice
    }

    // MARK: — Body

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 32) {

                    // Header
                    VStack(spacing: 8) {
                        Text("Fantasia")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Start creating cinematic AI videos.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Billing period toggle
                    billingToggle

                    // Plan cards — stacked vertically (D-13: all 3 visible)
                    planCards

                    // Error message — inline below cards
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    // Legal footer (D-15)
                    legalFooter
                }
                .padding(.horizontal, 24) // lg
                .padding(.top, 48)        // 2xl
                .padding(.bottom, 64)     // 3xl
            }

            // X dismiss button overlay (D-09: top-right, 32pt circle, white.opacity(0.08) background)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    .padding(.trailing, 20)
                }
                Spacer()
            }
            .padding(.top, 16)
        }
        .task {
            let manager = PurchaseManager(creditManager: creditManager)
            purchaseManager = manager
            await offeringsManager.refreshIfNeeded() // no-op if we already have fresh packages
        }
    }

    // MARK: — Billing Toggle

    private var billingToggle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
                .frame(height: 44)

            HStack(spacing: 0) {
                ForEach(BillingPeriod.allCases, id: \.self) { period in
                    Button {
                        if !UIAccessibility.isReduceMotionEnabled {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedPeriod = period
                            }
                        } else {
                            selectedPeriod = period
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(period.rawValue)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(selectedPeriod == period ? .white : Color.secondary)

                            if period == .annual {
                                Text("Best value")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .background(accent, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            Group {
                                if selectedPeriod == period {
                                    RoundedRectangle(cornerRadius: 8).fill(accent)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                    }
                    .accessibilityLabel(
                        period == .annual
                            ? "Annual billing, Best value\(selectedPeriod == period ? ", selected" : "")"
                            : "Monthly billing\(selectedPeriod == period ? ", selected" : "")"
                    )
                    .accessibilityAddTraits(selectedPeriod == period ? .isSelected : [])
                }
            }
            .padding(2)
        }
    }

    // MARK: — Plan Cards

    @ViewBuilder
    private var planCards: some View {
        VStack(spacing: 12) {
            // Basic — outlined CTA
            if let data = currentData(for: "Basic") {
                PlanCardView(
                    planName: "Basic",
                    price: displayPrice(for: data),
                    strikethroughPrice: selectedPeriod == .annual ? data.strikethroughMonthlyPrice : nil,
                    billingNote: selectedPeriod == .annual ? data.billingNote : nil,
                    creditsText: data.credits,
                    features: data.features,
                    ctaLabel: "Get Basic",
                    isMostPopular: false,
                    isPrimary: false,
                    isLoading: purchasingPlanId == data.productId,
                    isDisabled: purchasingPlanId != nil || isRestoring
                ) {
                    Task { await purchase(productId: data.productId) }
                }
            }

            // Pro — accent-filled CTA + "Most Popular" badge
            if let data = currentData(for: "Pro") {
                PlanCardView(
                    planName: "Pro",
                    price: displayPrice(for: data),
                    strikethroughPrice: selectedPeriod == .annual ? data.strikethroughMonthlyPrice : nil,
                    billingNote: selectedPeriod == .annual ? data.billingNote : nil,
                    creditsText: data.credits,
                    features: data.features,
                    ctaLabel: "Get Pro",
                    isMostPopular: true,
                    isPrimary: true,
                    isLoading: purchasingPlanId == data.productId,
                    isDisabled: purchasingPlanId != nil || isRestoring
                ) {
                    Task { await purchase(productId: data.productId) }
                }
            }

            // Creator — outlined CTA (same as Basic per UI-SPEC)
            if let data = currentData(for: "Creator") {
                PlanCardView(
                    planName: "Creator",
                    price: displayPrice(for: data),
                    strikethroughPrice: selectedPeriod == .annual ? data.strikethroughMonthlyPrice : nil,
                    billingNote: selectedPeriod == .annual ? data.billingNote : nil,
                    creditsText: data.credits,
                    features: data.features,
                    ctaLabel: "Get Creator",
                    isMostPopular: false,
                    isPrimary: false,
                    isLoading: purchasingPlanId == data.productId,
                    isDisabled: purchasingPlanId != nil || isRestoring
                ) {
                    Task { await purchase(productId: data.productId) }
                }
            }
        }
    }

    // MARK: — Legal Footer (D-15)

    private var legalFooter: some View {
        VStack(spacing: 8) {
            Button {
                Task { await restore() }
            } label: {
                Text(isRestoring ? "Restoring..." : "Restore Purchases")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isRestoring ? 0.5 : 1.0)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isRestoring || purchasingPlanId != nil)

            if let msg = restoreMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Link("Terms of Service",
                     destination: URL(string: "https://fantasiaai.app/terms")!)
                Text("·").foregroundStyle(.secondary)
                Link("Privacy Policy",
                     destination: URL(string: "https://fantasiaai.app/privacy")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: — Actions

    private func purchase(productId: String) async {
        guard let pm = purchaseManager else { return }
        guard let pkg = package(for: productId) else {
            errorMessage = "Purchase failed. Try again or restore."
            return
        }
        purchasingPlanId = productId
        errorMessage = nil
        await pm.purchase(package: pkg)
        purchasingPlanId = nil
        if let err = pm.purchaseError {
            errorMessage = err
        } else {
            isPresented = false
        }
    }

    private func restore() async {
        guard let pm = purchaseManager else { return }
        isRestoring = true
        restoreMessage = nil
        errorMessage = nil
        await pm.restorePurchases()
        isRestoring = false
        if let err = pm.purchaseError {
            restoreMessage = err
        } else if creditManager.entitlementLevel == .none {
            restoreMessage = "No active subscription found."
        } else {
            isPresented = false
        }
    }
}

#Preview {
    PaywallView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
