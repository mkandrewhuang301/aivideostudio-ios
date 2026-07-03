// ProfileCreditSheet.swift
// Fantasia
// Profile bottom sheet: identity, credits, actions, account management.

import SwiftUI
import StoreKit

struct ProfileCreditSheet: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Binding var isPresented: Bool

    @State private var showCreditStore = false
    @State private var showSignOutConfirm = false
    @State private var isOpeningManageSub = false

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var displayName: String {
        authManager.currentUser?.displayName
            ?? authManager.currentUser?.email?.components(separatedBy: "@").first
            ?? "Account"
    }

    private var tierLabel: String {
        switch creditManager.entitlementLevel {
        case .pro:      return "Pro"
        case .basic:    return "Basic"
        case .creator:  return "Creator"
        case .none:     return "Free"
        }
    }

    private var filledDots: Int {
        Int((creditManager.fillRatio * 22).rounded())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    identityBlock
                    creditsBlock
                    menuSection
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .fullScreenCover(isPresented: $showCreditStore) {
            CreditStoreView(isPresented: $showCreditStore)
                .environment(creditManager)
        }
    }

    // MARK: - Identity

    private var identityBlock: some View {
        HStack(spacing: 14) {
            CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(tierLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Credits

    private var creditsBlock: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Credits")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(creditManager.creditsBalance) remaining")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 22),
                spacing: 0
            ) {
                ForEach(0..<22, id: \.self) { index in
                    Circle()
                        .fill(index < filledDots ? accent : Color.white.opacity(0.1))
                        .frame(height: 6)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Credit balance: \(filledDots) of 22")

            Button {
                showCreditStore = true
            } label: {
                Text("Top Up Credits")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.65, green: 0.45, blue: 1.0),
                                     Color(red: 0.40, green: 0.35, blue: 0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .shadow(color: accent.opacity(0.4), radius: 10, x: 0, y: 4)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    // MARK: - Menu section

    private var menuSection: some View {
        VStack(spacing: 0) {
            // Primary actions card
            VStack(spacing: 0) {
                menuRow(icon: "creditcard.fill", iconColor: accent, label: "Manage Subscription", isLoading: isOpeningManageSub) {
                    guard !isOpeningManageSub else { return }
                    guard let windowScene = UIApplication.shared.connectedScenes
                        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                    isOpeningManageSub = true
                    Task {
                        try? await AppStore.showManageSubscriptions(in: windowScene)
                        isOpeningManageSub = false
                    }
                }

                rowDivider

                menuRow(icon: "star.fill", iconColor: Color(red: 1.0, green: 0.8, blue: 0.15), label: "Rate Fantasia") {
                    if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                        SKStoreReviewController.requestReview(in: scene)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 0.5))

            // Dashed separator
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: geo.size.width, y: 0.5))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 10)

            // Sign out card
            VStack(spacing: 0) {
                Button { showSignOutConfirm = true } label: {
                    HStack(spacing: 12) {
                        iconContainer(systemName: "rectangle.portrait.and.arrow.right", color: .red.opacity(0.9))
                        Text("Sign Out")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                }
                .buttonStyle(.plain)
            }
            .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.15), lineWidth: 0.5))
            .alert("Sign out of Fantasia?", isPresented: $showSignOutConfirm) {
                Button("Sign Out", role: .destructive) { try? authManager.signOut() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Fantasia · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(spacing: 20) {
                Link(destination: URL(string: "https://fantasiaai.app/privacy")!) {
                    Text("Privacy Policy")
                        .underline()
                }
                Link(destination: URL(string: "https://fantasiaai.app/terms")!) {
                    Text("Terms of Service")
                        .underline()
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.white.opacity(0.3))
            .tint(Color.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - Row helpers

    private func menuRow(icon: String, iconColor: Color, label: String, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                iconContainer(systemName: icon, color: iconColor)
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if isLoading {
                    ProgressView()
                        .tint(Color.white.opacity(0.5))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.25))
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func iconContainer(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 42)
    }

}
