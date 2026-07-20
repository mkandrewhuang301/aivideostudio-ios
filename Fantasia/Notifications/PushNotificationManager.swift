// PushNotificationManager.swift
// Fantasia
// Requests native iOS push-notification permission when the first generation starts and forwards
// the resulting APNs device token to the backend via APIClient.

import SwiftUI
import UserNotifications
import UIKit
import GoogleSignIn

@Observable
@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private override init() {
        super.init()
    }

    /// Requests permission only while the system status is still undetermined, then registers
    /// with APNs if granted. The call is intentionally tied to the first generation action.
    static func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            print("[PushNotificationManager] Authorization request failed: \(error)")
        }
    }

    func requestPermissionAndRegister() async {
        await Self.requestIfNeeded()
    }

    /// Called from the UIApplicationDelegate adaptor's didRegisterForRemoteNotificationsWithDeviceToken.
    /// Converts the raw Data token to a hex string and sends it to the backend.
    func handleDeviceToken(_ tokenData: Data) async {
        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
        do {
            try await APIClient.shared.updateDeviceToken(tokenString)
        } catch {
            print("[PushNotificationManager] Failed to send device token: \(error)")
        }
    }
}

// FantasiaAppDelegate — UIApplicationDelegate adaptor so SwiftUI's @main App can receive
// didRegisterForRemoteNotificationsWithDeviceToken. Wired in FantasiaApp via
// @UIApplicationDelegateAdaptor(FantasiaAppDelegate.self) var appDelegate.
final class FantasiaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Set UNUserNotificationCenter delegate so didReceive and willPresent callbacks fire.
        // RESEARCH.md Pitfall 9: without this assignment, UNUserNotificationCenterDelegate
        // methods are never called even if conformance is declared.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            await PushNotificationManager.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[FantasiaAppDelegate] Failed to register for remote notifications: \(error)")
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}

// MARK: - Orientation lock infrastructure (D-13, D-16)
// RESEARCH.md Pitfall 9: supportedInterfaceOrientationsFor MUST be implemented for
// orientationLock to have any effect — the OS ignores the property without this method.
extension FantasiaAppDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return FantasiaAppDelegate.orientationLock
    }
}

// MARK: - Shared notification name for push-triggered refresh (GEN-10, D-03)
// Posted by UNUserNotificationCenterDelegate; observed by FeedView/LibraryView via
// GenerationManager.refreshOnNotification() — triggers immediate refresh without
// waiting for the 3-second poll tick.
extension Notification.Name {
    static let generationCompleted = Notification.Name("generationCompleted")
}

// MARK: - UNUserNotificationCenterDelegate (GEN-10, D-03: push triggers immediate refresh)
extension FantasiaAppDelegate: UNUserNotificationCenterDelegate {
    // The backend's apnsService sends `payload = { generationId }` (camelCase — see
    // aivideostudio-backend/src/services/apnsService.ts). The original snake_case-only check
    // here never matched a real push, so the refresh trigger silently did nothing. Accept both
    // spellings so a future backend rename can't reintroduce the same silent failure.
    private static func isGenerationPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["generationId"] != nil || userInfo["generation_id"] != nil
    }

    // Called when user taps a notification while the app is in background or killed state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if Self.isGenerationPush(response.notification.request.content.userInfo) {
            NotificationCenter.default.post(name: .generationCompleted, object: nil)
        }
        completionHandler()
    }

    // Called when a notification arrives while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if Self.isGenerationPush(notification.request.content.userInfo) {
            NotificationCenter.default.post(name: .generationCompleted, object: nil)
        }
        completionHandler([.banner, .sound])
    }
}
