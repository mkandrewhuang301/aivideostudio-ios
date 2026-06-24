// MainTabView.swift
// Fantasia
// Extended in Phase 3: adds CircularCreditIndicator to nav bar trailing position (D-17).
// Tapping presents ProfileCreditSheet (D-18).
// D-17: indicator visible on all main screens.

import SwiftUI

struct MainTabView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @State private var showProfileSheet = false

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView {
            NavigationStack {
                Text("Generate")
                    .foregroundStyle(.secondary)
                    .navigationTitle("Generate")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { creditIndicatorToolbarItem }
            }
            .tabItem {
                Label("Generate", systemImage: "wand.and.stars")
            }

            NavigationStack {
                Text("Gallery")
                    .foregroundStyle(.secondary)
                    .navigationTitle("Gallery")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { creditIndicatorToolbarItem }
            }
            .tabItem {
                Label("Gallery", systemImage: "photo.stack")
            }
        }
        .tint(accent)
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var creditIndicatorToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showProfileSheet = true
            } label: {
                CircularCreditIndicator(
                    fillRatio: creditManager.fillRatio,
                    size: 32
                )
                // Expand touch target to 44×44 per HIG (UI-SPEC accessibility)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .accessibilityLabel("Credits: \(creditManager.creditsBalance) of \(creditManager.subscriptionAllotment + creditManager.activeTopupBalance)")
        }
    }
}

#Preview {
    MainTabView()
        .environment(CreditManager())
        .environment(AuthManager())
}
