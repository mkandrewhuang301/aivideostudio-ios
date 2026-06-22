// FantasiaApp.swift
// Fantasia

import SwiftUI
import FirebaseCore

@main
struct FantasiaApp: App {
    @State private var authManager: AuthManager

    init() {
        // FirebaseApp.configure() MUST run before AuthManager() — Auth.auth() crashes otherwise.
        // Using _authManager = State(initialValue:) ensures this order; the @State default
        // initializer form `= AuthManager()` evaluates before init() body runs.
        FirebaseApp.configure()
        _authManager = State(initialValue: AuthManager())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
        }
    }
}
