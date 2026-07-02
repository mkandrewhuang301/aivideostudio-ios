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
    // Flat credits/sec for xai/grok-imagine-video-1.5 — not resolution-tiered like `rates`.
    private(set) var grokImagineRate: Int = 8
    private(set) var isLoaded = false
    private var lastLoadDate: Date?
    private static let staleAfter: TimeInterval = 3600

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

    // Fallback image costs — matches IMAGE_MODEL_COSTS on backend
    private static let imageCostFallback: [String: Int] = [
        "openai/gpt-image-2-high":   13,
        "openai/gpt-image-2-medium": 5,
        "openai/gpt-image-2-low":    2,
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
            grokImagineRate = response.grokImagineRate ?? 8
            lastLoadDate = Date()
        } catch {
            if !isLoaded {
                rates = Self.fallback
                imageCosts = Self.imageCostFallback
            }
        }
        isLoaded = true
    }

    /// Perf: GET /rates was previously re-fetched on every single foreground with no guard.
    /// Rates change rarely (a manual server-side pricing update), so skip the network call
    /// unless we've never loaded successfully or it's been over an hour. Used for the
    /// scenePhase == .active trigger; the launch-time call still uses load() unconditionally.
    func loadIfNeeded() async {
        let isStale = lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        guard isStale else { return }
        await load()
    }

    func cost(model: String, durationSeconds: Int, resolution: String, hasVideoReference: Bool) -> Int {
        // Flat credits/sec, not resolution-tiered — bypasses the `rates` table entirely.
        if model == "xai/grok-imagine-video-1.5" {
            return Int(ceil(Double(durationSeconds) * Double(grokImagineRate)))
        }
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
