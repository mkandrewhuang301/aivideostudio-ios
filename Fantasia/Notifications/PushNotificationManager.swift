// PushNotificationManager.swift
// Fantasia
// Requests native iOS push-notification permission on first sign-in (no custom pre-prompt per
// CONTEXT.md) and forwards the resulting APNs device token to the backend via APIClient.

import SwiftUI
import UserNotifications
import UIKit

@Observable
@MainActor
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    private override init() {
        super.init()
    }

    /// Fires the native iOS permission dialog (no custom pre-prompt per CONTEXT.md), then
    /// registers for remote notifications if granted. Device token capture happens via
    /// AppDelegate-equivalent UIApplicationDelegate callback wired in FantasiaApp — this
    /// method only triggers the OS dialog and the registration call.
    func requestPermissionAndRegister() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                await UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            print("[PushNotificationManager] Authorization request failed: \(error)")
        }
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
    // Called when user taps a notification while the app is in background or killed state.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["generation_id"] != nil {
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
        if notification.request.content.userInfo["generation_id"] != nil {
            NotificationCenter.default.post(name: .generationCompleted, object: nil)
        }
        completionHandler([.banner, .sound])
    }
}
