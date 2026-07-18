// PlanCatalog.swift
// Fantasia
// Shared subscription plan data — single source of truth for TierPlanSelectorView, used by
// both PaywallView (new subscribers) and ManageSubscriptionView (existing subscribers).
// Design locked with Andrew over ~16 mockup iterations (paywall-tiers-plan.md, 2026-07-17):
// one shared tabbed tier screen, fixed 7-row feature checklist (rows never move — only the
// per-tier mark/value differs), one-press Annual/Monthly purchase buttons (no toggle).

import Foundation

/// Per-billing-period purchase data for one tier.
struct PlanData {
    let productId: String
    /// This period's per-month display price, e.g. "$9.99" (monthly) or "$7.99" (annual equiv).
    let price: String
    /// Annual-only: the monthly price to show struck through next to `price` on the Annual
    /// button (nil on the monthly variant).
    let strikethroughMonthlyPrice: String?
    /// Annual-only: plain total sublabel under "Get Annual", e.g. "$95.88/year" (nil on monthly).
    let annualTotalPrice: String?
}

/// Everything TierPlanSelectorView needs to render one tier tab: descriptor line, the big
/// SF Mono credits numeral + "≈ N videos" sub-label, and both billing-period purchase options.
struct TierInfo {
    let descriptor: String
    let creditsPerMonth: Int
    let approxVideos: Int
    let monthly: PlanData
    let annual: PlanData
}

/// One row of the fixed 7-row feature checklist — identical labels across every tier; only the
/// per-tier mark (yes/no) or numeric value differs. Rows never move/reorder.
struct ChecklistRow {
    enum Cell {
        case yes
        case no
        case numeric(String)
    }

    let label: String
    let basic: Cell
    let pro: Cell
    let creator: Cell

    func cell(for tier: String) -> Cell {
        switch tier {
        case "Basic":   return basic
        case "Pro":     return pro
        case "Creator": return creator
        default:        return basic
        }
    }
}

enum PlanCatalog {
    // Ordered ascending by price — drives display order everywhere tiers are listed.
    static let tierOrder = ["Basic", "Pro", "Creator"]

    static let tiers: [String: TierInfo] = [
        "Basic": TierInfo(
            descriptor: "For people just exploring AI video.",
            creditsPerMonth: 500,
            approxVideos: 7,
            monthly: PlanData(
                productId: "com.fantasiaai.basic_monthly",
                price: "$9.99",
                strikethroughMonthlyPrice: nil,
                annualTotalPrice: nil
            ),
            annual: PlanData(
                productId: "com.fantasiaai.basic_yearly",
                price: "$7.99",
                strikethroughMonthlyPrice: "$9.99",
                annualTotalPrice: "$95.88/year"
            )
        ),
        "Pro": TierInfo(
            descriptor: "For people who want more room to create.",
            creditsPerMonth: 1_400,
            approxVideos: 21,
            monthly: PlanData(
                productId: "com.fantasiaai.pro_monthly",
                price: "$24.99",
                strikethroughMonthlyPrice: nil,
                annualTotalPrice: nil
            ),
            annual: PlanData(
                productId: "com.fantasiaai.pro_yearly",
                price: "$19.99",
                strikethroughMonthlyPrice: "$24.99",
                annualTotalPrice: "$239.88/year"
            )
        ),
        "Creator": TierInfo(
            descriptor: "For people who want the best tools.",
            creditsPerMonth: 5_800,
            approxVideos: 87,
            monthly: PlanData(
                productId: "com.fantasiaai.creator_monthly",
                price: "$99.99",
                strikethroughMonthlyPrice: nil,
                annualTotalPrice: nil
            ),
            annual: PlanData(
                productId: "com.fantasiaai.creator_yearly",
                price: "$79.99",
                strikethroughMonthlyPrice: "$99.99",
                annualTotalPrice: "$959.88/year"
            )
        ),
    ]

    /// Fixed 7-row feature checklist (locked design — paywall-tiers-plan.md). Row order and
    /// labels are identical across tiers; only the per-tier cell value differs.
    static let checklist: [ChecklistRow] = [
        ChecklistRow(label: "480p · 720p generation", basic: .yes, pro: .yes, creator: .yes),
        ChecklistRow(label: "1080p generation", basic: .no, pro: .yes, creator: .yes),
        ChecklistRow(label: "4K generation", basic: .no, pro: .no, creator: .yes),
        ChecklistRow(label: "All presets, effects & formats", basic: .yes, pro: .yes, creator: .yes),
        ChecklistRow(label: "Core models: Grok 1.5 Pro, Seedance Mini", basic: .yes, pro: .yes, creator: .yes),
        ChecklistRow(label: "Premium models: Seedance 2.0, Kling 3.0", basic: .no, pro: .yes, creator: .yes),
        ChecklistRow(
            label: "Parallel generations",
            basic: .numeric("1×"), pro: .numeric("2×"), creator: .numeric("4×")
        ),
    ]

    /// Every subscription product id across every tier/period — passed to
    /// OfferingsManager.refreshIfNeeded(ensuring:) so a product missing from the current
    /// offering still resolves via the direct-product fallback (see OfferingsManager).
    static let allProductIds: [String] = tierOrder.flatMap { tier -> [String] in
        guard let info = tiers[tier] else { return [] }
        return [info.monthly.productId, info.annual.productId]
    }

    /// Maps an active EntitlementLevel to its display tier name in `tiers`, or nil for `.none`.
    static func tierName(for level: EntitlementLevel) -> String? {
        switch level {
        case .none:    return nil
        case .basic:   return "Basic"
        case .pro:     return "Pro"
        case .creator: return "Creator"
        }
    }
}
