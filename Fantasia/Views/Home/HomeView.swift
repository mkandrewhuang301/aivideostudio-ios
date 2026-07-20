// HomeView.swift
// Fantasia
// Registry-driven Home (D-01 replace): one continuous scroll rendering PresetRegistryManager
// rows in the section order — Edit Studio hero, recent presets, Formats, Shows & Vlogs, Video
// Effects, then Photo Effects. Registry status remains the sole source for SOON treatment.

import SwiftUI

struct HomeView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(FormatRegistryManager.self) private var formatsRegistry
    @Environment(GenerationManager.self) private var generationManager
    @State private var registry = PresetRegistryManager()
    // App-scoped so Home's project preview and Studio render the same cache-first state. Creating
    // separate stores here and in Studio made both screens paint empty before their `.task`
    // hydration ran, producing the visible red/purple placeholder flash on every entry.
    @Environment(ProjectManager.self) private var heroProjectManager
    @State private var selectedHomeSection = "top"

    var onNavigateToGenerate: () -> Void
    /// The Edit Studio hero selects MainTabView's existing Studio tab instead of presenting a
    /// second copy of the hub over the tab hierarchy.
    var onNavigateToStudio: () -> Void = {}
    /// Wired by Plan 07/08 to present PresetInputSheet; default no-op lets this plan compile
    /// standalone (D-10 sheet doesn't exist yet in this wave).
    var onSelectPreset: (Preset) -> Void = { _ in }
    var onSelectCategory: (String) -> Void = { _ in }
    var onSelectFormat: (Format) -> Void = { _ in }

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    private struct HomeSectionChip: Identifiable {
        let id: String
        let label: String
    }

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

    private var showsPresets: [Preset] {
        registry.presets
            .filter { $0.section == "shows_vlogs" }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var formatsToShow: [Format] {
        formatsRegistry.formats
            .filter { $0.section == "formats" }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// The top destination is always present. Registry-backed destinations only appear when the
    /// matching section has at least one live item, so a chip can never jump to a SOON-only shelf.
    private var homeSectionChips: [HomeSectionChip] {
        var chips = [HomeSectionChip(id: "top", label: "For You")]
        if formatsToShow.contains(where: \.isLive) {
            chips.append(HomeSectionChip(id: "formats", label: "Formats"))
        }
        if showsPresets.contains(where: { $0.status == "live" }) {
            chips.append(HomeSectionChip(id: "shows_vlogs", label: "Shows"))
        }
        if videoEffectsPresets.contains(where: { $0.status == "live" }) {
            chips.append(HomeSectionChip(id: "video_effects", label: "Video FX"))
        }
        if photoEffectsPresets.contains(where: { $0.status == "live" }) {
            chips.append(HomeSectionChip(id: "photo_effects", label: "Photo FX"))
        }
        return chips
    }

    /// Most recent distinct preset runs from the existing app-wide generation snapshot. Freeform
    /// rows and registry misses are skipped; no second backend feed or local preference is needed.
    private var recentPresets: [Preset] {
        let presetsById = Dictionary(uniqueKeysWithValues: registry.presets.map { ($0.presetId, $0) })
        var seen = Set<String>()
        var result: [Preset] = []

        for generation in generationManager.feedGenerations {
            guard let presetId = generation.params.presetId,
                  seen.insert(presetId).inserted,
                  let preset = presetsById[presetId],
                  !preset.isSoon else { continue }
            result.append(preset)
            if result.count == 6 { break }
        }

        return result.count >= 2 ? result : []
    }

    var body: some View {
        ZStack {
            background

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("top")

                        if let heroPreset {
                            heroCard(heroPreset)
                        }

                        if !recentPresets.isEmpty {
                            sectionHeader("Jump back in")
                            jumpBackInRow
                        }

                        if !formatsToShow.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader("Formats", section: "formats")
                                formatsRow
                            }
                            .id("formats")
                        }

                        if !showsPresets.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader("Shows & Vlogs", section: "shows_vlogs")
                                showsRow
                            }
                            .id("shows_vlogs")
                        }

                        if !videoEffectsPresets.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader("Video Effects", section: "video_effects")
                                effectsRow(videoEffectsPresets)
                            }
                            .id("video_effects")
                        }

                        if !photoEffectsPresets.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                sectionHeader("Photo Effects", section: "photo_effects")
                                effectsRow(photoEffectsPresets)
                            }
                            .id("photo_effects")
                        }
                    }
                    .padding(.bottom, 110)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    homeSectionChipStrip(proxy: proxy)
                }
            }
        }
        .task {
            await registry.loadIfNeeded()
            await formatsRegistry.loadIfNeeded()
        }
        .task {
            await heroProjectManager.loadProjects()
        }
    }

    // MARK: - Sticky section navigation

    private func homeSectionChipStrip(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(homeSectionChips) { chip in
                    let isSelected = selectedHomeSection == chip.id
                    Button {
                        selectedHomeSection = chip.id
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(chip.id, anchor: .top)
                        }
                    } label: {
                        Text(chip.label)
                            .font(.system(size: 12, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? accent : theme.surface,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(isSelected ? Color.clear : theme.surfaceBorder, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint("Scrolls to \(chip.label)")
                }
            }
            .padding(.horizontal, 12)
        }
        .background(theme.elevatedBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 0.5)
        }
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

    private func sectionHeader(_ title: String, section: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            if let section {
                Button {
                    onSelectCategory(section)
                } label: {
                    Text("See all ›")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all \(title)")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Hero (Edit Studio — D-06: the ONLY entry point into the Studio hub)

    /// Phase 13: the "edit-studio" hero row's card renders sketch 003's locked winner (variant
    /// B — stacked project thumbnails), not a generic `PresetLoopBackground` loop. Every other
    /// hero-section preset (none currently exist, but the registry could add one) falls back to
    /// the original loop+Coming-Soon treatment untouched.
    private func heroCard(_ preset: Preset) -> some View {
        let isEditStudio = preset.presetId == "edit-studio"
        let showComingSoon = preset.isSoon && !isEditStudio
        let projects = heroProjectManager.projects

        return Color.clear
            .aspectRatio(isEditStudio ? 3.15 : 16.0 / 10.0, contentMode: .fit)
            .overlay {
                if isEditStudio {
                    heroProjectStack(projects: projects)
                        .allowsHitTesting(false)
                } else {
                    PresetLoopBackground(preset: preset)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: isEditStudio ? [.clear, .clear] : [.clear, .black.opacity(0.72)],
                        startPoint: .init(x: 0.5, y: 0.5),
                        endPoint: .bottom
                    )
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(isEditStudio ? Color(red: 0.13, green: 0.11, blue: 0.20) : .white)
                            if isEditStudio {
                                Text("Trim, text, sound — your editor")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color(red: 0.13, green: 0.11, blue: 0.20).opacity(0.52))
                            } else if let subtitle = preset.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        Spacer()
                        if isEditStudio {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(red: 0.13, green: 0.11, blue: 0.20).opacity(0.38))
                                .padding(.bottom, 2)
                        } else if showComingSoon {
                            Text("Coming Soon")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(red: 0.106, green: 0.086, blue: 0.147))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.92), in: Capsule())
                        }
                    }
                    .padding(.horizontal, isEditStudio ? 17 : 14)
                    .padding(.top, 34)
                    .padding(.bottom, isEditStudio ? 14 : 12)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()
            .overlay {
                if isEditStudio {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color(red: 0.13, green: 0.11, blue: 0.20).opacity(0.10), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isEditStudio ? .black.opacity(0.08) : .clear, radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditStudio {
                    onNavigateToStudio()
                } else if !preset.isSoon {
                    onSelectPreset(preset)
                }
            }
    }

    /// Two project previews followed by a constant gray add card. The medium-size trio stays in
    /// the upper-right, clear of the title and subtitle inside the extra-compact hero.
    private func heroProjectStack(projects: [ProjectSummary]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cardW = w * 0.15
            let cardH = cardW * 1.35

            ZStack {
                heroThumbSlot(project: projects.count > 0 ? projects[0] : nil, gradient: heroSlotGradient(0))
                    .frame(width: cardW, height: cardH)
                    .position(x: w * 0.50 + cardW / 2, y: h * 0.06 + cardH / 2)

                heroThumbSlot(project: projects.count > 1 ? projects[1] : nil, gradient: heroSlotGradient(1))
                    .frame(width: cardW, height: cardH)
                    .position(x: w * 0.66 + cardW / 2, y: h * 0.06 + cardH / 2)

                heroAddSlot
                    .frame(width: cardW, height: cardH)
                    .position(x: w * 0.82 + cardW / 2, y: h * 0.06 + cardH / 2)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.965, green: 0.949, blue: 0.995),
                    Color(red: 0.915, green: 0.890, blue: 0.970),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    /// One compact preview card. A missing project or thumbnail renders `gradient`; a real cover
    /// center-crops inside the fixed caller-provided frame so source aspect ratio cannot alter layout.
    private func heroThumbSlot(project: ProjectSummary?, gradient: LinearGradient) -> some View {
        Color.clear
            .overlay {
                ZStack {
                    if let project, let urlString = project.thumbnailUrl, let url = URL(string: urlString) {
                        LetterboxThumbnailView(
                            url: url,
                            cacheKey: "project-cover-\(project.id)-\(url.lastPathComponent)"
                        ) {
                            gradient
                        }
                    } else {
                        gradient
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(red: 0.13, green: 0.11, blue: 0.20).opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, y: 3)
    }

    /// Constant add-project treatment for the third slot.
    private var heroAddSlot: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(red: 0.34, green: 0.34, blue: 0.38))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.white.opacity(0.62),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [1, 4])
                    )
            )
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 3)
    }

    /// Empty-state colors mirror the compact studio-card artwork: purple, then blue.
    private func heroSlotGradient(_ index: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 0.52, green: 0.36, blue: 0.78), Color(red: 0.24, green: 0.17, blue: 0.39)],
            [Color(red: 0.31, green: 0.58, blue: 0.83), Color(red: 0.12, green: 0.28, blue: 0.48)],
        ]
        let colors = palettes[index % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Video Effects / Photo Effects (single horizontal shelf per section)

    private func effectsRow(_ presets: [Preset]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(presets) { preset in
                    PresetTileView(preset: preset, onTap: onSelectPreset)
                        .frame(width: 148)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Jump back in (small, familiar recent-preset shelf)

    private var jumpBackInRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(recentPresets) { preset in
                    Button {
                        onSelectPreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            recentPresetArtwork(preset)
                                .frame(width: 76, height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.surfaceBorder, lineWidth: 1)
                                )

                            Text(preset.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                                .frame(width: 76, alignment: .leading)
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Use \(preset.title) again")
                }
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func recentPresetArtwork(_ preset: Preset) -> some View {
        if let url = preset.tile.posterURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    recentPresetFallback
                }
            }
        } else {
            recentPresetFallback
        }
    }

    private var recentPresetFallback: some View {
        LinearGradient(
            colors: [theme.surfaceStrong, accent.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Formats (server-driven marquee cards)

    private var formatsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(formatsToShow) { format in
                    FormatCardView(format: format, onTap: onSelectFormat)
                }
            }
            .padding(.horizontal, 12)
        }
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
