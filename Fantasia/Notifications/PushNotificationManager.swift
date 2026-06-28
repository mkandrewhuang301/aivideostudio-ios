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
