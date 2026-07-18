// PaywallView.swift
// Fantasia
// Custom paywall screen (D-14: NOT RevenueCat built-in component).
// AUTH-03: Hard gate — no dismiss affordance. Only exits: purchase success or restore success.
// Plan-selection UI is the shared TierPlanSelectorView (Basic/Pro/Creator tabs, fixed 7-row
// checklist, one-press Annual/Monthly purchase) — opens on Pro. Only the onboarding hero/branding
// chrome below is owned by this screen.

import SwiftUI

struct PaywallView: View {
    @Binding var isPresented: Bool

    private let bgColor = Color(red: 0.059, green: 0.059, blue: 0.067) // #0F0F11

    // MARK: — Body

    var body: some View {
        ZStack {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 8) {
                    Text("Fantasia")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Start creating cinematic AI videos.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 8)

                TierPlanSelectorView(isPresented: $isPresented, showAppStoreManage: false)
            }

            // X dismiss button overlay (D-09: top-right, 32pt circle, white.opacity(0.08) background)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .accessibilityLabel("Close")
                    .padding(.trailing, 20)
                }
                Spacer()
            }
            .padding(.top, 16)
        }
    }
}

#Preview {
    PaywallView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
