// MainTabView.swift
// Fantasia
// Custom tab bar: Feed (left) + Generate center diamond + Library (right).

import SwiftUI

struct MainTabView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme
    @State private var selectedTab = 1   // open on Generate by default
    @State private var showProfileSheet = false
    @State private var drawer = DrawerManager()

    private let tabBarHeight: CGFloat = 74
    private let bottomLift: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = geo.size.width * 0.65

            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    HomeView(onNavigateToGenerate: { selectedTab = 1 })
                        .safeAreaInset(edge: .top, spacing: 0) { topBar() }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(0)
                    NavigationStack { GenerateView() }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(1)
                    LibraryView()
                        .safeAreaInset(edge: .top, spacing: 0) { topBar(compact: true) }
                        .toolbar(.hidden, for: .tabBar)
                        .tag(2)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: tabBarHeight + bottomLift)
                }

                customTabBar
                    .padding(.bottom, bottomLift)

                // T16: was a plain recessedBackground fill, which reads as a darker band under
                // the (lighter) tab bar — same fill recipe as customTabBar's own background
                // Rectangle so the bar and this under-bar strip read as one continuous surface.
                Rectangle()
                    .fill(theme.recessedBackground.opacity(0.9))
                    .background(.regularMaterial)
                    .frame(height: bottomLift)
                    .ignoresSafeArea(edges: .bottom)
            }
            // Dim overlay
            .overlay {
                Color.black.opacity(drawer.isOpen ? 0.5 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(drawer.isOpen)
                    .onTapGesture { drawer.close() }
                    .animation(.easeInOut(duration: 0.22), value: drawer.isOpen)
            }
            // Side drawer
            .overlay(alignment: .leading) {
                SideDrawerView()
                    .environment(drawer)
                    .environment(creditManager)
                    .environment(authManager)
                    .environment(theme)
                    .frame(width: drawerWidth)
                    .ignoresSafeArea()
                    .offset(x: drawer.isOpen ? 0 : -drawerWidth)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: drawer.isOpen)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(drawer)
        .onReceive(NotificationCenter.default.publisher(for: .remixGenerationRequested)) { _ in
            selectedTab = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .referenceGenerationRequested)) { _ in
            selectedTab = 1
        }
        .nameAsReferenceAlert()
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
                .presentationDetents([.fraction(0.62)])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - Shared top bar (used by all non-Generate tabs)

    // `compact` shrinks the bar for Library only (Home keeps the full-size bar) — Library's
    // date-header grid sits directly under this bar, and at full height it read as an
    // oversized gap above the first date row.
    private func topBar(compact: Bool = false) -> some View {
        let tapSize: CGFloat = compact ? 38 : 44
        let logoSize: CGFloat = compact ? 21 : 26
        let titleFont: CGFloat = compact ? 14 : 16.5
        let creditIndicatorSize: CGFloat = compact ? 26 : 32
        let topPad: CGFloat = compact ? 0 : 2
        let bottomPad: CGFloat = compact ? 4 : 10

        return HStack(alignment: .center, spacing: 11) {
            Button { drawer.open() } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(theme.textPrimary)
                .frame(width: tapSize, height: tapSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                Text("Fantasia")
                    .font(.system(size: titleFont, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .kerning(-0.16)
            }

            Spacer()

            Button { showProfileSheet = true } label: {
                HStack(spacing: 12) {
                    Text(creditManager.totalCreditsPossible > 0
                         ? "\(creditManager.creditsBalance)/\(creditManager.totalCreditsPossible)"
                         : "\(creditManager.creditsBalance)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .contentTransition(.numericText())
                    CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: creditIndicatorSize)
                }
                .frame(height: tapSize)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .background(theme.elevatedBackground.ignoresSafeArea(edges: .top))
    }

    // MARK: - Custom tab bar

    private var customTabBar: some View {
        GeometryReader { geo in
            let third = geo.size.width / 3
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(theme.recessedBackground.opacity(0.9))
                    .background(.regularMaterial)
                    .frame(height: tabBarHeight)

                HStack(spacing: 0) {
                    tabButton(0, "Home", "house").frame(width: third)
                    Color.clear.frame(width: third)
                    tabButton(2, "Library", "square.grid.2x2").frame(width: third)
                }
                .frame(height: tabBarHeight)

                // Dividers at exact 1/3 and 2/3 of the bar width
                HStack(spacing: 0) {
                    Color.clear.frame(width: third)
                    Rectangle()
                        .fill(theme.textTertiary)
                        .frame(width: 0.5, height: 36)
                    Spacer()
                    Rectangle()
                        .fill(theme.textTertiary)
                        .frame(width: 0.5, height: 36)
                    Color.clear.frame(width: third)
                }
                .frame(height: tabBarHeight)

                VStack {
                    Spacer()
                    Text("Generate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selectedTab == 1 ? theme.textPrimary : theme.textTertiary)
                        .padding(.bottom, 7)
                }
                .frame(height: tabBarHeight)

                HStack {
                    Spacer()
                    Button { selectedTab = 1 } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                                             Color(red: 0.416, green: 0.561, blue: 0.878)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .frame(width: 42, height: 42)
                                .overlay(RoundedRectangle(cornerRadius: 13)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1.5))
                                .shadow(color: Color(red: 0.47, green: 0.39, blue: 0.90).opacity(0.45), radius: 8, x: 0, y: 4)
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                                .rotationEffect(.degrees(45))
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .offset(y: -14)
            }
        }
        .frame(height: tabBarHeight)
    }

    private func tabButton(_ index: Int, _ label: String, _ icon: String) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selectedTab == index ? theme.textPrimary : theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: tabBarHeight)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MainTabView()
        .environment(CreditManager())
        .environment(AuthManager())
        .environment(GenerationManager())
        .environment(MediaLibraryManager())
        .environment(ThemeManager())
}
