// AuthManager.swift
// Fantasia

import SwiftUI
import FirebaseAuth
import AuthenticationServices
import GoogleSignIn
import CryptoKit
import UIKit

// MARK: - Error Types

enum AuthManagerError: Error, LocalizedError {
    case noPresentingViewController
    case missingGoogleIdToken
    case missingNonce
    case missingAppleIdToken

    var errorDescription: String? {
        switch self {
        case .noPresentingViewController: return "Could not find a view controller to present sign-in from."
        case .missingGoogleIdToken: return "Google sign-in did not return an ID token."
        case .missingNonce: return "Apple sign-in nonce was missing. Try again."
        case .missingAppleIdToken: return "Apple sign-in did not return an identity token."
        }
    }
}

// MARK: - AuthManager

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

    func deleteAccount() async throws {
        try await Auth.auth().currentUser?.delete()
        // The listener fires automatically and sets currentUser = nil
    }

    // MARK: - Sign in with Google

    func signInWithGoogle() async throws {
        guard let rootVC = await Self.rootViewController() else {
            throw AuthManagerError.noPresentingViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthManagerError.missingGoogleIdToken
        }
        let accessToken = result.user.accessToken.tokenString
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        _ = try await Auth.auth().signIn(with: credential)
        // listener fires automatically and sets currentUser
    }

    // MARK: - Sign in with Apple

    func generateNonce() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return nonce
    }

    func signInWithApple(credential appleCredential: ASAuthorizationAppleIDCredential, rawNonce: String) async throws {
        guard let idTokenData = appleCredential.identityToken,
              let idTokenString = String(data: idTokenData, encoding: .utf8) else {
            throw AuthManagerError.missingAppleIdToken
        }
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleCredential.fullName
        )
        _ = try await Auth.auth().signIn(with: firebaseCredential)
        currentNonce = nil
        // listener fires automatically and sets currentUser
    }

    // MARK: - Helpers

    private static func rootViewController() async -> UIViewController? {
        await MainActor.run {
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)?
                .rootViewController else {
                return nil
            }
            // Walk the presentation chain so Google Sign-In presents from the visible VC.
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            return top
        }
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            precondition(status == errSecSuccess, "Unable to generate nonce")
            for random in randoms where remainingLength > 0 {
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }

    func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
