// PlanCatalog.swift
// Fantasia
// Shared subscription plan data — used by PaywallView (new subscribers) and
// ManageSubscriptionView (existing subscribers switching/reviewing plans).

import Foundation

struct PlanData {
    let productId: String
    let monthlyDisplayPrice: String   // fallback if RevenueCat offline
    let annualEquivPrice: String      // per-month equivalent for annual
    let strikethroughMonthlyPrice: String? // shown when annual selected
    let billingNote: String?          // e.g. "Billed $95.88 annually"
    let credits: String               // e.g. "500 credits/month"
    let features: [String]
}

enum PlanCatalog {
    // Ordered ascending by price — drives display order everywhere plans are listed.
    static let tierOrder = ["Basic", "Pro", "Creator"]

    static let plans: [String: (monthly: PlanData, annual: PlanData)] = [
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

    /// Maps an active EntitlementLevel to its display tier name in `plans`, or nil for `.none`.
    static func tierName(for level: EntitlementLevel) -> String? {
        switch level {
        case .none:    return nil
        case .basic:   return "Basic"
        case .pro:     return "Pro"
        case .creator: return "Creator"
        }
    }
}
