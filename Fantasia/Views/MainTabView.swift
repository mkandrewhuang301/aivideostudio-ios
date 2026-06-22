// MainTabView.swift
// Fantasia

import SwiftUI

struct MainTabView: View {
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    init() {
        // Set tab bar background via UIKit appearance (SwiftUI tab bar tint APIs limited before iOS 18)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.25, alpha: 1.0)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView {
            Text("Generate")
                .foregroundStyle(.secondary)
                .tabItem {
                    Label("Generate", systemImage: "wand.and.stars")
                }

            Text("Gallery")
                .foregroundStyle(.secondary)
                .tabItem {
                    Label("Gallery", systemImage: "photo.stack")
                }
        }
        .tint(accent) // active tab indicator uses accent color
    }
}

#Preview {
    MainTabView()
}
