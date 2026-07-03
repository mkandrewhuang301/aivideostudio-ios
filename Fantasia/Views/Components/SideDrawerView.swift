import SwiftUI
import StoreKit

struct SideDrawerView: View {
    @Environment(DrawerManager.self) private var drawer
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(ThemeManager.self) private var theme

    @AppStorage("modelPickerEnabled") private var modelPickerEnabled = true
    @State private var showSignOutConfirm = false
    @State private var isOpeningManageSub = false

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var displayName: String {
        authManager.currentUser?.displayName
            ?? authManager.currentUser?.email?.components(separatedBy: "@").first
            ?? "Account"
    }

    private var initial: String {
        String(displayName.prefix(1)).uppercased()
    }

    private var tierLabel: String {
        switch creditManager.entitlementLevel {
        case .pro:      return "Pro"
        case .basic:    return "Basic"
        case .creator:  return "Creator"
        case .none:     return "Free"
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            theme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 60)
                    .padding(.bottom, 28)
                    .padding(.horizontal, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("PREFERENCES")
                        settingsCard

                        sectionLabel("ACCOUNT")
                            .padding(.top, 8)
                        accountCard

                        signOutButton
                            .padding(.top, 8)

                        footer
                            .padding(.top, 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width < -40 { drawer.close() }
                }
        )
        .alert("Sign out of Fantasia?", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) { try? authManager.signOut() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(accent.opacity(0.35), lineWidth: 1))
                Text(initial)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(tierLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.14), in: Capsule())
            }
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .kerning(0.8)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
    }

    // MARK: - Settings card

    private var settingsCard: some View {
        VStack(spacing: 0) {
            toggleRow(
                icon: "slider.horizontal.3",
                iconColor: accent,
                label: "Model Selector",
                value: $modelPickerEnabled
            )

            rowDivider

            toggleRow(
                icon: theme.isLight ? "sun.max.fill" : "moon.fill",
                iconColor: accent,
                label: "Light Mode",
                value: Binding(
                    get: { theme.isLight },
                    set: { theme.theme = $0 ? .light : .dark }
                )
            )
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Account card

    private var accountCard: some View {
        VStack(spacing: 0) {
            actionRow(icon: "creditcard.fill", iconColor: accent, label: "Manage Subscription", isLoading: isOpeningManageSub) {
                guard !isOpeningManageSub else { return }
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
                isOpeningManageSub = true
                Task {
                    try? await AppStore.showManageSubscriptions(in: scene)
                    isOpeningManageSub = false
                }
            }

            rowDivider

            actionRow(
                icon: "star.fill",
                iconColor: Color(red: 1.0, green: 0.8, blue: 0.15),
                label: "Rate Fantasia"
            ) {
                if let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                    SKStoreReviewController.requestReview(in: scene)
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Sign out

    private var signOutButton: some View {
        Button { showSignOutConfirm = true } label: {
            HStack(spacing: 12) {
                iconContainer(systemName: "rectangle.portrait.and.arrow.right", color: .red.opacity(0.85))
                Text("Sign Out")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Text("Fantasia · v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption2)
                .foregroundStyle(theme.textTertiary)
            HStack(spacing: 16) {
                Link("Privacy", destination: URL(string: "https://fantasiaai.app/privacy")!)
                Link("Terms", destination: URL(string: "https://fantasiaai.app/terms")!)
            }
            .font(.caption2)
            .foregroundStyle(theme.textTertiary)
            .tint(theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Row helpers

    private func toggleRow(
        icon: String,
        iconColor: Color,
        label: String,
        value: Binding<Bool>
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Toggle("", isOn: value)
                .labelsHidden()
                .tint(accent)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func actionRow(icon: String, iconColor: Color, label: String, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconContainer(systemName: icon, color: iconColor)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if isLoading {
                    ProgressView()
                        .tint(theme.textTertiary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private func iconContainer(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: 0.5)
            .padding(.leading, 58)
    }
}
