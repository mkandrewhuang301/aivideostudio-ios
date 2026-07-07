// HomeView.swift
// Fantasia
// Registry-driven Home (D-01 replace): one continuous scroll rendering PresetRegistryManager
// rows in the v10-locked section order — Cinema Studio hero, Video Effects, Photo Effects
// (split by output media type, D-02 revision 2026-07-06), Avatar Center (full-width feature
// card), Shows & Vlogs. Every card is a poster-first autoplaying loop (D-08); SOON tiles/pills
// are registry-driven from `status` alone (D-04) — nothing here is hardcoded per-preset.

import SwiftUI

struct HomeView: View {
    @Environment(ThemeManager.self) private var theme
    @State private var registry = PresetRegistryManager()

    var onNavigateToGenerate: () -> Void
    /// Wired by Plan 07/08 to present PresetInputSheet; default no-op lets this plan compile
    /// standalone (D-10 sheet doesn't exist yet in this wave).
    var onSelectPreset: (Preset) -> Void = { _ in }

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    // MARK: - Registry buckets (D-02 order)

    private var heroPreset: Preset? {
        registry.presets.first { $0.section == "hero" }
    }

    /// D-02 revision 2026-07-06: split by output media type — "Video Effects" (produces a
    /// video) rendered above "Photo Effects" (produces a still image).
    private var videoEffectsPresets: [Preset] {
        registry.presets
            .filter { $0.section == "video_effects" }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var photoEffectsPresets: [Preset] {
        registry.presets
            .filter { $0.section == "photo_effects" }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var avatarCenterPreset: Preset? {
        registry.presets.first { $0.section == "avatar_center" }
    }

    private var showsPresets: [Preset] {
        registry.presets
            .filter { $0.section == "shows_vlogs" }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let heroPreset {
                        heroCard(heroPreset)
                    }

                    if !videoEffectsPresets.isEmpty {
                        sectionHeader("Video Effects")
                        effectsGrid(videoEffectsPresets)
                    }

                    if !photoEffectsPresets.isEmpty {
                        sectionHeader("Photo Effects")
                        effectsGrid(photoEffectsPresets)
                    }

                    if let avatarCenterPreset {
                        sectionHeader("Avatar Center")
                        avatarCenterRow(avatarCenterPreset)
                    }

                    if !showsPresets.isEmpty {
                        sectionHeader("Shows & Vlogs")
                        showsRow
                    }
                }
                .padding(.bottom, 110)
            }
        }
        .task { await registry.loadIfNeeded() }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            theme.elevatedBackground.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0,
                endRadius: 340
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Section header (D-05: bold title left, grey "See all" right, uniform everywhere)

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text("See all")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Hero (Cinema Studio)

    private func heroCard(_ preset: Preset) -> some View {
        Color.clear
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay {
                PresetLoopBackground(preset: preset)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                Text("FEATURED")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color(red: 0.91, green: 0.87, blue: 0.99))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    .padding(12)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                            if let subtitle = preset.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        Spacer()
                        if preset.isSoon {
                            Text("Coming Soon")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 0.106, green: 0.086, blue: 0.147))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.92), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 34)
                    .padding(.bottom, 12)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture { if !preset.isSoon { onSelectPreset(preset) } }
    }

    // MARK: - Video Effects / Photo Effects (same 2-col tile grid, different rows)

    private func effectsGrid(_ presets: [Preset]) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(presets) { preset in
                PresetTileView(preset: preset, onTap: onSelectPreset)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Avatar Center (App Store feature-card idiom — text header, ONE full-width row card)

    private func avatarCenterRow(_ preset: Preset) -> some View {
        HStack(spacing: 16) {
            Color.clear
                .frame(width: 84, height: 84)
                .overlay {
                    PresetLoopBackground(preset: preset)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .clipped()

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(theme.textPrimary)
                if let subtitle = preset.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if preset.isSoon {
                Text("SOON")
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if !preset.isSoon { onSelectPreset(preset) } }
    }

    // MARK: - Shows & Vlogs (two half-width cards)

    private var showsRow: some View {
        HStack(spacing: 10) {
            ForEach(showsPresets) { preset in
                showsCard(preset)
            }
        }
        .padding(.horizontal, 12)
    }

    private func showsCard(_ preset: Preset) -> some View {
        Color.clear
            .aspectRatio(16.0 / 12.0, contentMode: .fit)
            .overlay {
                PresetLoopBackground(preset: preset)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                        .frame(height: 46)
                    Text(preset.title.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if preset.isSoon {
                    Text("SOON")
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .saturation(preset.isSoon ? 0.55 : 1)
            .brightness(preset.isSoon ? -0.12 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { if !preset.isSoon { onSelectPreset(preset) } }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HomeView(onNavigateToGenerate: {})
            .environment(ThemeManager())
    }
}
