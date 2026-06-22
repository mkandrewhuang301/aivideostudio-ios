// ContentView.swift
// Fantasia

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager

    var body: some View {
        Group {
            if authManager.isLoading {
                SplashView()
            } else if authManager.currentUser != nil {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: authManager.isLoading)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser == nil)
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}
