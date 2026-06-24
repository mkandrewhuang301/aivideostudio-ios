// CircularCreditIndicator.swift
// Fantasia
// Higgsfield-style circular progress indicator for the navigation bar (D-16, D-17).
// Size: 32pt for nav bar, parameterized for reuse at 28pt in ProfileCreditSheet.
// Color interpolates green (full) → yellow → orange → red (empty) per D-16c.
// fill=0 shows a complete red ring — zero credits deserves a clear visual signal.

import SwiftUI

struct CircularCreditIndicator: View {
    let fillRatio: Double   // 0.0 (empty/red) to 1.0 (full/green); clamped inside
    let size: CGFloat

    private var clampedRatio: Double { max(0, min(1, fillRatio)) }

    private var ringColor: Color {
        switch clampedRatio {
        case 0.75...: return Color(red: 0.2,  green: 0.85, blue: 0.4)
        case 0.50...: return Color(red: 0.7,  green: 0.85, blue: 0.2)
        case 0.25...: return Color(red: 1.0,  green: 0.65, blue: 0.0)
        default:      return Color(red: 1.0,  green: 0.35, blue: 0.0)
        }
    }

    // When fill == 0, show a complete red ring instead of no ring
    private var effectiveTrim: Double {
        clampedRatio == 0 ? 1.0 : clampedRatio
    }

    private var effectiveColor: Color {
        clampedRatio == 0 ? Color(red: 0.95, green: 0.15, blue: 0.15) : ringColor
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Track ring (background)
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)

            // Progress arc
            Circle()
                .trim(from: 0, to: effectiveTrim)
                .stroke(effectiveColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(
                    reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
                    value: clampedRatio
                )

            // Profile picture placeholder (Phase 6: replace with AsyncImage)
            Circle()
                .fill(Color(red: 0.15, green: 0.15, blue: 0.25))
                .frame(width: size - 8, height: size - 8)

            // Person icon placeholder
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.35))
                .foregroundStyle(Color.secondary)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 24) {
        CircularCreditIndicator(fillRatio: 1.0, size: 44)
        CircularCreditIndicator(fillRatio: 0.6, size: 44)
        CircularCreditIndicator(fillRatio: 0.3, size: 44)
        CircularCreditIndicator(fillRatio: 0.0, size: 44)
    }
    .padding()
    .background(Color(red: 0.10, green: 0.10, blue: 0.18))
}
