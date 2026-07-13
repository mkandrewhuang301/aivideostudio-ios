// ManageSubscriptionView.swift
// Fantasia
// Fast, custom subscription management screen — replaces jumping straight to Apple's
// native AppStore.showManageSubscriptions() sheet, which is slow (round-trips to the
// App Store) and can prompt Apple ID re-authentication before showing anything.
// Pattern: mirrors CreditStoreView — reads OfferingsManager's cache so plans render
// instantly, and the current tier comes straight from CreditManager (already loaded).
// The native Apple sheet is only invoked when the user explicitly wants to cancel or
// change their payment method, via the "Manage in App Store" link below.

import SwiftUI
import RevenueCat
import StoreKit

struct ManageSubscriptionView: View {
    @Binding var isPresented: Bool
    @Environment(CreditManager.self) private var creditManager
    @Environment(OfferingsManager.self) private var offeringsManager
    @State private var purchaseManager: PurchaseManager?
    @State private var selectedPeriod: BillingPeriod = .annual
    @State private var purchasingPlanId: String? = nil
    @State private var isOpeningAppStore = false
    @State private var errorMessage: String? = nil

    private let accent  = Color(red: 0.55, green: 0.35, blue: 1.0)
    private let bgColor = Color(red: 0.059, green: 0.059, blue: 0.067)

    private var currentTier: String? {
        PlanCatalog.tierName(for: creditManager.entitlementLevel)
    }

    private func currentData(for tier: String) -> PlanData? {
        guard let pair = PlanCatalog.plans[tier] else { return nil }
        return selectedPeriod == .monthly ? pair.monthly : pair.annual
    }

    private func displayPrice(for data: PlanData) -> String {
        if let pkg = offeringsManager.package(for: data.productId) {
            return pkg.storeProduct.localizedPriceString
        }
        return offeringsManager.cachedPrice(for: data.productId) ?? data.monthlyDisplayPrice
    }

    var body: some View {
        ZStack(alignment: .top) {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 24) {
                        currentPlanCard

                        VStack(alignment: .leading, spacing: 16) {
                            Text(currentTier == nil ? "Choose a Plan" : "Switch Plan")
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            billingToggle
                            planCards
                        }

                        if let error = errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        appStoreLink
                        termsLinksRow
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 48)
                }
            }
        }
        .task {
            let manager = PurchaseManager(creditManager: creditManager)
            purchaseManager = manager
            await offeringsManager.refreshIfNeeded() // cache-first — no-op if already fresh
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Manage Subscription")
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
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    // MARK: - Current Plan

    @ViewBuilder
    private var currentPlanCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CURRENT PLAN")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)

            if let tier = currentTier {
                Text(tier)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text("\(creditManager.entitlementLevel.monthlyCredits.formatted()) credits/month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Free")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Subscribe below for monthly credits and higher resolutions.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    // MARK: - Billing Toggle

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

    // MARK: - Plan Cards

    @ViewBuilder
    private var planCards: some View {
        VStack(spacing: 12) {
            ForEach(PlanCatalog.tierOrder, id: \.self) { tier in
                if let data = currentData(for: tier) {
                    let isCurrent = tier == currentTier
                    PlanCardView(
                        planName: tier,
                        price: displayPrice(for: data),
                        strikethroughPrice: selectedPeriod == .annual ? data.strikethroughMonthlyPrice : nil,
                        billingNote: selectedPeriod == .annual ? data.billingNote : nil,
                        creditsText: data.credits,
                        features: data.features,
                        ctaLabel: isCurrent ? "Current Plan" : "Switch to \(tier)",
                        isMostPopular: tier == "Pro" && !isCurrent,
                        isPrimary: tier == "Pro" && !isCurrent,
                        isLoading: purchasingPlanId == data.productId,
                        isDisabled: isCurrent || purchasingPlanId != nil
                    ) {
                        Task { await purchase(productId: data.productId) }
                    }
                }
            }
        }
    }

    // MARK: - App Store Link

    private var appStoreLink: some View {
        VStack(spacing: 4) {
            Text("To cancel or change your payment method, use the App Store.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                guard !isOpeningAppStore else { return }
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                isOpeningAppStore = true
                Task {
                    try? await AppStore.showManageSubscriptions(in: scene)
                    isOpeningAppStore = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isOpeningAppStore {
                        ProgressView().tint(.secondary)
                    }
                    Text("Manage in App Store")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(minHeight: 44)
            }
            .disabled(isOpeningAppStore)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // This screen lets users directly purchase/switch subscription plans — a real purchase
    // point, same class as PaywallView — mirrors its Terms/Privacy link row exactly (2026-07-13,
    // this screen previously had neither).
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
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func purchase(productId: String) async {
        guard let pm = purchaseManager else { return }
        guard let pkg = offeringsManager.package(for: productId) else {
            errorMessage = "Couldn't start purchase. Try again."
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
}

#Preview {
    ManageSubscriptionView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
