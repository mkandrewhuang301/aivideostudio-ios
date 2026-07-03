// GlassTextField.swift
// Fantasia
// Reusable glass-morphism text field supporting plain text and secure (eye-toggle) modes.
// Used by SignInView (06-03) and SignUpView (06-04).

import SwiftUI

/// A glass-morphism styled text field with optional secure mode.
///
/// Styling per UI-SPEC Screen 2 design tokens:
/// - Background: `Color.white.opacity(0.06)`
/// - Border: `Color.white.opacity(0.12)`, 1pt
/// - Height: 52pt, corner radius: 14pt
/// - Text: `.white.opacity(0.9)`, placeholder: `.white.opacity(0.3)`
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var isFocused: FocusState<Bool>.Binding

    @State private var showSecureText = false

    var body: some View {
        HStack(spacing: 0) {
            inputField
                .padding(.leading, 16)
                .padding(.trailing, isSecure ? 0 : 16)

            if isSecure {
                eyeToggleButton
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var inputField: some View {
        let promptText = Text(placeholder).foregroundStyle(Color.white.opacity(0.3))

        if isSecure && !showSecureText {
            SecureField(text: $text, prompt: promptText) {
                EmptyView()
            }
            .textContentType(textContentType)
            .font(.body)
            .foregroundStyle(Color.white.opacity(0.9))
            .focused(isFocused)
        } else {
            TextField(text: $text, prompt: promptText) {
                EmptyView()
            }
            .keyboardType(keyboardType)
            .textContentType(textContentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body)
            .foregroundStyle(Color.white.opacity(0.9))
            .focused(isFocused)
        }
    }

    private var eyeToggleButton: some View {
        Button {
            if !UIAccessibility.isReduceMotionEnabled {
                withAnimation { showSecureText.toggle() }
            } else {
                showSecureText.toggle()
            }
        } label: {
            Image(systemName: showSecureText ? "eye.slash.fill" : "eye.fill")
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(showSecureText ? "Hide password" : "Show password")
    }
}
