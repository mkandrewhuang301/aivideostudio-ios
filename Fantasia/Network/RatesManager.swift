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
    // Flat credits/sec for DreamActor (Motion Transfer avatar runs) — not resolution-tiered.
    // D-18: PresetInputSheet shows the exact live cost from this before Generate.
    private(set) var dreamactorRate: Double = 5.0
    // Video upscaler (Enhancer): [tier ("standard"|"pro"): [resolution: [fpsBand ("lte30"|"gt30"): credits/sec]]]
    private(set) var upscalerRates: [String: [String: [String: Double]]] = RatesManager.upscalerFallback
    private(set) var isLoaded = false
    private var lastLoadDate: Date?
    private static let staleAfter: TimeInterval = 3600

    // Fallback in credits/sec (cents rule: 1 credit = 1 cent of provider cost, CENTS_PER_DOLLAR=100
    // × dollar rate), used if network call fails. Previously on the old 50-credits/$1 scale
    // (D-21/Pitfall 1) — values below are the corrected cents-scale numbers.
    private static let fallback: [String: [String: [String: Double]]] = [
        "bytedance/seedance-2.0-fast": [
            "nonVideoIn": ["480p": 7.0,  "720p": 15.0],
            "videoIn":    ["480p": 8.0,  "720p": 17.0],
        ],
        "bytedance/seedance-2.0-mini": [
            "nonVideoIn": ["480p": 4.0,  "720p": 9.0],
            "videoIn":    ["480p": 5.0,  "720p": 11.0],
        ],
        "bytedance/seedance-2.0": [
            "nonVideoIn": ["480p": 8.0,  "720p": 18.0, "1080p": 45.0, "4k": 100.0],
            "videoIn":    ["480p": 10.0, "720p": 22.0, "1080p": 55.0, "4k": 125.0],
        ],
    ]

    // Fallback image costs — matches IMAGE_MODEL_COSTS on backend
    private static let imageCostFallback: [String: Int] = [
        "openai/gpt-image-2-high":   13,
        "openai/gpt-image-2-medium": 5,
        "openai/gpt-image-2-low":    2,
    ]

    // DreamActor $0.05/sec × CENTS_PER_DOLLAR (100) = 5.0 credits/sec (generationService.ts DREAMACTOR_RATE).
    private static let dreamactorFallback: Double = 5.0

    // bytedance/video-upscaler tiered fallback, converted from VIDEO_UPSCALER_RATES ($/sec) to
    // credits/sec via the cents rule (× 100). Matches generationService.ts verbatim.
    private static let upscalerFallback: [String: [String: [String: Double]]] = [
        "standard": [
            "720p":  ["lte30": 0.3443,  "gt30": 0.6887],
            "1080p": ["lte30": 0.6887,  "gt30": 1.3773],
            "2k":    ["lte30": 1.3773,  "gt30": 2.7548],
            "4k":    ["lte30": 2.7548,  "gt30": 5.5097],
        ],
        "pro": [
            "720p":  ["lte30": 3.4435,  "gt30": 6.8870],
            "1080p": ["lte30": 6.8870,  "gt30": 13.7742],
            "2k":    ["lte30": 13.7742, "gt30": 27.5482],
            "4k":    ["lte30": 27.5482, "gt30": 55.0965],
        ],
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
            dreamactorRate = response.dreamactorRate ?? Self.dreamactorFallback
            upscalerRates = response.upscalerRates ?? Self.upscalerFallback
            lastLoadDate = Date()
        } catch {
            if !isLoaded {
                rates = Self.fallback
                imageCosts = Self.imageCostFallback
                dreamactorRate = Self.dreamactorFallback
                upscalerRates = Self.upscalerFallback
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

    /// DreamActor (Motion Transfer) live cost — D-18: shown from the picked driving video's real
    /// duration before Generate, same pattern as the composer's live cost label.
    func dreamactorCost(durationSeconds: Int) -> Int {
        Int(ceil(Double(durationSeconds) * dreamactorRate))
    }

    /// bytedance/video-upscaler (Enhancer) live cost. Defaults to the 'standard' tier and 720p ≤30fps
    /// band, matching the server's default in computeUpscalerCost — 'pro' is Replicate-allowlist-only.
    func upscalerCost(
        durationSeconds: Int,
        tier: String = "standard",
        resolution: String = "720p",
        fps: Int = 30
    ) -> Int {
        let table = upscalerRates.isEmpty ? Self.upscalerFallback : upscalerRates
        let tierRates = table[tier] ?? table["standard"] ?? Self.upscalerFallback["standard"] ?? [:]
        let band = fps > 30 ? "gt30" : "lte30"
        let creditsPerSec = tierRates[resolution]?[band] ?? tierRates["720p"]?[band] ?? 0
        return Int(ceil(Double(durationSeconds) * creditsPerSec))
    }
}
