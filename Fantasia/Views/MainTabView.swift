// MainTabView.swift
// Fantasia
// Custom tab bar: 5 tabs (Home, Explore, Generate, Library, Profile).
// Generate is a real tab — tapping the diamond lights it up like any other tab.
// All tabs share the same custom top bar (hamburger + logo + credit ring).

import SwiftUI

struct MainTabView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @State private var selectedTab = 2   // open on Generate by default
    @State private var showProfileSheet = false

    private let tabBarHeight: CGFloat = 74

    var body: some View {
        ZStack(alignment: .bottom) {
            tabContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: tabBarHeight)
                }

            customTabBar
        }
        .ignoresSafeArea(edges: .bottom)
        // D-35: Remix tab switch — FeedView posts .remixGenerationRequested; MainTabView switches to Generate (tab 2)
        .onReceive(NotificationCenter.default.publisher(for: .remixGenerationRequested)) { _ in
            selectedTab = 2
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case 1:  tabPlaceholder("Explore", icon: "magnifyingglass")
        case 2:  NavigationStack { GenerateView(selectedTab: $selectedTab) }
        case 3:  LibraryView()
        case 4:  profileTab
        default: NavigationStack { FeedView() }
        }
    }

    // MARK: - Profile tab

    private var profileTab: some View {
        ZStack {
            Color(red: 0.051, green: 0.047, blue: 0.067).ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0, endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                sharedTopBar
                Spacer()
                Button {
                    try? authManager.signOut()
                } label: {
                    Text("Sign Out")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .padding(.horizontal, 32)
                Spacer()
            }
        }
    }

    // MARK: - Shared top bar (used by all non-Generate tabs)

    private var sharedTopBar: some View {
        HStack(alignment: .center, spacing: 11) {
            Button { } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Fantasia")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .kerning(-0.16)
            }

            Spacer()

            Button { showProfileSheet = true } label: {
                CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 36)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    // MARK: - Generic tab placeholder (Home / Explore / Library / Profile)

    @ViewBuilder
    private func tabPlaceholder(_ title: String, icon: String) -> some View {
        ZStack {
            Color(red: 0.051, green: 0.047, blue: 0.067).ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0, endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                sharedTopBar
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Custom tab bar

    private var customTabBar: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(red: 0.063, green: 0.059, blue: 0.075).opacity(0.9))
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
                .frame(height: tabBarHeight)

            HStack(spacing: 0) {
                tabButton(0, "Feed",    "film.stack")
                tabButton(1, "Explore", "magnifyingglass")
                Color.clear.frame(width: 64)
                tabButton(3, "Library", "square.grid.2x2")
                tabButton(4, "Profile", "person.fill")
            }
            .frame(height: tabBarHeight)

            VStack {
                Spacer()
                Text("Generate")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(selectedTab == 2 ? .white : Color.white.opacity(0.38))
                    .padding(.bottom, 7)
            }
            .frame(height: tabBarHeight)

            HStack {
                Spacer()
                Button { selectedTab = 2 } label: {
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
        .frame(height: tabBarHeight)
    }

    private func tabButton(_ index: Int, _ label: String, _ icon: String) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(selectedTab == index ? .white : Color.white.opacity(0.38))
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
}
