// FantasiaApp.swift
// Fantasia

import SwiftUI
import FirebaseCore

@main
struct FantasiaApp: App {
    @State private var authManager = AuthManager()

    init() {
        // FirebaseApp.configure() MUST be in init() — not in body.
        // body can be called multiple times; configure is once-only.
        // configure() reads GoogleService-Info.plist from the app bundle.
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
        }
    }
}
