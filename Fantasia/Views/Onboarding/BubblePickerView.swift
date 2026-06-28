// BubblePickerView.swift
// Fantasia
// 2-column grid bubble picker for the onboarding question flow.
// UI-SPEC Screen 1: staggered spring pop-in, multi-select purple glow, Skip/Continue swap.
// D-01: 2-column LazyVGrid, 16pt corner radius
// D-02: Selected bubble = primary gradient border (2pt) + shadow(purple, radius:10)
// D-03: 50ms stagger delay between bubbles via .animation(...delay(index * 0.05))

import SwiftUI

struct BubblePickerView: View {
    let question: OnboardingQuestion
    let onNext: (Set<String>) -> Void
    let onSkip: () -> Void

    @State private var selectedLabels: Set<String> = []
    @State private var appeared = false

    private let primaryGradient = LinearGradient(
        colors: [Color(red: 0.545, green: 0.427, blue: 0.839), Color(red: 0.357, green: 0.561, blue: 0.851)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    onSkip()
                } label: {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Spacer().frame(height: 24)

            Text(question.prompt)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer().frame(height: 32)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    bubble(for: option, index: index)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            actionButton
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .onAppear { appeared = true }
        .onChange(of: question.id) {
            // Reset state when navigating to a new question (e.g. Q3 -> conditional Q4)
            selectedLabels = []
            appeared = false
            DispatchQueue.main.async { appeared = true }
        }
    }

    private func bubble(for option: OnboardingOption, index: Int) -> some View {
        let isSelected = selectedLabels.contains(option.label)
        return BubbleCell(
            option: option,
            isSelected: isSelected,
            appeared: appeared,
            index: index,
            primaryGradient: primaryGradient
        ) {
            if isSelected {
                selectedLabels.remove(option.label)
            } else {
                selectedLabels.insert(option.label)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if selectedLabels.isEmpty {
            Button {
                onSkip()
            } label: {
                Text("Skip")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
        } else {
            Button {
                onNext(selectedLabels)
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(primaryGradient, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

private struct BubbleCell: View {
    let option: OnboardingOption
    let isSelected: Bool
    let appeared: Bool
    let index: Int
    let primaryGradient: LinearGradient
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            bubbleContent
        }
        .scaleEffect(appeared ? 1.0 : 0.1)
        .opacity(appeared ? 1.0 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.65).delay(Double(index) * 0.05), value: appeared)
    }

    private var bubbleContent: some View {
        VStack(spacing: 8) {
            Image(systemName: option.icon)
                .font(.system(size: 24))
                .foregroundStyle(.white)
            Text(option.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.1, contentMode: .fit)
        .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(bubbleStroke)
        .shadow(color: isSelected ? .purple.opacity(0.5) : .clear, radius: isSelected ? 10 : 0)
    }

    private var bubbleBackground: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(primaryGradient.opacity(0.18))
            : AnyShapeStyle(Color.white.opacity(0.06))
    }

    private var bubbleStroke: some View {
        let strokeStyle: AnyShapeStyle = isSelected
            ? AnyShapeStyle(primaryGradient)
            : AnyShapeStyle(Color.white.opacity(0.1))
        let lineWidth: CGFloat = isSelected ? 2 : 1
        return RoundedRectangle(cornerRadius: 16).stroke(strokeStyle, lineWidth: lineWidth)
    }
}
