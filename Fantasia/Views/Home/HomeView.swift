// HomeView.swift
// Fantasia
// Discovery home — featured model banner, quick-create cards, style preset grid, recent videos.
// Placeholder gradients fill in for real video thumbnails until content is available.

import SwiftUI
import AVFoundation

struct HomeView: View {
    @Environment(CreditManager.self) private var creditManager

    var onNavigateToGenerate: () -> Void

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    quickCreateSection
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    featuredStylesSection
                        .padding(.top, 28)

                }
                .padding(.bottom, 110)
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.13, green: 0.125, blue: 0.15).ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0,
                endRadius: 340
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        ZStack(alignment: .bottomLeading) {
            // Placeholder gradient — replace with video thumbnail when available
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.22, green: 0.14, blue: 0.48),
                            Color(red: 0.10, green: 0.07, blue: 0.28),
                            Color.black
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .frame(height: 240)
                .overlay(heroBannerDecoration)

            // Bottom gradient fade so text is legible
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )
                .frame(height: 240)

            heroTextContent
        }
    }

    private var heroBannerDecoration: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.30))
                .frame(width: 200, height: 200)
                .blur(radius: 50)
                .offset(x: 80, y: -40)

            Circle()
                .fill(Color(red: 0.30, green: 0.55, blue: 0.90).opacity(0.18))
                .frame(width: 140, height: 140)
                .blur(radius: 40)
                .offset(x: 100, y: 40)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.white.opacity(0.10))
                .offset(x: 80, y: 0)
        }
    }

    private var heroTextContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // "NEW MODEL" pill
            Text("SEEDANCE 2.0 FAST")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.65))
                .tracking(1.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12), in: Capsule())

            Text("CREATE\nCINEMATIC\nAI VIDEOS")
                .font(.system(size: 28, weight: .black))
                .foregroundStyle(.white)
                .lineSpacing(1)

            Text("Hollywood-grade video from your imagination")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.60))

            Button(action: onNavigateToGenerate) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start Creating")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(20)
    }

    // MARK: - Quick Create

    private var quickCreateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("CRAFT YOUR NEXT VIDEO", action: nil)

            HStack(spacing: 12) {
                quickCreateCard(
                    title: "Text to Video",
                    subtitle: "Describe your vision",
                    icon: "text.alignleft",
                    colors: [Color(red: 0.35, green: 0.22, blue: 0.72), Color(red: 0.18, green: 0.12, blue: 0.40)]
                )
                quickCreateCard(
                    title: "Image to Video",
                    subtitle: "Bring a photo to life",
                    icon: "photo.on.rectangle.angled",
                    colors: [Color(red: 0.18, green: 0.28, blue: 0.70), Color(red: 0.10, green: 0.16, blue: 0.40)]
                )
            }
        }
    }

    private func quickCreateCard(title: String, subtitle: String, icon: String, colors: [Color]) -> some View {
        Button(action: onNavigateToGenerate) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 118)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: icon)
                            .font(.system(size: 38))
                            .foregroundStyle(Color.white.opacity(0.12))
                            .padding(14)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.60))
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Featured Styles

    private struct StylePreset: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let badge: String?
        let colors: [Color]
        let icon: String
    }

    private let stylePresets: [StylePreset] = [
        StylePreset(
            title: "Cinematic",
            subtitle: "Hollywood-grade footage",
            badge: "NEW",
            colors: [Color(red: 0.30, green: 0.16, blue: 0.65), Color(red: 0.10, green: 0.07, blue: 0.30)],
            icon: "film.stack"
        ),
        StylePreset(
            title: "Portrait",
            subtitle: "Character-focused",
            badge: nil,
            colors: [Color(red: 0.60, green: 0.20, blue: 0.28), Color(red: 0.28, green: 0.10, blue: 0.14)],
            icon: "person.crop.rectangle"
        ),
        StylePreset(
            title: "Nature",
            subtitle: "Landscapes & environments",
            badge: nil,
            colors: [Color(red: 0.12, green: 0.42, blue: 0.32), Color(red: 0.06, green: 0.20, blue: 0.16)],
            icon: "leaf.fill"
        ),
        StylePreset(
            title: "Urban",
            subtitle: "City & street scenes",
            badge: "HOT",
            colors: [Color(red: 0.52, green: 0.36, blue: 0.08), Color(red: 0.26, green: 0.18, blue: 0.04)],
            icon: "building.2.fill"
        ),
        StylePreset(
            title: "Abstract",
            subtitle: "Surreal dreamlike visuals",
            badge: nil,
            colors: [Color(red: 0.52, green: 0.12, blue: 0.52), Color(red: 0.26, green: 0.06, blue: 0.26)],
            icon: "circle.hexagongrid.fill"
        ),
        StylePreset(
            title: "Action",
            subtitle: "Dynamic motion sequences",
            badge: nil,
            colors: [Color(red: 0.62, green: 0.22, blue: 0.08), Color(red: 0.30, green: 0.10, blue: 0.04)],
            icon: "bolt.fill"
        ),
    ]

    private var featuredStylesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("FEATURED STYLES", action: {})
                .padding(.horizontal, 16)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                ForEach(stylePresets) { preset in
                    stylePresetCard(preset)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func stylePresetCard(_ preset: StylePreset) -> some View {
        Button(action: onNavigateToGenerate) {
            ZStack(alignment: .bottomLeading) {
                // Gradient placeholder (swap for real thumbnail later)
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: preset.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .aspectRatio(0.80, contentMode: .fit)
                    .overlay(
                        Image(systemName: preset.icon)
                            .font(.system(size: 42))
                            .foregroundStyle(Color.white.opacity(0.10))
                    )

                // Bottom text fade
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // Title + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.60))
                        .lineLimit(1)
                }
                .padding(12)

                // Badge
                if let badge = preset.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.72, green: 0.98, blue: 0.32), in: Capsule())
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String, action: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
                .tracking(1.6)
            Spacer()
            if let action {
                Button(action: action) {
                    Text("See all")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}


#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        HomeView(onNavigateToGenerate: {})
            .environment(GenerationManager())
            .environment(CreditManager())
    }
}
