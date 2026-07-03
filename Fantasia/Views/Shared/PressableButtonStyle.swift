// PressableButtonStyle.swift
// Fantasia
// Shared press feedback (scale + opacity) for capsule/circle action buttons across the
// detail sheet, generation cards, and the composer's options pill.

import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
