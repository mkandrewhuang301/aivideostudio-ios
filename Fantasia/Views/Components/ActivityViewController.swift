// ActivityViewController.swift
// Fantasia
// UIViewControllerRepresentable wrapper for UIActivityViewController.
// Used by GenerationDetailSheet share action (GAL-04, D-29).
// RESEARCH.md Pattern 6 — no existing codebase analog (PATTERNS.md).

import SwiftUI
import UIKit

struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
