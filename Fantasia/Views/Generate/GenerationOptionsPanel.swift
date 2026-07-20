// GenerationOptionsPanel.swift
// Fantasia
// D-17: Always-visible options row inside the composer card.
// D-18: Defaults — Fast model, 5s, 720p, 16:9, Audio On.
// Model picker swaps between curated video/image models based on mode.
// Each model shows a checkmark + tagline so users know what they're picking.

import SwiftUI

// MARK: - Model catalog

struct ModelOption {
    let id: String
    let name: String
    let tagline: String
    let badge: String?   // credit cost badge, e.g. "5 credits" — image models only
    let requiresImage: Bool   // true = image-to-video only, no text-only mode (e.g. Grok Imagine)
    let forcedAudio: Bool     // true = provider always generates audio; pill is locked "Always On"

    init(
        id: String,
        name: String,
        tagline: String,
        badge: String? = nil,
        requiresImage: Bool = false,
        forcedAudio: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.badge = badge
        self.requiresImage = requiresImage
        self.forcedAudio = forcedAudio
    }
}

enum ImageResolution: String, CaseIterable, Identifiable {
    case square    = "1:1"
    case landscape = "4:3"
    case portrait  = "3:4"
    case wide      = "16:9"
    case tall      = "9:16"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .square:    return "Square · 1:1"
        case .portrait:  return "Portrait · 3:4"
        case .tall:      return "Instagram / TikTok · 9:16"
        case .landscape: return "Landscape · 4:3"
        case .wide:      return "Widescreen · 16:9"
        }
    }
}

enum ModelCatalog {
    static let video: [ModelOption] = [
        ModelOption(id: "bytedance/seedance-2.0-mini", name: "Seedance 2.0 Mini",
                    tagline: "Newest model - cheaper and faster than 2.0, good for testing ideas"),
        ModelOption(id: "bytedance/seedance-2.0",      name: "Seedance 2.0",
                    tagline: "Best output quality, ideal for final renders"),
        ModelOption(id: "xai/grok-imagine-video-1.5",  name: "Grok Imagine 1.5",
                    tagline: "More creative freedom, fewer restrictions — image-to-video with synced audio",
                    requiresImage: true,
                    forcedAudio: true),
        ModelOption(id: "fal-ai/kling-video/v3/standard/image-to-video", name: "Kling 3.0 Standard",
                    tagline: "Cinematic image-to-video with optional native audio",
                    requiresImage: true),
        ModelOption(id: "fal-ai/kling-video/o3/standard/reference-to-video", name: "Kling O3 Reference",
                    tagline: "Character-driven video with native lip-synced dialogue (EN/ZH/JA/KO/ES)",
                    requiresImage: true),
        ModelOption(id: "alibaba/happyhorse-1.1", name: "HappyHorse 1.1",
                    tagline: "Premium video with native audio and multilingual lip-sync",
                    requiresImage: false,
                    forcedAudio: true),
    ]
    static let image: [ModelOption] = [
        ModelOption(id: "openai/gpt-image-2-high",   name: "GPT Image 2 · High",
                    tagline: "Best quality, ideal for final renders"),
        ModelOption(id: "openai/gpt-image-2-medium", name: "GPT Image 2 · Medium",
                    tagline: "Balanced quality and speed"),
        ModelOption(id: "openai/gpt-image-2-low",    name: "GPT Image 2 · Low",
                    tagline: "Fastest and cheapest, best for testing ideas"),
    ]

    static func defaultModel(for mode: String) -> String {
        mode == "AI Image" ? image[0].id : video[0].id
    }

    static func displayName(for modelID: String) -> String {
        (video + image).first(where: { $0.id == modelID })?.name ?? modelID
    }
}

// MARK: - Panel

struct GenerationOptionsPanel: View {
    @Binding var selectedMode: String
    @Binding var selectedModel: String
    @Binding var selectedDuration: Int
    @Binding var selectedResolution: String
    @Binding var selectedAspectRatio: String
    @Binding var audioEnabled: Bool
    @Binding var selectedImageResolution: ImageResolution

    @AppStorage("modelPickerEnabled") private var modelPickerEnabled = true
    @Environment(ThemeManager.self) private var theme

    private var modeIcon: String {
        switch selectedMode {
        case "AI Avatar": return "person.crop.square.fill"
        case "AI Image":  return "photo.fill"
        default:          return "video.fill"
        }
    }

    private var activeModels: [ModelOption] {
        selectedMode == "AI Image" ? ModelCatalog.image : ModelCatalog.video
    }

    private var supportedVideoResolutions: [String] {
        switch selectedModel {
        case "bytedance/seedance-2.0": return ["480p", "720p", "1080p", "4k"]
        case "fal-ai/kling-video/v3/standard/image-to-video": return ["720p"]
        case "fal-ai/kling-video/o3/standard/reference-to-video": return ["720p"]
        case "alibaba/happyhorse-1.1": return ["720p", "1080p"]
        default: return ["480p", "720p"]
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Type
                menuSegment("Type", icon: modeIcon, value: selectedMode) {
                    Picker("Type", selection: $selectedMode) {
                        Text("AI Video").tag("AI Video")
                        Text("AI Image").tag("AI Image")
                        Text("AI Avatar").tag("AI Avatar")
                    }
                }
                .onChange(of: selectedMode) { _, newMode in
                    selectedModel = ModelCatalog.defaultModel(for: newMode)
                }

                // Model — button-based so each item can show a tagline + checkmark
                // Hidden while the "Model Selector" preference is off; locked to the mode's default model.
                if modelPickerEnabled {
                    segmentDivider
                    modelPill
                }

                // Duration — video only
                if selectedMode != "AI Image" {
                    segmentDivider
                    menuSegment("Duration", icon: "clock", value: "\(selectedDuration)s") {
                        Picker("Duration", selection: $selectedDuration) {
                            Text("4 seconds").tag(4)
                            Text("5 seconds").tag(5)
                            Text("6 seconds").tag(6)
                            Text("8 seconds").tag(8)
                            Text("10 seconds").tag(10)
                        }
                    }
                }

                if selectedMode == "AI Image" {
                    // Image mode resolution picker — pixel dimensions, not video resolutions
                    segmentDivider
                    menuSegment("Aspect", icon: "aspectratio", value: selectedImageResolution.displayName) {
                        Picker("Aspect Ratio", selection: $selectedImageResolution) {
                            ForEach(ImageResolution.allCases) { res in
                                Text(res.displayName).tag(res)
                            }
                        }
                    }
                } else {
                    segmentDivider
                    menuSegment("Resolution", icon: "sparkles", value: selectedResolution) {
                        Picker("Resolution", selection: $selectedResolution) {
                            ForEach(supportedVideoResolutions, id: \.self) { resolution in
                                Text(
                                    selectedModel == "fal-ai/kling-video/v3/standard/image-to-video"
                                        ? "Standard"
                                        : (resolution == "4k" ? "4K" : resolution)
                                )
                                .tag(resolution)
                            }
                        }
                    }
                    .onChange(of: selectedModel) { _, newModel in
                        if !supportedVideoResolutions.contains(selectedResolution) { selectedResolution = "720p" }
                        if ModelCatalog.video.first(where: { $0.id == newModel })?.forcedAudio == true {
                            audioEnabled = true
                        }
                    }

                    // Kling's start image defines framing; its Standard i2v schema has no aspect input.
                    if selectedModel != "fal-ai/kling-video/v3/standard/image-to-video" {
                        segmentDivider
                        menuSegment("Aspect Ratio", icon: "aspectratio", value: selectedAspectRatio) {
                            Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                                Text("16:9 · Landscape").tag("16:9")
                                Text("9:16 · TikTok / Reels").tag("9:16")
                                Text("1:1 · Square").tag("1:1")
                                Text("4:3 · Landscape").tag("4:3")
                                Text("3:4 · Portrait").tag("3:4")
                            }
                        }
                    }
                }

                // Audio — video only. Provider-fixed models expose a locked "Always On" pill.
                if selectedMode != "AI Image" {
                    let audioIsFixed = ModelCatalog.video.first { $0.id == selectedModel }?.forcedAudio ?? false
                    segmentDivider
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { audioEnabled.toggle() }
                    } label: {
                        segmentLabel(
                            icon: (audioIsFixed || audioEnabled) ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            value: audioIsFixed ? "Always On" : (audioEnabled ? "On" : "Off"),
                            showChevron: false,
                            isActive: audioIsFixed || audioEnabled
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(audioIsFixed)
                    .opacity(audioIsFixed ? 0.6 : 1.0)
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 14)
        }
        .onChange(of: modelPickerEnabled) { _, enabled in
            if !enabled { selectedModel = ModelCatalog.defaultModel(for: selectedMode) }
        }
        .mask(
            HStack(spacing: 0) {
                // Mirror the trailing edge treatment so the strip fades evenly on both sides.
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
            }
        )
    }

    // MARK: - Model pill (sheet-based so it's scrollable for large catalogs)

    @State private var showModelPicker = false

    private var modelPill: some View {
        Button {
            showModelPicker = true
        } label: {
            segmentLabel(
                icon: "cpu",
                value: ModelCatalog.displayName(for: selectedModel),
                showChevron: true,
                isActive: false
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(models: activeModels, selectedModel: $selectedModel)
                .presentationDetents([.height(modelPickerHeight), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // Height that shows exactly 3 rows (or fewer if catalog is smaller)
    private var modelPickerHeight: CGFloat {
        let rowHeight: CGFloat = 66
        let visibleRows = min(CGFloat(activeModels.count), 3)
        return 52 + visibleRows * rowHeight  // 52 = header + top padding
    }

    // MARK: - Generic menu pill (Picker-based)

    private func menuSegment<Content: View>(
        _ label: String,
        icon: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            Section(label) {
                content()
            }
        } label: {
            segmentLabel(icon: icon, value: value, showChevron: true, isActive: false)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
    }

    // MARK: - Segment label

    private var segmentDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 0.5, height: 36)
    }

    private func segmentLabel(icon: String, value: String, showChevron: Bool, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? AnyShapeStyle(LinearGradient.brandPrimary) : AnyShapeStyle(theme.textSecondary))
                .frame(width: 15, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .contentTransition(.opacity)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 13)
        .padding(.vertical, 9)
        .background {
            if isActive {
                LinearGradient.brandPrimary.opacity(0.14)
            }
        }
    }
}

// MARK: - Model picker sheet

private struct ModelPickerSheet: View {
    let models: [ModelOption]
    @Binding var selectedModel: String
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        VStack(spacing: 0) {
            Text("Model")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(models, id: \.id) { model in
                        Button {
                            selectedModel = model.id
                            dismiss()
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(model.tagline)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                if selectedModel == model.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(accent)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if model.id != models.last?.id {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }
}
