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

    init(id: String, name: String, tagline: String, badge: String? = nil) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.badge = badge
    }
}

/// Supported output resolutions for Flux image generation.
enum ImageResolution: String, CaseIterable, Identifiable {
    case small     = "512×512"
    case medium    = "1024×1024"
    case landscape = "1024×768"
    case portrait  = "768×1024"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var width: Int {
        switch self {
        case .small:     return 512
        case .medium:    return 1024
        case .landscape: return 1024
        case .portrait:  return 768
        }
    }
    var height: Int {
        switch self {
        case .small:     return 512
        case .medium:    return 1024
        case .landscape: return 768
        case .portrait:  return 1024
        }
    }
}

enum ModelCatalog {
    static let video: [ModelOption] = [
        ModelOption(id: "bytedance/seedance-2.0-mini", name: "Seedance 2.0 Mini",
                    tagline: "Newest model · 2× faster than Fast at half the cost"),
        ModelOption(id: "bytedance/seedance-2.0-fast", name: "Seedance 2.0 Fast",
                    tagline: "Great quality with faster generation than standard"),
        ModelOption(id: "bytedance/seedance-2.0",      name: "Seedance 2.0",
                    tagline: "Highest quality, cinematic motion"),
    ]
    static let image: [ModelOption] = [
        ModelOption(id: "bytedance/seedream-5-lite", name: "Seedream 5 Lite",
                    tagline: "Fast, high-quality images", badge: "4 credits"),
        ModelOption(id: "bytedance/seedream-4.5",    name: "Seedream 4.5",
                    tagline: "Cinematic aesthetics, strong detail", badge: "4 credits"),
        ModelOption(id: "openai/gpt-image-2",        name: "GPT Image 2",
                    tagline: "Precise instruction-following, photorealistic", badge: "13 credits"),
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

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Type
                menuPill("Type", icon: modeIcon, value: selectedMode) {
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
                modelPill

                // Duration — video only
                if selectedMode != "AI Image" {
                    menuPill("Duration", icon: "clock", value: "\(selectedDuration)s") {
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
                    menuPill("Resolution", icon: "sparkles", value: selectedImageResolution.displayName) {
                        Picker("Resolution", selection: $selectedImageResolution) {
                            ForEach(ImageResolution.allCases) { res in
                                Text(res.displayName).tag(res)
                            }
                        }
                    }
                } else {
                    menuPill("Resolution", icon: "sparkles", value: selectedResolution) {
                        Picker("Resolution", selection: $selectedResolution) {
                            Text("480p").tag("480p")
                            Text("720p").tag("720p")
                            if selectedModel == "bytedance/seedance-2.0" {
                                Text("1080p").tag("1080p")
                                Text("4K").tag("4k")
                            }
                        }
                    }
                    .onChange(of: selectedModel) { _, newModel in
                        let supported = ["bytedance/seedance-2.0": ["480p", "720p", "1080p", "4k"]]
                        let validForModel = supported[newModel] ?? ["480p", "720p"]
                        if !validForModel.contains(selectedResolution) { selectedResolution = "720p" }
                    }

                    menuPill("Aspect Ratio", icon: "aspectratio", value: selectedAspectRatio) {
                        Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                            Text("16:9 · Landscape").tag("16:9")
                            Text("9:16 · Portrait").tag("9:16")
                            Text("1:1 · Square").tag("1:1")
                            Text("4:3").tag("4:3")
                        }
                    }
                }

                // Audio — video only
                if selectedMode != "AI Image" {
                    VStack(spacing: 4) {
                        Text("AUDIO")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.35))
                            .kerning(0.4)
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { audioEnabled.toggle() }
                        } label: {
                            pillLabel(
                                icon: audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                value: audioEnabled ? "On" : "Off",
                                showChevron: false,
                                isActive: audioEnabled
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 36)
            }
        )
    }

    // MARK: - Model pill (Button-based menu so taglines are visible)

    private var modelPill: some View {
        VStack(spacing: 4) {
            Text("MODEL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.4)
            Menu {
                Section("Model") {
                    ForEach(activeModels, id: \.id) { model in
                        Button {
                            selectedModel = model.id
                        } label: {
                            if selectedModel == model.id {
                                Label {
                                    Text(model.name)
                                    Text(model.tagline)
                                    if let badge = model.badge {
                                        Text(badge)
                                    }
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(model.name)
                                Text(model.tagline)
                                if let badge = model.badge {
                                    Text(badge)
                                }
                            }
                        }
                    }
                }
            } label: {
                pillLabel(
                    icon: "cpu",
                    value: ModelCatalog.displayName(for: selectedModel),
                    showChevron: true,
                    isActive: false
                )
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Generic menu pill (Picker-based)

    private func menuPill<Content: View>(
        _ label: String,
        icon: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .kerning(0.4)
            Menu {
                Section(label) {
                    content()
                }
            } label: {
                pillLabel(icon: icon, value: value, showChevron: true, isActive: false)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Pill label

    private func pillLabel(icon: String, value: String, showChevron: Bool, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? accent : .white.opacity(0.55))
                .frame(width: 15, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.opacity)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? accent.opacity(0.16) : Color.white.opacity(0.07))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(isActive ? accent.opacity(0.45) : Color.white.opacity(0.18), lineWidth: 1))
    }
}
