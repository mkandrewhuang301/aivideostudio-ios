// AppReview.swift
// Fantasia
//
// Shared "Rate the app" action for manually-tapped buttons (Side Drawer, Profile sheet).
//
// `SKStoreReviewController.requestReview` is designed for organic, infrequent in-app
// moments — Apple throttles it internally (roughly 3 displays per 365 days per user)
// with no callback when it's suppressed, so a dedicated "Rate Fantasia" button can
// appear to do nothing most of the time. Apple's own guidance for a manual rate button
// is to deep-link straight to the App Store's write-a-review page instead, which always
// opens reliably and isn't throttled.
//
// TODO: once Fantasia has an App Store Connect listing, set `appStoreID` below to switch
// this to the reliable direct-link behavior. Until then this falls back to the
// system prompt, which is subject to Apple's throttling during testing.

import StoreKit
import UIKit

enum AppReview {
    /// Numeric App Store Connect ID (e.g. "1234567890"). Empty until Fantasia is published.
    private static let appStoreID = ""

    static func requestOrOpenStorePage() {
        guard appStoreID.isEmpty == false,
              let url = URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review") else {
            #if DEBUG
            print("[AppReview] appStoreID not set — using the throttled SKStoreReviewController prompt. Paste the numeric App Store Connect ID into AppReview.appStoreID to enable the reliable direct write-a-review link.")
            #endif
            requestSystemPrompt()
            return
        }
        UIApplication.shared.open(url)
    }

    private static func requestSystemPrompt() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        SKStoreReviewController.requestReview(in: scene)
    }
}
