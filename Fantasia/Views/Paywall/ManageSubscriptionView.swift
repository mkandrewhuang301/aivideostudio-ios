// ManageSubscriptionView.swift
// Fantasia
// Thin host for the shared TierPlanSelectorView in the existing-subscriber (manage) context.
// Fast, custom subscription management screen — replaces jumping straight to Apple's
// native AppStore.showManageSubscriptions() sheet, which is slow (round-trips to the
// App Store) and can prompt Apple ID re-authentication before showing anything.
// The native Apple sheet is only invoked when the user explicitly wants to cancel or
// change their payment method, via TierPlanSelectorView's "Cancel or change plan in the
// App Store" footer link (showAppStoreManage: true).

import SwiftUI

struct ManageSubscriptionView: View {
    @Binding var isPresented: Bool

    private let bgColor = Color(red: 0.059, green: 0.059, blue: 0.067)

    var body: some View {
        ZStack(alignment: .top) {
            bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                TierPlanSelectorView(isPresented: $isPresented, showAppStoreManage: true)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Manage Subscription")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }
}

#Preview {
    ManageSubscriptionView(isPresented: .constant(true))
        .environment(CreditManager())
        .environment(OfferingsManager())
}
