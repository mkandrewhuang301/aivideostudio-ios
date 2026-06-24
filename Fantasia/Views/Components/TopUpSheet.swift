// TopUpSheet.swift
// Fantasia
// IAP consumable top-up purchase sheet (PAY-02).
// D-08: Top-up credits expire 90 days from purchase.
// Loads RevenueCat packages filtered to topup_* product IDs.

import SwiftUI
import RevenueCat

struct TopUpSheet: View {
    @Environment(CreditManager.self) private var creditManager
    @State private var packages: [Package] = []
    @State private var purchaseManager: PurchaseManager?
    @State private var isLoading: Bool = true
    @State private var purchasingId: String? = nil
    @State private var errorId: String? = nil
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 16)
                .padding(.bottom, 16)

            // Header
            HStack {
                Text("Top Up Credits")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 24)

            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            if isLoading {
                // Skeleton loading rows
                VStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        skeletonRow
                    }
                }
                .padding(.horizontal, 24)
            } else if packages.isEmpty {
                // Empty / error state
                VStack(spacing: 16) {
                    Text("Couldn't load top-ups")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Check your connection and try again.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await loadPackages() }
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 44)
                    .padding(.horizontal, 32)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
            } else {
                VStack(spacing: 12) {
                    ForEach(packages, id: \.identifier) { package in
                        topUpPackRow(package)
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()
                .frame(height: 32)
        }
        .task {
            let pm = PurchaseManager(creditManager: creditManager)
            purchaseManager = pm
            await loadPackages()
        }
    }

    // MARK: - Subviews

    private var skeletonRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: 100, height: 14)
                Capsule().fill(Color.white.opacity(0.05)).frame(width: 80, height: 10)
            }
            Spacer()
            Capsule().fill(Color.white.opacity(0.08)).frame(width: 60, height: 28)
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func topUpPackRow(_ package: Package) -> some View {
        let productId = package.storeProduct.productIdentifier
        let displayName = package.storeProduct.localizedTitle
        let price = package.storeProduct.localizedPriceString
        let isPurchasing = purchasingId == productId
        let hadError = errorId == productId

        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Expires in 90 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(price)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await purchase(package) }
                    } label: {
                        Group {
                            if isPurchasing {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Text("Buy Pack")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(minWidth: 60)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(purchasingId != nil)
                }
            }
            .padding(16)

            if hadError {
                Text("Purchase failed. Please try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    // MARK: - Actions

    private func loadPackages() async {
        isLoading = true
        let offerings = try? await Purchases.shared.offerings()
        packages = offerings?.current?.availablePackages
            .filter { $0.storeProduct.productIdentifier.contains("topup") } ?? []
        isLoading = false
    }

    private func purchase(_ package: Package) async {
        guard let pm = purchaseManager else { return }
        let id = package.storeProduct.productIdentifier
        purchasingId = id
        errorId = nil
        await pm.purchase(package: package)
        purchasingId = nil
        if pm.purchaseError != nil {
            errorId = id
        } else {
            // Success: balance updated by PurchaseManager, dismiss sheet
            dismiss()
        }
    }
}
