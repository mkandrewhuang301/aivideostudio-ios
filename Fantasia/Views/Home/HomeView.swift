// HomeView.swift
// Fantasia
// Registry-driven Home (D-01 replace): one continuous scroll rendering PresetRegistryManager
// rows in the section order — Edit Studio hero, Shows & Vlogs (moved up 2026-07-13, first row
// below hero), Video Effects, Photo Effects (split by output media type, D-02 revision
// 2026-07-06), Avatar Center (full-width feature card). Every card is a poster-first autoplaying
// loop (D-08); SOON tiles/pills are registry-driven from `status` alone (D-04) — nothing here is
// hardcoded per-preset.

import SwiftUI

struct HomeView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(FormatRegistryManager.self) private var formatsRegistry
    @State private var registry = PresetRegistryManager()
    @State private var presentedFormat: Format?
    // Phase 13, Plan 09 (D-06): the Studio hub is the ONLY entry point into Edit Studio, opened
    // exclusively from this hero tap — self-contained here (not bubbled up to MainTabView like
    // onSelectPreset) since Studio isn't a generation preset and needs no PresetInputSheet/consent
    // routing.
    @State private var showStudioHub = false
    // App-scoped so Home's project preview and Studio render the same cache-first state. Creating
    // separate stores here and in Studio made both screens paint empty before their `.task`
    // hydration ran, producing the visible red/purple placeholder flash on every entry.
    @Environment(ProjectManager.self) private var heroProjectManager

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

    private var formatsToShow: [Format] {
        formatsRegistry.formats
            .filter { $0.isLive && $0.section == "formats" }
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

                    if !formatsToShow.isEmpty {
                        sectionHeader("Formats")
                        VStack(spacing: 10) {
                            ForEach(formatsToShow) { format in
                                formatRow(format)
                            }
                        }
                    }

                    if !showsPresets.isEmpty {
                        sectionHeader("Shows & Vlogs")
                        showsRow
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
                }
                .padding(.bottom, 110)
            }
        }
        .task {
            await registry.loadIfNeeded()
            await formatsRegistry.loadIfNeeded()
        }
        .task {
            await heroProjectManager.loadProjects()
        }
        // D-06: the Studio hub, opened exclusively from the hero card below.
        .fullScreenCover(isPresented: $showStudioHub) {
            NavigationStack {
                StudioHubView()
            }
            .environment(theme)
        }
        .sheet(item: $presentedFormat) { format in
            ExplainerFormatSheet(format: format)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
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
            .aspectRatio(isEditStudio ? 16.0 / 9.0 : 16.0 / 10.0, contentMode: .fit)
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
                        colors: [.clear, .black.opacity(isEditStudio ? 0.6 : 0.72)],
                        startPoint: .init(x: 0.5, y: isEditStudio ? 0.3 : 0.5),
                        endPoint: .bottom
                    )
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                            if isEditStudio {
                                Text(projects.isEmpty ? "Start your first edit" : "Your projects, ready to finish")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.78))
                            } else if let subtitle = preset.subtitle {
                                Text(subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        Spacer()
                        if isEditStudio {
                            Text("Try It ↗")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.545, green: 0.361, blue: 0.965), Color(red: 1.0, green: 0.302, blue: 0.557)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ),
                                    in: Capsule()
                                )
                                .shadow(color: Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.5), radius: 10)
                        } else if showComingSoon {
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
            .overlay {
                if isEditStudio {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: isEditStudio ? Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.18) : .clear, radius: 20)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isEditStudio {
                    showStudioHub = true
                } else if !preset.isSoon {
                    onSelectPreset(preset)
                }
            }
    }

    /// Sketch 003 winner B: 3 fanned portrait cards — 2 project-preview slots (leftmost rotated
    /// -9°, middle unrotated) + a constant dotted "+" card (rightmost, rotated +9°), matching the
    /// locked percentages (24% card width, left 20/38/56%, top 12/6/12%). Empty state (0 saved
    /// projects) renders a warm/cool color-gradient pair (not gray) — live, not placeholder-dead;
    /// populated state swaps in real project thumbnails as they're created.
    private func heroProjectStack(projects: [ProjectSummary]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cardW = w * 0.24
            let cardH = cardW * 16.0 / 9.0

            ZStack {
                heroThumbSlot(project: projects.count > 0 ? projects[0] : nil, gradient: heroSlotGradient(0))
                    .frame(width: cardW, height: cardH)
                    .rotationEffect(.degrees(-9))
                    .position(x: w * 0.20 + cardW / 2, y: h * 0.12 + cardH / 2)

                heroThumbSlot(project: projects.count > 1 ? projects[1] : nil, gradient: heroSlotGradient(1))
                    .frame(width: cardW, height: cardH)
                    .position(x: w * 0.38 + cardW / 2, y: h * 0.06 + cardH / 2)

                heroPlusSlot
                    .frame(width: cardW, height: cardH)
                    .rotationEffect(.degrees(9))
                    .position(x: w * 0.56 + cardW / 2, y: h * 0.12 + cardH / 2)
            }
        }
        .background(theme.elevatedBackground)
    }

    /// One of the two left-hand stacked cards. `project == nil` (cold start) or a real project
    /// with no thumbnail yet both render `gradient`; a real project WITH a thumbnail renders it.
    /// Exactly one glyph (the play triangle) is ever drawn — never stacked with a second icon,
    /// which is what previously read as a "white box" behind the triangle when a thumbnail-less
    /// project overlapped a film icon with the play icon on top of it.
    /// 13-24 K7: card frame is fixed by the caller (`.frame(width:height:)`); thumbnail center-crops
    /// inside via Color.clear + overlay so a landscape/'original' image cannot influence layout.
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
                    Image(systemName: "play.fill")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .shadow(color: .black.opacity(0.5), radius: 9, x: 0, y: 8)
    }

    /// First slot: warm magenta→orange. Second slot: cool violet→blue. Both drawn from the app's
    /// existing accent family so the cold-start hero reads as "this app", not a generic filler.
    private func heroSlotGradient(_ index: Int) -> LinearGradient {
        let palettes: [[Color]] = [
            [Color(red: 1.0, green: 0.302, blue: 0.557), Color(red: 0.949, green: 0.463, blue: 0.243)],
            [Color(red: 0.545, green: 0.361, blue: 0.965), Color(red: 0.243, green: 0.416, blue: 0.949)],
        ]
        let colors = palettes[index % palettes.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The constant third card — always a "+", never a project. Same fixed dotted-border
    /// affordance as `AddProjectTile` inside the Studio hub itself.
    private var heroPlusSlot: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(red: 0.137, green: 0.137, blue: 0.161))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.4))
            )
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
            )
            .shadow(color: .black.opacity(0.5), radius: 9, x: 0, y: 8)
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

    // MARK: - Formats (server-driven full-width rows below the Edit Studio hero)

    private func formatRow(_ format: Format) -> some View {
        Button {
            presentedFormat = format
        } label: {
            HStack(spacing: 16) {
                Color.clear
                    .frame(width: 84, height: 84)
                    .overlay {
                        formatArtwork(format)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(format.title)
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        if let badge = format.badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 8.5, weight: .heavy))
                                .tracking(0.7)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(explainerAccentGradient, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }

                    if let subtitle = format.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(16)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(format.title), \(format.subtitle ?? "Format")")
        .accessibilityHint("Opens format options")
    }

    @ViewBuilder
    private func formatArtwork(_ format: Format) -> some View {
        if let rawURL = format.tile.posterUrl,
           let url = URL(string: rawURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    formatArtworkFallback
                }
            }
        } else {
            formatArtworkFallback
        }
    }

    private var formatArtworkFallback: some View {
        explainerAccentGradient
            .overlay {
                Image(systemName: "sparkles")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }

    private var explainerAccentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0.357, green: 0.561, blue: 0.851)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
