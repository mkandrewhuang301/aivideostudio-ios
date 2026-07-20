// AuthManager.swift
// Fantasia

import SwiftUI
import FirebaseAuth
import AuthenticationServices
import GoogleSignIn
import CryptoKit
import UIKit
import RevenueCat

// MARK: - Error Types

enum AuthManagerError: Error, LocalizedError {
    case noPresentingViewController
    case missingGoogleIdToken
    case missingNonce
    case missingAppleIdToken
    case missingAppleAuthorizationCode

    var errorDescription: String? {
        switch self {
        case .noPresentingViewController: return "Could not find a view controller to present sign-in from."
        case .missingGoogleIdToken: return "Google sign-in did not return an ID token."
        case .missingNonce: return "Apple sign-in nonce was missing. Try again."
        case .missingAppleIdToken: return "Apple sign-in did not return an identity token."
        case .missingAppleAuthorizationCode: return "Apple sign-in did not return an authorization code."
        }
    }
}

enum LinkProvider {
    case apple
    case google
}

// MARK: - AuthManager

@Observable
@MainActor
final class AuthManager {
    var currentUser: User?     // FirebaseAuth.User — nil until auth state restores from Keychain
    var isLoading: Bool = true // true until first addStateDidChangeListener callback fires
    var currentNonce: String?  // Stored here (not locally) so it survives to Apple sign-in delegate callback
    var linkError: Error?
    var isLinking: Bool = false

    nonisolated(unsafe) private var listenerHandle: AuthStateDidChangeListenerHandle?
    private var appleLinkCoordinator: AppleSignInCoordinator?

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

    var isAppleLinkedUser: Bool {
        currentUser?.providerData.contains(where: { $0.providerID == "apple.com" }) == true
    }

    func deleteAccount(appleAuthorizationCode: String? = nil) async throws {
        if isAppleLinkedUser {
            guard let appleAuthorizationCode else {
                throw AuthManagerError.missingAppleAuthorizationCode
            }
            do {
                try await Auth.auth().revokeToken(withAuthorizationCode: appleAuthorizationCode)
            } catch {
                // Apple revocation is best-effort. Server-side account/data deletion remains the
                // authoritative privacy action and must not be blocked by an Apple outage.
                print("[AuthManager] Apple token revocation failed: \(error)")
            }
        }

        try await APIClient.shared.deleteAccount()
        try? signOut()

        // Guest-first routing requires an authenticated Firebase user at all times. The deleted
        // UID cannot be reused, so immediately establish a fresh anonymous session instead of
        // leaving ContentView on its nil-user loading state. A launch retry still recovers if the
        // network happens to be unavailable at this exact moment.
        do {
            let replacement = try await Auth.auth().signInAnonymously()
            currentUser = replacement.user
        } catch {
            currentUser = nil
            print("[AuthManager] Account deleted, but replacement guest sign-in failed: \(error)")
        }
    }

    // MARK: - Sign in with Google

    func signInWithGoogle() async throws {
        let credential = try await googleCredential()
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
        let firebaseCredential = try makeAppleCredential(appleCredential, rawNonce: rawNonce)
        _ = try await Auth.auth().signIn(with: firebaseCredential)
        currentNonce = nil
        // listener fires automatically and sets currentUser
    }

    // MARK: - Guest account linking / merging

    /// Links a new provider identity to the active guest, or signs into an existing provider
    /// account and asks the backend to merge the retained anonymous account into it.
    /// The source UID/token are captured before any Firebase link/sign-in changes auth state.
    func linkOrMerge(provider: LinkProvider, creditManager: CreditManager? = nil) async throws {
        guard let anonymousUser = Auth.auth().currentUser,
              anonymousUser.isAnonymous,
              !isLinking else { return }

        isLinking = true
        linkError = nil
        defer { isLinking = false }

        do {
            let anonymousUid = anonymousUser.uid
            let anonymousIdToken = try await anonymousUser.getIDToken(forcingRefresh: true)
            let credential = try await providerCredential(for: provider)

            do {
                let result = try await anonymousUser.link(with: credential)
                await refreshIdentity(result.user, creditManager: creditManager)
            } catch let error as NSError
                where error.domain == AuthErrorDomain
                    && AuthErrorCode(rawValue: error.code) == .credentialAlreadyInUse {
                let mergeCredential: AuthCredential
                if let updatedCredential = error.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential {
                    mergeCredential = updatedCredential
                } else {
                    mergeCredential = try await providerCredential(for: provider)
                }
                let result = try await Auth.auth().signIn(with: mergeCredential)

                do {
                    try await APIClient.shared.mergeAnonymousAccount(
                        anonymousUid: anonymousUid,
                        anonymousIdToken: anonymousIdToken
                    )
                } catch APIError.mergeAlreadyCompleted {
                    // The endpoint is intentionally one-time and idempotent. A replay means the
                    // target already owns the source account's transferable data.
                }

                await refreshIdentity(result.user, creditManager: creditManager)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                linkError = nil
            } else {
                linkError = error
            }
            throw error
        }
    }

    private func refreshIdentity(_ user: User, creditManager: CreditManager?) async {
        currentUser = user
        _ = try? await Purchases.shared.logIn(user.uid)
        await creditManager?.fetchBalance(force: true)
    }

    private func providerCredential(for provider: LinkProvider) async throws -> AuthCredential {
        switch provider {
        case .google:
            return try await googleCredential()
        case .apple:
            return try await appleCredential()
        }
    }

    private func googleCredential() async throws -> AuthCredential {
        guard let rootVC = await Self.rootViewController() else {
            throw AuthManagerError.noPresentingViewController
        }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthManagerError.missingGoogleIdToken
        }
        return GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
    }

    private func appleCredential() async throws -> AuthCredential {
        let rawNonce = generateNonce()
        defer {
            currentNonce = nil
            appleLinkCoordinator = nil
        }

        let coordinator = AppleSignInCoordinator()
        appleLinkCoordinator = coordinator
        let appleCredential = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>) in
            coordinator.onCompletion = { result in
                continuation.resume(with: result)
            }
            coordinator.start(nonce: sha256(rawNonce))
        }
        return try makeAppleCredential(appleCredential, rawNonce: rawNonce)
    }

    private func makeAppleCredential(
        _ appleCredential: ASAuthorizationAppleIDCredential,
        rawNonce: String
    ) throws -> AuthCredential {
        guard let idTokenData = appleCredential.identityToken,
              let idTokenString = String(data: idTokenData, encoding: .utf8) else {
            throw AuthManagerError.missingAppleIdToken
        }
        return OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleCredential.fullName
        )
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
