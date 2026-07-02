// CreateGenerationView.swift
// Fantasia
// Full-screen modal that opens when the user taps the Generate (Create) action.
// Presented as a fullScreenCover — NOT a tab. Dismiss with the X button or
// (Phase 6) by submitting a prompt, which hands off to a generation-result screen.
//
// Spec: GENERATE_SCREEN_BUILD_SPEC.md — Variant B, Chips
// Key constraint: chips fill the prompt bar only. There is exactly one submit path.

import SwiftUI

struct CreateGenerationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager

    @State private var promptText = ""
    @FocusState private var promptFocused: Bool

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private let suggestions: [(label: String, prompt: String)] = [
        ("A dragon at dusk",    "A dragon gliding through a misty canyon at golden dusk, slow cinematic pan"),
        ("Underwater city",     "An ancient sunken city lit by bioluminescent coral, camera drifting through archways"),
        ("Quiet rainy street",  "A cobblestone street at night, warm lamplight reflecting in puddles, soft rain falling"),
    ]

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom) {
            promptBar
        }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            promptFocused = true
        }
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.051, green: 0.047, blue: 0.067)
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 11) {
            // Hamburger — tapping dismisses the modal on this screen
            Button { dismiss() } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
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

            // Credit ring — reflects actual balance from CreditManager
            CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 36)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Credits")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - Center content (vertically centered between topbar and prompt bar)

    private var centerContent: some View {
        VStack(spacing: 18) {
            // Fantasia logo mark
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)

            // Headline — gray, framed as an offer not an instruction
            Text("Not sure where to start?")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))

            // Chips — one per row, tap fills the prompt bar only
            chipGrid
        }
    }

    private var chipGrid: some View {
        VStack(spacing: 8) {
            ForEach(suggestions, id: \.label) { item in
                chipButton(item)
            }
        }
    }

    private func chipButton(_ item: (label: String, prompt: String)) -> some View {
        Button {
            promptText = item.prompt
            promptFocused = true
        } label: {
            Text(item.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.05))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // Attach — purple gradient circle matching send button
            Button {
                // Phase 6: PhotosPicker
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .medium))
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

            // Input — this is the ONLY submit path on this screen
            TextField("Describe what you want...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(.white)
                .tint(accent)
                .focused($promptFocused)
                .opacity(promptText.isEmpty ? 1 : 1) // ensure text always white
                .keyboardDoneButton()

            // Send — always purple gradient per spec
            Button {
                // Phase 6: validate credits, deduct, dispatch to Replicate, dismiss
                promptFocused = false
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
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 84) // 74pt tab bar + 10pt above diamond top
    }
}

#Preview {
    CreateGenerationView()
        .environment(CreditManager())
        .environment(AuthManager())
        .preferredColorScheme(.dark)
}
