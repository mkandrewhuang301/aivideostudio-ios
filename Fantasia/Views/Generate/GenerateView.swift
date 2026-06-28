// GenerateView.swift
// Fantasia
// Home tab: custom topbar, vertically-centered inspiration content, bottom prompt bar.
// System nav bar is hidden — this view manages its own header and profile sheet.
// Generation dispatch is wired in Phase 6.

import SwiftUI

struct GenerateView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager

    @State private var promptText = ""
    @State private var showProfileSheet = false
    @FocusState private var promptFocused: Bool

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private let suggestions: [(label: String, icon: String, prompt: String)] = [
        ("Anime girl at dusk",  "sparkles",           "Anime girl standing on a rooftop at golden dusk, wind blowing through her hair"),
        ("Underwater city",    "water.waves",        "An ancient sunken city lit by bioluminescent coral, camera drifting through archways"),
        ("Rainy street",       "cloud.rain.fill",    "A cobblestone street at night, warm lamplight reflecting in puddles, soft rain falling"),
        ("Kung fu battle",     "figure.martial.arts","Kung fu masters fighting on ancient temple steps at sunrise"),
        ("Space station",      "moon.stars.fill",    "Astronaut floating outside a space station, Earth glowing below"),
    ]

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer().frame(height: 278) // push chips up toward screen center
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            promptBar
        }
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.09, green: 0.085, blue: 0.105)
                .ignoresSafeArea()

            RadialGradient(
                colors: [accent.opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0,
                endRadius: 340
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Top bar (hamburger + brand left, credit ring right)

    private var topBar: some View {
        HStack(alignment: .center, spacing: 11) {
            Button { } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            // Brand mark + name
            HStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Fantasia")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .kerning(-0.16)
            }

            Spacer()

            // Credit ring — opens profile / credit sheet
            Button {
                showProfileSheet = true
            } label: {
                CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 36)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    // MARK: - Center inspiration content

    private var centerContent: some View {
        VStack(spacing: 20) {
            Text("What will you create?")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            chipRow
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions, id: \.label) { item in
                    Button {
                        promptText = item.prompt
                        promptFocused = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(accent.opacity(0.9))
                            Text(item.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 48)
            }
        )
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Attach — plain, subordinate to send button
            Button {
                // Phase 6: PhotosPicker
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // Text input — grows up to 5 lines
            TextField("Describe a scene...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(accent)
                .focused($promptFocused)

            // Send — always purple gradient
            Button {
                promptFocused = false
                // Phase 6: dispatch generation
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.545, green: 0.427, blue: 0.839), Color(red: 0.357, green: 0.561, blue: 0.851)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 72) // clear tab bar + diamond raise + comfortable gap
    }
}

#Preview {
    NavigationStack {
        GenerateView()
    }
    .environment(CreditManager())
    .environment(AuthManager())
    .preferredColorScheme(.dark)
}
