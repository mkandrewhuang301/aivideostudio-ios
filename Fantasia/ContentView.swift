// ContentView.swift
// Fantasia

import SwiftUI

struct ContentView: View {
    @Environment(AuthManager.self) private var authManager
    @State private var minSplashElapsed = false

    var body: some View {
        Group {
            if authManager.isLoading || !minSplashElapsed {
                SplashView()
            } else if authManager.currentUser != nil {
                MainTabView()
            } else {
                SignInView()
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: authManager.isLoading || !minSplashElapsed)
        .animation(.easeInOut(duration: 0.35), value: authManager.currentUser == nil)
        .task {
            try? await Task.sleep(for: .seconds(2))
            minSplashElapsed = true
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthManager())
}
