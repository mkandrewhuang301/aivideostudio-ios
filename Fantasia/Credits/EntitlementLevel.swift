// EntitlementLevel.swift
// Fantasia
// Maps RevenueCat entitlement identifiers to the app's subscription tiers (D-10).

import Foundation

enum EntitlementLevel: String, Codable, Equatable {
    case none    = ""        // No active subscription
    case basic   = "basic"
    case pro     = "pro"
    case creator = "creator"

    /// Monthly subscription credit allotment for this plan tier.
    var monthlyCredits: Int {
        switch self {
        case .none:    return 0
        case .basic:   return 500
        case .pro:     return 1_400
        case .creator: return 5_800
        }
    }
}
