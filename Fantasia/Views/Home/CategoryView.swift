import SwiftUI

struct BrowseCategory {
    let id: String
    let title: String
    let icon: String
    let tint: Color

    static let all: [BrowseCategory] = [
        BrowseCategory(
            id: "formats",
            title: "Formats",
            icon: "sparkles",
            tint: Color(red: 0.55, green: 0.35, blue: 1.0)
        ),
        BrowseCategory(
            id: "shows_vlogs",
            title: "Shows & Vlogs",
            icon: "play.rectangle",
            tint: Color(red: 0.31, green: 0.68, blue: 0.96)
        ),
        BrowseCategory(
            id: "video_effects",
            title: "Video Effects",
            icon: "wand.and.stars",
            tint: Color(red: 0.96, green: 0.39, blue: 0.58)
        ),
        BrowseCategory(
            id: "photo_effects",
            title: "Photo Effects",
            icon: "photo",
            tint: Color(red: 0.22, green: 0.73, blue: 0.67)
        ),
    ]

    static func title(for section: String) -> String {
        all.first { $0.id == section }?.title ?? section.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CategoryView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(FormatRegistryManager.self) private var formatsRegistry
    @State private var presetRegistry = PresetRegistryManager()

    let section: String
    var onSelectPreset: (Preset) -> Void = { _ in }
    var onSelectFormat: (Format) -> Void = { _ in }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var presets: [Preset] {
        presetRegistry.presets
            .filter { $0.section == section }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var formats: [Format] {
        formatsRegistry.formats
            .filter { $0.section == section }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            if section == "formats" {
                LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                    ForEach(formats) { format in
                        FormatCardView(format: format, onTap: onSelectFormat)
                    }
                }
            } else {
                LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
                    ForEach(presets) { preset in
                        PresetTileView(preset: preset, onTap: onSelectPreset)
                    }
                }
            }
        }
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .contentMargins(.top, 12, for: .scrollContent)
        // Category pages are pushed inside MainTabView, whose custom tab bar overlays the
        // NavigationStack. Keep the final row scrollable above that bar instead of trapping it
        // underneath the overlay.
        .contentMargins(.bottom, 110, for: .scrollContent)
        .background(theme.elevatedBackground.ignoresSafeArea())
        .navigationTitle(BrowseCategory.title(for: section))
        .navigationBarTitleDisplayMode(.large)
        .task {
            await presetRegistry.loadIfNeeded()
            await formatsRegistry.loadIfNeeded()
        }
    }
}

/// Shared Formats card used by Home's shelf and the full category page.
struct FormatCardView: View {
    @Environment(ThemeManager.self) private var theme

    let format: Format
    var onTap: (Format) -> Void = { _ in }

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        Button {
            guard format.isLive else { return }
            onTap(format)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(width: 172, height: 124)
                    .overlay {
                        artwork
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        badge
                            .padding(10)
                    }
                    .saturation(format.isLive ? 1 : 0.58)
                    .brightness(format.isLive ? 0 : -0.1)
                    .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(format.title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    if let subtitle = format.subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 148, height: 58, alignment: .leading)
                .padding(.horizontal, 12)
            }
            .frame(width: 172)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(
                RoundedRectangle(cornerRadius: 15)
                    .stroke(theme.surfaceBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(PressableButtonStyle())
        .allowsHitTesting(format.isLive)
        .accessibilityLabel(format.isLive ? format.title : "\(format.title), coming soon")
        .accessibilityHint(format.isLive ? "Opens format options" : "")
    }

    @ViewBuilder
    private var badge: some View {
        if !format.isLive {
            badgeText("SOON", background: AnyShapeStyle(Color.black.opacity(0.42)))
        } else if let badge = format.badge, !badge.isEmpty {
            badgeText(badge, background: AnyShapeStyle(accentGradient))
        }
    }

    private func badgeText(_ text: String, background: AnyShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var artwork: some View {
        if let rawURL = format.tile.posterUrl,
           let url = URL(string: rawURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    artworkFallback
                }
            }
        } else {
            artworkFallback
        }
    }

    private var artworkFallback: some View {
        LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }

    private var palette: [Color] {
        switch format.formatId {
        case "video-explainer":
            [Color(red: 0.18, green: 0.71, blue: 0.82), Color(red: 0.24, green: 0.33, blue: 0.72)]
        case "daily-verse":
            [Color(red: 0.95, green: 0.58, blue: 0.28), Color(red: 0.62, green: 0.29, blue: 0.45)]
        case "spanish-lessons", "language-lessons":
            [Color(red: 0.16, green: 0.68, blue: 0.63), Color(red: 0.18, green: 0.39, blue: 0.72)]
        case "history-reimagined":
            [Color(red: 0.77, green: 0.32, blue: 0.36), Color(red: 0.38, green: 0.24, blue: 0.57)]
        default:
            [accent, Color(red: 0.357, green: 0.561, blue: 0.851)]
        }
    }

    private var symbol: String {
        switch format.formatId {
        case "video-explainer": "text.bubble.fill"
        case "daily-verse": "book.closed.fill"
        case "spanish-lessons", "language-lessons": "character.book.closed.fill"
        case "history-reimagined": "building.columns.fill"
        default: "sparkles"
        }
    }

    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(red: 0.357, green: 0.561, blue: 0.851)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
