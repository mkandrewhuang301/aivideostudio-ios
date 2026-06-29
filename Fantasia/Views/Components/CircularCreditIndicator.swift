// CircularCreditIndicator.swift
// Fantasia
// Higgsfield-style circular progress indicator for the navigation bar (D-16, D-17).
// Size: 32pt for nav bar, parameterized for reuse at 28pt in ProfileCreditSheet.
// Color interpolates green (full) → yellow → orange → red (empty) per D-16c.
// fill=0 shows a small red dot at 6 o'clock — zero credits deserves a clear visual signal.

import SwiftUI

struct CircularCreditIndicator: View {
    let fillRatio: Double   // 0.0 (empty/red) to 1.0 (full/green); clamped inside
    let size: CGFloat

    private var clampedRatio: Double { max(0, min(1, fillRatio)) }

    private var ringColor: Color {
        // Piecewise linear per spec: red(0%) → yellow(50%) → green(100%)
        // red:    rgb(224,71,63)   = (0.878, 0.278, 0.247)
        // yellow: rgb(232,177,63)  = (0.910, 0.694, 0.247)
        // green:  rgb(95,191,90)   = (0.373, 0.749, 0.353)
        let t = clampedRatio
        if t <= 0.5 {
            let s = t * 2.0
            return Color(red: 0.878 + (0.910 - 0.878) * s,
                         green: 0.278 + (0.694 - 0.278) * s,
                         blue:  0.247)
        } else {
            let s = (t - 0.5) * 2.0
            return Color(red: 0.910 + (0.373 - 0.910) * s,
                         green: 0.694 + (0.749 - 0.694) * s,
                         blue:  0.247 + (0.353 - 0.247) * s)
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Track ring (background)
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)

            // Progress arc — 0 credits shows red dot at start position
            Circle()
                .trim(from: 0, to: clampedRatio)
                .stroke(ringColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(90)) // 6 o'clock start, clockwise fill
                .animation(
                    reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75),
                    value: clampedRatio
                )

            // Red dot at 6 o'clock when credits are 0
            if clampedRatio < 0.001 {
                Circle()
                    .fill(Color(red: 0.878, green: 0.278, blue: 0.247))
                    .frame(width: 6, height: 6)
                    .offset(y: size / 2)
            }

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
