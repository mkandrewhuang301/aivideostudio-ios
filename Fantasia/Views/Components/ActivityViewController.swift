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
