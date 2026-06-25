// AuthManager.swift
// Fantasia

import SwiftUI
import FirebaseAuth

@Observable
@MainActor
final class AuthManager {
    var currentUser: User?     // FirebaseAuth.User — nil until auth state restores from Keychain
    var isLoading: Bool = true // true until first addStateDidChangeListener callback fires
    var currentNonce: String?  // Stored here (not locally) so it survives to Apple sign-in delegate callback

    nonisolated(unsafe) private var listenerHandle: AuthStateDidChangeListenerHandle?

    // Listener registration deferred to start() — must not call Auth.auth() until
    // FirebaseApp.configure() has run. Keeps init() free of Firebase calls so the
    // object can be created before Firebase is configured, off the app's first-frame path.
    func start() {
        listenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            Task { @MainActor in
                self.currentUser = user
                self.isLoading = false
            }
        }
    }

    deinit {
        if let handle = listenerHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
        // The listener fires automatically and sets currentUser = nil
    }
}
