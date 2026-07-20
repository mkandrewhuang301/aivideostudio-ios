// TierPlanSelectorView.swift
// Fantasia
// Shared tier screen used by BOTH PaywallView (new subscriber; hard-paywall context) and
// ManageSubscriptionView (existing subscriber) — Basic/Pro/Creator tabs, fixed 7-row feature
// checklist, one-press Annual/Monthly purchase. Design locked with Andrew over ~16 mockup
// iterations (paywall-tiers-plan.md, 2026-07-17; mockup source at
// ~/.planning/sketches/fantasia-paywall-tiers-final.html) — do not redesign.
//
// Opens on "Pro" unless the user already has an active tier, in which case it opens on their
// tier and shows a "Your current plan" pill instead of purchase buttons for it.

import SwiftUI
import RevenueCat
import StoreKit

struct TierPlanSelectorView: View {
    @Binding var isPresented: Bool
    /// Manage-subscription context adds a "Cancel or change plan in the App Store" link to the
    /// footer (the native sheet is the only place a user can cancel). Off for the paywall flow.
    var showAppStoreManage: Bool = false
    @Environment(CreditManager.self) private var creditManager
    @Environment(OfferingsManager.self) private var offeringsManager
    @Environment(ThemeManager.self) private var theme
    @State private var purchaseManager: PurchaseManager?
    @State private var selectedTier: String = "Pro"
    @State private var hasResolvedInitialTier = false
    @State private var purchasingProductId: String? = nil
    @State private var isRestoring = false
    @State private var isOpeningAppStore = false
    @State private var errorMessage: String? = nil
    @State private var restoreMessage: String? = nil
    @State private var renewalDate: Date?
    @State private var isManagePillExpanded = false
    @State private var managePillAnimationSequence = 0

    // MARK: - Locked design constants

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)               // #8C59FF (existing app accent)
    private let creatorGradient = LinearGradient(
        colors: [
            Color(red: 0.663, green: 0.545, blue: 1.0),   // #A98BFF
            Color(red: 0.851, green: 0.545, blue: 0.878), // #D98BE0
            Color(red: 0.910, green: 0.659, blue: 0.298),  // #E8A84C
        ],
        startPoint: .leading, endPoint: .trailing
    )
    private let goodGreen = Color(red: 0.247, green: 0.749, blue: 0.467)  // #3FBF77
    private let badRed    = Color(red: 0.788, green: 0.322, blue: 0.306) // #C9524E
    private let mutedGray = Color(red: 0.596, green: 0.584, blue: 0.624) // #98959F
    private let dimGray   = Color(red: 0.306, green: 0.294, blue: 0.341) // #4E4B57
    private let hairline  = Color.white.opacity(0.08)

    /// Reuses CreditStoreView's mono-numeral conventions verbatim (locked design requirement).
    private let monoTracking: CGFloat = -1.1
    private func techFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    private var currentTier: String? {
        PlanCatalog.tierName(for: creditManager.entitlementLevel)
    }

    private var currentInfo: TierInfo {
        PlanCatalog.tiers[selectedTier] ?? PlanCatalog.tiers["Pro"]!
    }

    private var isAnyPurchasePending: Bool {
        purchasingProductId != nil || isRestoring
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if showAppStoreManage {
                manageTabBar
            } else {
                tabBar
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if showAppStoreManage {
                        manageHero
                            .padding(.top, 22)
                    } else {
                        Text(currentInfo.descriptor)
                            .font(.system(size: 13))
                            .foregroundStyle(mutedGray)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 22)

                        creditsRow
                            .padding(.top, 12)
                    }

                    checklistSection
                        .padding(.top, showAppStoreManage ? 16 : 22)

                    purchaseSection
                        .padding(.top, showAppStoreManage ? 16 : 22)

                    footer
                        .padding(.top, 16)
                }
                .padding(.horizontal, showAppStoreManage ? 16 : 20)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !hasResolvedInitialTier {
                hasResolvedInitialTier = true
                if let currentTier { selectedTier = currentTier }
            }
            let pm = PurchaseManager(creditManager: creditManager)
            purchaseManager = pm
            // Settle RC identity before the tap so purchase goes straight to the StoreKit sheet
            // (mirrors CreditStoreView).
            Task { _ = await pm.ensureIdentified() }
            // Warm the backend now — the post-purchase credit poll has a bounded window and a
            // cold Railway boot can eat most of it (mirrors CreditStoreView).
            Task { await APIClient.shared.pingHealth() }
            // NEVER read only the current offering — subscription products may live in a
            // non-current offering; ensure() falls back to a direct product fetch if the package
            // lookup misses (the hard-won top-up lesson, see OfferingsManager).
            await offeringsManager.refreshIfNeeded(ensuring: PlanCatalog.allProductIds)
            if showAppStoreManage {
                await loadRenewalDate()
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let tabWidth = geo.size.width / CGFloat(PlanCatalog.tierOrder.count)
                let index = CGFloat(PlanCatalog.tierOrder.firstIndex(of: selectedTier) ?? 1)
                ZStack(alignment: .bottomLeading) {
                    HStack(spacing: 0) {
                        ForEach(PlanCatalog.tierOrder, id: \.self) { tier in
                            tabButton(tier).frame(width: tabWidth)
                        }
                    }
                    underlineIndicator
                        .frame(width: tabWidth, height: selectedTier == "Creator" ? 2 : 1.5)
                        .offset(x: tabWidth * index)
                        .animation(.easeInOut(duration: 0.25), value: selectedTier)
                }
            }
            .frame(height: 44)

            Rectangle().fill(hairline).frame(height: 1)
        }
    }

    /// Frosted sliding-pill segmented control (locked V1 manage design —
    /// ~/gen-redesign-mockups/manage-subscription-interactive.html, 2026-07-18).
    /// The pill is a material-backed frosted panel that slides between tabs; the selected
    /// tab's label takes its tier identity color (Pro = solid accent, Creator = gradient).
    private let manageSegHeight: CGFloat = 42

    private var manageTabBar: some View {
        GeometryReader { geo in
            let tabWidth = (geo.size.width - 6) / CGFloat(PlanCatalog.tierOrder.count)
            let index = CGFloat(PlanCatalog.tierOrder.firstIndex(of: selectedTier) ?? 1)
            ZStack(alignment: .topLeading) {
                frostedPill
                    .frame(width: tabWidth, height: manageSegHeight - 6)
                    .scaleEffect(
                        x: isManagePillExpanded ? 1.14 : 1,
                        y: isManagePillExpanded ? 1.06 : 1
                    )
                    .offset(x: 3 + tabWidth * index, y: 3)

                HStack(spacing: 0) {
                    ForEach(PlanCatalog.tierOrder, id: \.self) { tier in
                        manageTabButton(tier)
                            .frame(width: tabWidth, height: manageSegHeight - 6)
                    }
                }
                .padding(3)
            }
        }
        .frame(height: manageSegHeight)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(theme.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    /// Frosted glass: blur + ~9% white fill, a 16% border, a soft top sheen, and a drop shadow.
    private var frostedPill: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.ultraThinMaterial)
            .overlay { RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)) }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.12), .clear],
                                         startPoint: .top, endPoint: .center))
            }
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
    }

    private func manageTabButton(_ tier: String) -> some View {
        let isSelected = selectedTier == tier
        return Button {
            guard tier != selectedTier else { return }

            if UIAccessibility.isReduceMotionEnabled {
                isManagePillExpanded = false
                selectedTier = tier
            } else {
                managePillAnimationSequence += 1
                let animationSequence = managePillAnimationSequence

                // Stretch while traveling, then settle at the selected tier. The brief
                // rubber-band shape gives the control the same responsive feel as Tinder's
                // animated selectors without changing the control's resting footprint.
                withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
                    isManagePillExpanded = true
                    selectedTier = tier
                }

                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard managePillAnimationSequence == animationSequence else { return }
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                        isManagePillExpanded = false
                    }
                }
            }
        } label: {
            manageTabLabel(tier, isSelected: isSelected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func manageTabLabel(_ tier: String, isSelected: Bool) -> some View {
        let label = Text(tier).font(.system(size: 14, weight: .semibold))
        if isSelected {
            switch tier {
            case "Pro":     label.foregroundStyle(accent)
            case "Creator": label.foregroundStyle(creatorGradient)
            default:        label.foregroundStyle(theme.textPrimary)
            }
        } else {
            label.foregroundStyle(theme.textSecondary)
        }
    }

    private func tabButton(_ tier: String) -> some View {
        let isSelected = selectedTier == tier
        return Button {
            if !UIAccessibility.isReduceMotionEnabled {
                withAnimation(.easeInOut(duration: 0.25)) { selectedTier = tier }
            } else {
                selectedTier = tier
            }
        } label: {
            tabLabel(tier, isSelected: isSelected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func tabLabel(_ tier: String, isSelected: Bool) -> some View {
        switch tier {
        case "Pro":
            Text("Pro")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .opacity(isSelected ? 1.0 : 0.45)
        case "Creator":
            Text("Creator")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(creatorGradient)
                .opacity(isSelected ? 1.0 : 0.45)
        default:
            Text("Basic")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : dimGray)
        }
    }

    @ViewBuilder
    private var underlineIndicator: some View {
        switch selectedTier {
        case "Pro":     Rectangle().fill(accent)
        case "Creator": Rectangle().fill(creatorGradient)
        default:        Rectangle().fill(Color.primary)
        }
    }

    // MARK: - Credits numeral

    private var creditsNumeralStyle: AnyShapeStyle {
        switch selectedTier {
        case "Pro":     return AnyShapeStyle(accent)
        case "Creator": return AnyShapeStyle(creatorGradient)
        default:        return AnyShapeStyle(Color.primary)
        }
    }

    private var creditsRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(currentInfo.creditsPerMonth.formatted())
                .font(techFont(.largeTitle, weight: .bold))
                .tracking(monoTracking)
                .foregroundStyle(creditsNumeralStyle)

            VStack(alignment: .leading, spacing: 2) {
                Text("CREDITS MONTHLY")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(mutedGray)
                Text("≈ \(currentInfo.approxVideos) videos")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(dimGray)
            }
        }
    }

    private var manageHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(currentInfo.descriptor)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(currentInfo.creditsPerMonth.formatted())
                    .font(techFont(.largeTitle, weight: .bold))
                    .tracking(monoTracking)
                    .foregroundStyle(creditsNumeralStyle)

                Text("CREDITS MONTHLY")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(1.35)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Checklist (fixed 7 rows — never reorder; only the per-tier cell value changes)

    private var checklistSection: some View {
        Group {
            if showAppStoreManage {
                VStack(spacing: 0) {
                    ForEach(Array(PlanCatalog.checklist.enumerated()), id: \.element.label) { index, row in
                        manageChecklistRow(row)
                        if index < PlanCatalog.checklist.count - 1 {
                            Rectangle().fill(theme.divider).frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    Rectangle().fill(hairline).frame(height: 1)
                    ForEach(PlanCatalog.checklist, id: \.label) { row in
                        checklistRow(row)
                        Rectangle().fill(hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    private func manageChecklistRow(_ row: ChecklistRow) -> some View {
        let cell = row.cell(for: selectedTier)
        return HStack(spacing: 12) {
            manageMarkView(for: cell)
                .frame(width: 16)
            Text(row.label)
                .font(.system(size: 13.5))
                .foregroundStyle(manageLabelColor(for: cell))
            Spacer(minLength: 8)
            if case .numeric(let value) = cell {
                Text(value)
                    .font(techFont(.body, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(manageNumericValueStyle)
            }
        }
        .padding(.vertical, 12)
    }

    /// Per-tier numeric value color for the manage checklist (mockup: Basic = plain text,
    /// Pro = solid accent, Creator = gradient) — unlike the paywall's `numericValueStyle`,
    /// which dims Basic.
    private var manageNumericValueStyle: AnyShapeStyle {
        switch selectedTier {
        case "Pro":     return AnyShapeStyle(accent)
        case "Creator": return AnyShapeStyle(creatorGradient)
        default:        return AnyShapeStyle(theme.textPrimary)
        }
    }

    @ViewBuilder
    private func manageMarkView(for cell: ChecklistRow.Cell) -> some View {
        switch cell {
        case .yes:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.green)
        case .no:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.red.opacity(0.75))
        case .numeric:
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private func manageLabelColor(for cell: ChecklistRow.Cell) -> Color {
        switch cell {
        case .no: return theme.textTertiary
        case .numeric, .yes: return theme.textPrimary
        }
    }

    private func checklistRow(_ row: ChecklistRow) -> some View {
        let cell = row.cell(for: selectedTier)
        return HStack(spacing: 14) {
            markView(for: cell)
                .frame(width: 16)
            Text(row.label)
                .font(.system(size: 13.5))
                .foregroundStyle(labelColor(for: cell))
            Spacer(minLength: 8)
            if case .numeric(let value) = cell {
                Text(value)
                    .font(techFont(.body, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(numericValueStyle)
            }
        }
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private func markView(for cell: ChecklistRow.Cell) -> some View {
        switch cell {
        case .yes:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(goodGreen)
        case .no:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(badRed)
        case .numeric:
            Color.clear.frame(width: 16, height: 16)
        }
    }

    private func labelColor(for cell: ChecklistRow.Cell) -> Color {
        switch cell {
        case .no:      return dimGray
        case .numeric: return selectedTier == "Basic" ? mutedGray : .primary
        case .yes:     return .primary
        }
    }

    private var numericValueStyle: AnyShapeStyle {
        switch selectedTier {
        case "Pro":     return AnyShapeStyle(accent)
        case "Creator": return AnyShapeStyle(creatorGradient)
        default:        return AnyShapeStyle(dimGray)
        }
    }

    // MARK: - Purchase section

    @ViewBuilder
    private var purchaseSection: some View {
        VStack(spacing: 10) {
            if selectedTier == currentTier {
                currentPlanPill
                if showAppStoreManage {
                    annualButton
                }
            } else {
                annualButton
                monthlyButton
            }
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 8)
        }
    }

    private var currentPlanPill: some View {
        Group {
            if showAppStoreManage {
                Text(currentPlanMessage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                theme.surfaceStrongBorder,
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    }
            } else {
                Text("Your current plan")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.14), lineWidth: 1)
                    }
            }
        }
    }

    private var currentPlanMessage: String {
        if let renewalDate {
            return "✓  This is your current plan — renews \(renewalDate.formatted(date: .abbreviated, time: .omitted))"
        }
        return "✓  This is your current plan"
    }

    @ViewBuilder
    private var annualButton: some View {
        if showAppStoreManage {
            manageAnnualButton
        } else {
            hardPaywallAnnualButton
        }
    }

    private var hardPaywallAnnualButton: some View {
        let data = currentInfo.annual
        let isPurchasing = purchasingProductId == data.productId
        let inkText = Color(red: 0.043, green: 0.043, blue: 0.051) // ~#0B0B0D, matches locked design's ink-on-white

        return Button {
            handleTap(productId: data.productId)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isPurchasing {
                        ProgressView().tint(inkText)
                    } else {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Get Annual")
                                    .font(.system(size: 15, weight: .bold))
                                if let total = data.annualTotalPrice {
                                    Text(total)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .opacity(0.55)
                                }
                            }
                            Spacer(minLength: 8)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if let strike = data.strikethroughMonthlyPrice {
                                    Text(strike)
                                        .font(techFont(.footnote, weight: .medium))
                                        .tracking(monoTracking)
                                        .strikethrough(true)
                                        .opacity(0.45)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text(data.price)
                                        .font(techFont(.body, weight: .bold))
                                        .tracking(monoTracking)
                                    Text("/mo")
                                        .font(.system(size: 11, weight: .medium))
                                        .opacity(0.6)
                                }
                            }
                        }
                        .foregroundStyle(inkText)
                        .padding(.horizontal, 18)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 58)

                // Floating "SAVE 20%" pill — pinned to the button's top-right edge, per locked design.
                Text("SAVE 20%")
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(accent, in: Capsule())
                    .offset(x: -14, y: -9)
            }
        }
        .buttonStyle(.plain)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isAnyPurchasePending)
        .accessibilityLabel("Get Annual, \(data.price) per month\(data.annualTotalPrice.map { ", billed \($0)" } ?? "")")
    }

    private var manageAnnualButton: some View {
        let data = currentInfo.annual
        let isPurchasing = purchasingProductId == data.productId
        let isCurrent = selectedTier == currentTier

        return Button {
            handleTap(productId: data.productId)
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(theme.textPrimary)
                } else {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(isCurrent ? "Switch to Annual" : "Get Annual")
                                    .font(.system(size: 15, weight: .bold))
                                Text("SAVE 20%")
                                    .font(.system(size: 9.5, weight: .heavy))
                                    .tracking(0.4)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(LinearGradient.brandPrimary, in: RoundedRectangle(cornerRadius: 5))
                            }
                            if let total = data.annualTotalPrice {
                                Text(total)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(data.price + "/mo")
                                .font(techFont(.body, weight: .bold))
                                .tracking(monoTracking)
                                .foregroundStyle(LinearGradient.brandPrimary)
                            if let strike = data.strikethroughMonthlyPrice {
                                Text(strike)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textSecondary)
                                    .strikethrough(true)
                            }
                        }
                    }
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(.plain)
        .background {
            LinearGradient.brandPrimary.opacity(0.22)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(LinearGradient.brandPrimary.opacity(0.5), lineWidth: 1))
        .disabled(isAnyPurchasePending)
        .accessibilityLabel("\(isCurrent ? "Switch to" : "Get") Annual, \(data.price) per month")
    }

    @ViewBuilder
    private var monthlyButton: some View {
        if showAppStoreManage {
            manageMonthlyButton
        } else {
            hardPaywallMonthlyButton
        }
    }

    private var hardPaywallMonthlyButton: some View {
        let data = currentInfo.monthly
        let isPurchasing = purchasingProductId == data.productId

        return Button {
            handleTap(productId: data.productId)
        } label: {
            Group {
                if isPurchasing {
                    ProgressView().tint(.primary)
                } else {
                    HStack {
                        Text("Get Monthly")
                            .font(.system(size: 15, weight: .bold))
                        Spacer(minLength: 8)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(data.price)
                                .font(techFont(.body, weight: .bold))
                                .tracking(monoTracking)
                            Text("/mo")
                                .font(.system(size: 11, weight: .medium))
                                .opacity(0.6)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 18)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .disabled(isAnyPurchasePending)
        .accessibilityLabel("Get Monthly, \(data.price) per month")
    }

    private var manageMonthlyButton: some View {
        let data = currentInfo.monthly
        let isPurchasing = purchasingProductId == data.productId

        return Button {
            handleTap(productId: data.productId)
        } label: {
            ZStack {
                if isPurchasing {
                    ProgressView().tint(theme.textPrimary)
                } else {
                    HStack {
                        Text("Get Monthly")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(data.price + "/mo")
                            .font(techFont(.body, weight: .bold))
                            .tracking(monoTracking)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(.plain)
        .background(theme.elevatedBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
        .disabled(isAnyPurchasePending)
        .accessibilityLabel("Get Monthly, \(data.price) per month")
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if showAppStoreManage {
            manageFooter
        } else {
            hardPaywallFooter
        }
    }

    private var hardPaywallFooter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Auto-renews until canceled")
                Text("·")
                Link("Terms", destination: URL(string: "https://fantasiaai.app/terms")!)
                Text("·")
                Button {
                    Task { await restore() }
                } label: {
                    Text(isRestoring ? "Restoring…" : "Restore purchases")
                }
                .disabled(isAnyPurchasePending)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

            if let restoreMessage {
                Text(restoreMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var manageFooter: some View {
        VStack(spacing: 8) {
            Button {
                Task { await restore() }
            } label: {
                Text(isRestoring ? "Restoring…" : "Restore Purchases")
                    .underline()
            }
            .disabled(isAnyPurchasePending)

            Button {
                openAppStoreManage()
            } label: {
                HStack(spacing: 6) {
                    if isOpeningAppStore { ProgressView().tint(theme.textSecondary) }
                    Text("Cancel or change plan in the App Store")
                        .underline()
                }
            }
            .disabled(isOpeningAppStore)

            if let restoreMessage {
                Text(restoreMessage)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.textSecondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.bottom, 2)
    }

    private func loadRenewalDate() async {
        guard let currentTier else { return }
        guard let customerInfo = try? await Purchases.shared.customerInfo() else { return }
        renewalDate = customerInfo.entitlements[currentTier.lowercased()]?.expirationDate
    }

    private func openAppStoreManage() {
        guard !isOpeningAppStore,
              let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        isOpeningAppStore = true
        Task {
            try? await AppStore.showManageSubscriptions(in: scene)
            isOpeningAppStore = false
        }
    }

    // MARK: - Actions

    /// One-press purchase: tapping either button dispatches immediately, no select-then-continue.
    /// Same purchase path as CreditStoreView — cached Package lookup with a direct-product
    /// fallback for a product living outside the current offering (never read only `current`).
    private func handleTap(productId: String) {
        if let pkg = offeringsManager.package(for: productId) {
            Task { await purchase(pkg: pkg) }
        } else if let prod = offeringsManager.standaloneProduct(for: productId) {
            Task { await purchase(product: prod) }
        } else {
            Task {
                purchasingProductId = productId
                errorMessage = nil
                let ok = await offeringsManager.awaitProduct(for: productId)
                if ok, let pkg = offeringsManager.package(for: productId) {
                    await purchase(pkg: pkg)
                } else if ok, let prod = offeringsManager.standaloneProduct(for: productId) {
                    await purchase(product: prod)
                } else {
                    purchasingProductId = nil
                    errorMessage = "Couldn't start purchase. Try again."
                }
            }
        }
    }

    private func purchase(pkg: Package) async {
        guard let pm = purchaseManager else { return }
        purchasingProductId = pkg.storeProduct.productIdentifier
        errorMessage = nil
        _ = await pm.purchase(package: pkg)
        purchasingProductId = nil
        if let err = pm.purchaseError {
            errorMessage = err
        } else {
            isPresented = false
        }
    }

    private func purchase(product: StoreProduct) async {
        guard let pm = purchaseManager else { return }
        purchasingProductId = product.productIdentifier
        errorMessage = nil
        _ = await pm.purchase(product: product)
        purchasingProductId = nil
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
    TierPlanSelectorView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
        .environment(ThemeManager())
        .background(Color.black)
}
