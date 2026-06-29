// GenerationOptionsPanel.swift
// Fantasia
// D-17: Always-visible options row above the prompt bar.
// D-18: Defaults — Fast model, 5s, 720p, 16:9, Audio On.
// D-19: Live credit cost preview between options row and prompt bar.
// Each pill opens a .confirmationDialog for selection (no extra sheet).

import SwiftUI

struct GenerationOptionsPanel: View {
    @Binding var selectedModel: String
    @Binding var selectedDuration: Int
    @Binding var selectedResolution: String
    @Binding var selectedAspectRatio: String
    @Binding var audioEnabled: Bool
    let hasVideoReference: Bool    // affects credit cost (videoIn vs nonVideoIn)

    @State private var showModelPicker = false
    @State private var showDurationPicker = false
    @State private var showResolutionPicker = false
    @State private var showAspectRatioPicker = false
    @State private var showAudioPicker = false

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // D-17: pills row — horizontal scroll, always visible above prompt bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    optionPill(
                        "Model",
                        value: selectedModel == "bytedance/seedance-2.0-fast" ? "Fast" : "Mini"
                    ) { showModelPicker = true }
                    optionPill("Duration", value: "\(selectedDuration)s") { showDurationPicker = true }
                    optionPill("Res", value: selectedResolution) { showResolutionPicker = true }
                    optionPill("Ratio", value: selectedAspectRatio) { showAspectRatioPicker = true }
                    optionPill("Audio", value: audioEnabled ? "On" : "Off") { showAudioPicker = true }
                }
                .padding(.horizontal, 24)
            }

            // D-19: credit preview — shown BELOW the pills row, above the prompt bar
            // RESEARCH.md Pitfall 4: NO audio multiplier — backend has none in computeCostCredits
            let cost = estimatedCost(
                model: selectedModel,
                duration: selectedDuration,
                resolution: selectedResolution,
                hasVideoRef: hasVideoReference
            )
            Text("~\(cost) credits")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())
                .padding(.horizontal, 24)
        }
        // D-18: Model picker — Fast | Mini, default Fast
        .confirmationDialog("Model", isPresented: $showModelPicker, titleVisibility: .visible) {
            Button("Fast (Seedance 2.0 Fast)") { selectedModel = "bytedance/seedance-2.0-fast" }
            Button("Mini (Seedance 2.0 Mini)") { selectedModel = "bytedance/seedance-2.0-mini" }
        }
        // D-18: Duration picker — 4s / 5s / 8s / 10s, default 5s
        .confirmationDialog("Duration", isPresented: $showDurationPicker, titleVisibility: .visible) {
            Button("4 seconds") { selectedDuration = 4 }
            Button("5 seconds") { selectedDuration = 5 }
            Button("8 seconds") { selectedDuration = 8 }
            Button("10 seconds") { selectedDuration = 10 }
        }
        // D-18: Resolution picker — 480p | 720p, default 720p
        .confirmationDialog("Resolution", isPresented: $showResolutionPicker, titleVisibility: .visible) {
            Button("480p") { selectedResolution = "480p" }
            Button("720p") { selectedResolution = "720p" }
        }
        // D-18: Aspect ratio picker — 16:9 | 9:16 | 1:1 | 4:3, default 16:9
        .confirmationDialog("Aspect Ratio", isPresented: $showAspectRatioPicker, titleVisibility: .visible) {
            Button("16:9 (Landscape)") { selectedAspectRatio = "16:9" }
            Button("9:16 (Portrait)") { selectedAspectRatio = "9:16" }
            Button("1:1 (Square)") { selectedAspectRatio = "1:1" }
            Button("4:3") { selectedAspectRatio = "4:3" }
        }
        // D-18: Audio picker — On | Off, default On
        .confirmationDialog("Audio", isPresented: $showAudioPicker, titleVisibility: .visible) {
            Button("Audio On") { audioEnabled = true }
            Button("Audio Off") { audioEnabled = false }
        }
    }

    // Pill button — matches chipRow visual style from GenerateView.swift (lines 124–157)
    private func optionPill(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // D-19: credit cost formula — MUST match backend computeCostCredits exactly
    // RESEARCH.md verified: NO audio multiplier in generationService.ts (Pitfall 4)
    private func estimatedCost(model: String, duration: Int, resolution: String, hasVideoRef: Bool) -> Int {
        let creditPerDollar = 50.0
        let rates: [String: [String: [String: Double]]] = [
            "bytedance/seedance-2.0-fast": [
                "nonVideoIn": ["480p": 0.07, "720p": 0.15],
                "videoIn":    ["480p": 0.08, "720p": 0.17],
            ],
            "bytedance/seedance-2.0-mini": [
                "nonVideoIn": ["480p": 0.04, "720p": 0.09],
                "videoIn":    ["480p": 0.05, "720p": 0.11],
            ],
        ]
        let rateSet = hasVideoRef ? "videoIn" : "nonVideoIn"
        let rate = rates[model]?[rateSet]?[resolution] ?? 0
        return Int(ceil(Double(duration) * rate * creditPerDollar))
    }
}
