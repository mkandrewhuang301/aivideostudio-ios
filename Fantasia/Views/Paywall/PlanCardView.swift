// PlanCardView.swift
// Fantasia
// Reusable plan card for PaywallView. Glass morphism per D-13, D-16e.
// Shows: plan name, "Most Popular" badge (optional), monthly price with optional
// strikethrough, billing note, credit quantity, feature bullets, CTA button.

import SwiftUI
import RevenueCat

struct PlanCardView: View {
    let planName: String          // "Basic", "Pro", or "Creator"
    let price: String             // Per-month price, e.g. "$9.99"
    let strikethroughPrice: String? // Monthly price to strike through (annual only), e.g. "$9.99"
    let billingNote: String?      // e.g. "Billed $95.88 annually" or nil for monthly
    let creditsText: String       // e.g. "500 credits/month"
    let features: [String]        // Feature bullet strings
    let ctaLabel: String          // "Get Basic", "Get Pro", or "Get Creator"
    let isMostPopular: Bool       // Shows "Most Popular" badge (Pro only)
    let isPrimary: Bool           // true = accent-filled; false = outlined white border
    let isLoading: Bool
    let isDisabled: Bool
    let onTap: () -> Void

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0) // #8C59FF

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header row: plan name + optional "Most Popular" badge
            HStack {
                Text(planName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if isMostPopular {
                    Text("Most Popular")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(accent, in: RoundedRectangle(cornerRadius: 4))
                }
            }

            // Price block
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Strikethrough monthly price (annual view only)
                    if let strikethrough = strikethroughPrice {
                        Text(strikethrough)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .strikethrough(true, color: .secondary)
                    }
                    // Per-month price (annual equivalent or actual monthly)
                    Text(price)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("/mo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Annual billing note
                if let note = billingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Credit quantity (accent color per UI-SPEC)
            Text(creditsText)
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)

            // Feature bullets
            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(feature)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            // CTA Button
            Button {
                onTap()
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(ctaLabel)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .disabled(isLoading || isDisabled)
            .background(
                Group {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 10).fill(accent)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color.clear)
                    }
                }
            )
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            }
            .accessibilityLabel("\(ctaLabel), \(price) per month")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }
}
