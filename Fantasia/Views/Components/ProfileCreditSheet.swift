// ProfileCreditSheet.swift
// Fantasia
// Bottom sheet presented on CircularCreditIndicator tap (D-18).
// Shows: username, dot grid (20 dots), Top Up Credits, Manage Subscription (PAY-06), View Profile.

import SwiftUI
import StoreKit

struct ProfileCreditSheet: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @State private var showTopUpSheet = false
    @Binding var isPresented: Bool

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var username: String {
        authManager.currentUser?.displayName
            ?? authManager.currentUser?.email
            ?? "Account"
    }

    private var filledDots: Int {
        Int((creditManager.fillRatio * 20).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 16)
                .padding(.bottom, 16)

            VStack(spacing: 0) {
                // Username row
                HStack {
                    Text(username)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 28)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                VStack(spacing: 8) {
                    // Credits label row
                    HStack {
                        Text("Credits remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(creditManager.creditsBalance)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    // Dot grid (20 dots, 10-column)
                    // UI-SPEC Dot Grid: accessibilityLabel on grid, individual dots hidden
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 10),
                        spacing: 4
                    ) {
                        ForEach(0..<20, id: \.self) { index in
                            Circle()
                                .fill(index < filledDots ? accent : Color.white.opacity(0.12))
                                .frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Credit balance: \(filledDots) of 20 dots filled")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Action buttons
                VStack(spacing: 8) {
                    // Top Up Credits
                    Button {
                        isPresented = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showTopUpSheet = true
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white)
                            Text("Top Up Credits")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(accent, in: RoundedRectangle(cornerRadius: 12))
                    }

                    // Manage Subscription (PAY-06)
                    Button {
                        if let windowScene = UIApplication.shared.connectedScenes
                            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                            Task { try? await AppStore.showManageSubscriptions(in: windowScene) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "creditcard")
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text("Manage Subscription")
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        }
                    }

                    // View Profile (placeholder — Phase 6)
                    Button {
                        isPresented = false
                    } label: {
                        Text("View Profile")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 48)
            }
        }
        .sheet(isPresented: $showTopUpSheet) {
            TopUpSheet()
                .environment(creditManager)
        }
    }
}
