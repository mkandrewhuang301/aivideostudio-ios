import SwiftUI

struct SideDrawerView: View {
    @Environment(DrawerManager.self) private var drawer
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(FormatRegistryManager.self) private var formatsRegistry
    @Environment(ThemeManager.self) private var theme

    @AppStorage("modelPickerEnabled") private var modelPickerEnabled = true
    @State private var presetRegistry = PresetRegistryManager()
    @State private var showSignOutConfirm = false
    @State private var showManageSubscription = false

    var onSelectBrowseSection: (String) -> Void = { _ in }

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var browseSections: [BrowseCategory] {
        BrowseCategory.all
        .filter { section in
            if section.id == "formats" {
                return formatsRegistry.formats.contains { $0.section == section.id && $0.isLive }
            }
            return presetRegistry.presets.contains { $0.section == section.id && !$0.isSoon }
        }
    }

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
                    .padding(.top, 84)
                    .padding(.bottom, 28)
                    .padding(.horizontal, 22)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !browseSections.isEmpty {
                            sectionLabel("BROWSE")
                            browseCard
                        }

                        sectionLabel("SETTINGS")
                            .padding(.top, 8)
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
        .fullScreenCover(isPresented: $showManageSubscription) {
            ManageSubscriptionView(isPresented: $showManageSubscription)
                .environment(creditManager)
        }
        .task {
            await presetRegistry.loadIfNeeded()
            await formatsRegistry.loadIfNeeded()
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

    private var browseCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(browseSections.enumerated()), id: \.element.id) { index, section in
                if index > 0 { rowDivider }
                actionRow(icon: section.icon, iconColor: section.tint, label: section.title) {
                    drawer.close()
                    onSelectBrowseSection(section.id)
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            appearanceRow
            rowDivider
            toggleRow(
                icon: "slider.horizontal.3",
                iconColor: accent,
                label: "Model Selector",
                value: $modelPickerEnabled
            )
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Appearance row

    /// Variant B's compact two-choice appearance control. Each preview stays inside a 44pt tap
    /// target, while the artwork itself is only 34pt wide so the pair fits the narrowest 65%-wide
    /// drawer without clipping.
    private var appearanceRow: some View {
        HStack(spacing: 6) {
            Text("Appearance")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            appearanceButton(mode: .light, label: "Light")
            appearanceButton(mode: .dark, label: "Dark")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private func appearanceButton(mode: AppTheme, label: String) -> some View {
        let isSelected = theme.theme == mode
        return Button {
            theme.theme = mode
        } label: {
            appearancePreviewSwatch(isLight: mode == .light)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
                        .padding(-2)
                }
                .frame(width: 42, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) appearance")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // Miniature mock "screen" — two text-line bars + an accent dot.
    private func appearancePreviewSwatch(isLight: Bool) -> some View {
        let bg = isLight ? Color.white : Color(red: 0.13, green: 0.13, blue: 0.15)
        let bar = isLight ? Color.black.opacity(0.35) : Color.white.opacity(0.35)
        return RoundedRectangle(cornerRadius: 6)
            .fill(bg)
            .overlay(
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Capsule().fill(bar).frame(width: 14, height: 2)
                            Capsule().fill(bar).frame(width: 10, height: 2)
                        }
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Circle().fill(accent).frame(width: 6, height: 6)
                    }
                }
                .padding(4)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.surfaceBorder, lineWidth: 0.5))
            .frame(width: 34, height: 24)
    }

    // MARK: - Account card

    private var accountCard: some View {
        VStack(spacing: 0) {
            actionRow(icon: "creditcard.fill", iconColor: accent, label: "Manage Subscription") {
                showManageSubscription = true
            }

            rowDivider

            actionRow(
                icon: "star.fill",
                iconColor: Color(red: 1.0, green: 0.8, blue: 0.15),
                label: "Rate Fantasia"
            ) {
                AppReview.requestOrOpenStorePage()
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Sign out

    private var signOutButton: some View {
        Button { showSignOutConfirm = true } label: {
            Text("Sign Out")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Signs out of your Fantasia account")
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
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
            .contentShape(Rectangle())
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
