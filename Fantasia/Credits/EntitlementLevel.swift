// EntitlementLevel.swift
// Fantasia
// Maps RevenueCat entitlement identifiers to the app's subscription tiers (D-10).

import Foundation

enum EntitlementLevel: String, Codable, Equatable {
    case none    = ""        // No active subscription
    case basic   = "basic"
    case pro     = "pro"
    case creator = "creator"
}
