// RatesManager.swift
// Fetches model rate table from GET /rates (public endpoint) and exposes cost computation.
// Falls back to hardcoded values if the network call fails so the UI always has numbers.

import Foundation

@Observable
final class RatesManager {
    // [model: [rateSet ("nonVideoIn" | "videoIn"): [resolution: credits/sec]]]
    // Server pre-multiplies dollar rates by CREDITS_PER_DOLLAR — clients never see that constant.
    private(set) var rates: [String: [String: [String: Double]]] = [:]
    // Flat credit cost per image model (e.g. "black-forest-labs/flux-schnell" → 5)
    private(set) var imageCosts: [String: Int] = [:]
    private(set) var isLoaded = false

    // Fallback in credits/sec (50 credits/$1 × dollar rate), used if network call fails.
    private static let fallback: [String: [String: [String: Double]]] = [
        "bytedance/seedance-2.0-fast": [
            "nonVideoIn": ["480p": 3.5,  "720p": 7.5],
            "videoIn":    ["480p": 4.0,  "720p": 8.5],
        ],
        "bytedance/seedance-2.0-mini": [
            "nonVideoIn": ["480p": 2.0,  "720p": 4.5],
            "videoIn":    ["480p": 2.5,  "720p": 5.5],
        ],
        "bytedance/seedance-2.0": [
            "nonVideoIn": ["480p": 4.0,  "720p": 9.0,  "1080p": 22.5, "4k": 50.0],
            "videoIn":    ["480p": 5.0,  "720p": 11.0, "1080p": 27.5, "4k": 62.5],
        ],
    ]

    // Fallback image costs — matches IMAGE_MODEL_COSTS on backend (08-02)
    private static let imageCostFallback: [String: Int] = [
        "black-forest-labs/flux-schnell": 5,
        "black-forest-labs/flux-dev": 15,
    ]

    func load() async {
        do {
            let response = try await APIClient.shared.fetchRates()
            rates = response.rates
            if let costs = response.imageCosts {
                imageCosts = costs
            } else {
                imageCosts = Self.imageCostFallback
            }
        } catch {
            if !isLoaded {
                rates = Self.fallback
                imageCosts = Self.imageCostFallback
            }
        }
        isLoaded = true
    }

    func cost(model: String, durationSeconds: Int, resolution: String, hasVideoReference: Bool) -> Int {
        let table = rates.isEmpty ? Self.fallback : rates
        let rateSet = hasVideoReference ? "videoIn" : "nonVideoIn"
        let creditsPerSec = table[model]?[rateSet]?[resolution] ?? 0
        return Int(ceil(Double(durationSeconds) * creditsPerSec))
    }

    /// Returns the flat credit cost for the given image model.
    /// Returns 0 for unknown models (defense-in-depth; backend validates before billing).
    func imageCost(for model: String) -> Int {
        let table = imageCosts.isEmpty ? Self.imageCostFallback : imageCosts
        return table[model] ?? 0
    }
}
