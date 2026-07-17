import SwiftUI

struct CastView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(CharacterRegistryManager.self) private var registry
    @State private var selectedCharacter: CastCharacter?

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    private var categories: [String] {
        registry.characters.reduce(into: [String]()) { result, character in
            if !result.contains(character.category) {
                result.append(character.category)
            }
        }
    }

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    sectionHeader("My Cast")
                    myCastEmptyState

                    ForEach(categories, id: \.self) { category in
                        let characters = registry.characters
                            .filter { $0.category == category }
                            .sorted { $0.sortOrder < $1.sortOrder }

                        if let title = characters.first?.categoryTitle {
                            sectionHeader(title)
                            characterRow(characters)
                        }
                    }
                }
                .padding(.bottom, 112)
            }
        }
        .task { await registry.loadIfNeeded() }
        .sheet(item: $selectedCharacter) { character in
            CharacterPlaceholderSheet(character: character)
                .environment(theme)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    private var background: some View {
        ZStack {
            theme.elevatedBackground.ignoresSafeArea()
            RadialGradient(
                colors: [accent.opacity(0.14), .clear],
                center: .init(x: 0.9, y: 0),
                startRadius: 0,
                endRadius: 360
            )
            .ignoresSafeArea()
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cast")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text("Meet the characters coming to your stories.")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 3)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }

    private var myCastEmptyState: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.2.badge.plus")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 15))

            VStack(alignment: .leading, spacing: 4) {
                Text("Your cast lives here")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text("Characters are coming soon.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        }
        .padding(.horizontal, 16)
    }

    private func characterRow(_ characters: [CastCharacter]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 11) {
                ForEach(characters) { character in
                    Button { selectedCharacter = character } label: {
                        CharacterCard(character: character)
                            .environment(theme)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(character.name), coming soon")
                    .accessibilityHint("Shows character details")
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct CharacterCard: View {
    @Environment(ThemeManager.self) private var theme
    let character: CastCharacter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CharacterArtView(character: character, cornerRadius: 17)
                .frame(width: 132, height: 168)
                .overlay(alignment: .topTrailing) {
                    if character.isSoon {
                        Text("SOON")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(8)
                    }
                }

            Text(character.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

private struct CharacterArtView: View {
    let character: CastCharacter
    let cornerRadius: CGFloat

    private var colors: [Color] {
        switch character.category {
        case "anime":
            [Color(red: 0.31, green: 0.43, blue: 0.78), Color(red: 0.61, green: 0.38, blue: 0.76)]
        case "3d_generated":
            [Color(red: 0.20, green: 0.57, blue: 0.55), Color(red: 0.28, green: 0.38, blue: 0.72)]
        default:
            [Color(red: 0.60, green: 0.34, blue: 0.66), Color(red: 0.32, green: 0.36, blue: 0.72)]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 112, height: 112)
                .offset(x: 38, y: -45)

            Image(systemName: "person.crop.square.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.white.opacity(0.68))

            AsyncImage(url: character.artURL, transaction: Transaction(animation: .easeInOut)) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .clipped()
    }
}

private struct CharacterPlaceholderSheet: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss
    let character: CastCharacter

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Character preview")
                            .font(.headline)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                                .frame(width: 34, height: 34)
                                .background(theme.surfaceStrong, in: Circle())
                        }
                        .accessibilityLabel("Close")
                    }

                    CharacterArtView(character: character, cornerRadius: 24)
                        .frame(maxWidth: .infinity)
                        .frame(height: 390)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 9) {
                            Text(character.name)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                            Text("COMING SOON")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color(red: 0.545, green: 0.427, blue: 0.839), in: Capsule())
                        }

                        Text(character.bio)
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(red: 0.545, green: 0.427, blue: 0.839))
                            .frame(width: 38, height: 38)
                            .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.textTertiary)
                            Text(character.voiceLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.surfaceBorder, lineWidth: 1)
                    }

                    Text("You’ll be able to add characters to My Cast when their final look and voice are ready.")
                        .font(.footnote)
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding(18)
                .padding(.bottom, 24)
            }
        }
    }
}

#Preview {
    CastView()
        .environment(ThemeManager())
        .environment(CharacterRegistryManager())
}
