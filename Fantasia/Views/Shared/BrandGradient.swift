// BrandGradient.swift
// Fantasia
// The app's primary-action gradient (paperclip/send on the Generate page). Single source of truth
// so Magic Editor + presets match the Generate page exactly (2026-07-11 polish).

import SwiftUI

extension LinearGradient {
    static let brandPrimary = LinearGradient(
        colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                 Color(red: 0.357, green: 0.561, blue: 0.851)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
