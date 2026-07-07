// ActivityViewController.swift
// Fantasia
// UIViewControllerRepresentable wrapper for UIActivityViewController.
// Used by GenerationDetailSheet share action (GAL-04, D-29).
// RESEARCH.md Pattern 6 — no existing codebase analog (PATTERNS.md).

import SwiftUI
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Presents `UIActivityViewController` directly via UIKit instead of wrapping it in a SwiftUI
/// `.sheet`. SwiftUI's `.sheet` forces its own presentation-controller sizing (`.large` by
/// default, or a broken/collapsed-to-"More" layout under `.presentationDetents([.medium])`
/// because the activity view controller's internal icon grid doesn't reflow inside an externally
/// constrained height). Presenting it the native UIKit way lets it use its own adaptive sheet
/// sizing — this is the compact, half-screen-ish system share sheet with the full row of
/// Messages/app icons that users expect.
@MainActor
func presentActivityViewController(items: [Any]) {
    guard let scene = UIApplication.shared.connectedScenes
        .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else { return }

    var top = root
    while let presented = top.presentedViewController {
        top = presented
    }

    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
    top.present(activityVC, animated: true)
}

/// UIActivityItemSource wrapping a local file URL for sharing (T19) — gives extensions
/// (Messages, Instagram, TikTok, etc.) an unambiguous file type instead of the empty/generic
/// header UIActivityViewController shows for a bare URL, and supplies rich link metadata
/// (title + thumbnail) for a proper preview card in the share sheet.
final class ShareableMedia: NSObject, UIActivityItemSource {
    let url: URL
    let isVideo: Bool
    let thumbnail: UIImage?

    init(url: URL, isVideo: Bool, thumbnail: UIImage?) {
        self.url = url
        self.isVideo = isVideo
        self.thumbnail = thumbnail
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        isVideo ? UTType.mpeg4Movie.identifier : UTType.jpeg.identifier
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = isVideo ? "Fantasia video" : "Fantasia image"
        metadata.originalURL = url
        if let thumbnail {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
        }
        return metadata
    }
}
