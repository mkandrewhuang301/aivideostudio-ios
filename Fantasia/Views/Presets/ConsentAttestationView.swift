// ConsentAttestationView.swift
// Fantasia
// SC2: first-use face-input consent hard gate. Presented (fullScreenCover) by MainTabView
// BEFORE a face-input preset's PresetInputSheet ever opens, the very first time a user taps
// a faceswap/motion-transfer preset. Accepting PATCHes /api/me/consent (the server-side record
// of truth — T-09.2-21) and only then hands control back to MainTabView to open the preset
// sheet; declining cancels and the preset never opens.
//
// D-2 reconciliation note: the proactive age-scan was dropped from this phase, so the explicit
// "everyone I upload is 18 or older" line below is now the PRIMARY minor safeguard — it must
// stay prominent and must not be softened or removed.
//
// CRITICAL (CLAUDE.md keyboard/composer freeze): this is a brand-new, standalone modal, like
// PresetInputSheet. It does not import or touch GenerateView / HighlightingTextView /
// KeyboardHeightReader or any keyboard-avoidance/composer code.

import SwiftUI

// Shared purple accent used across the app's primary CTAs — kept as a local literal, consistent
// with PresetInputSheet's own `presetAccent`.
private let consentAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

struct ConsentAttestationView: View {
    @Environment(ThemeManager.self) private var theme

    /// Called when the user taps "I Agree & Continue". The caller (MainTabView) is responsible
    /// for calling APIClient.updateConsent(), persisting the local consent flag, dismissing this
    /// view, and opening the pending preset sheet.
    let onAgree: () async -> Void
    /// Called when the user cancels — the caller dismisses this view without opening any preset.
    let onCancel: () -> Void

    @State private var isAgreeing = false

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "person.crop.rectangle.badge.checkmark")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(consentAccent)
                    .padding(.bottom, 24)

                Text("Before you continue")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.bottom, 14)

                Text("I confirm that everyone whose face I upload is 18 or older and that I have their permission. I will not upload images of minors, public figures, or anyone who has not consented. Uploaded faces are scanned and deleted after processing.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                Spacer()
                Spacer()

                VStack(spacing: 14) {
                    Button {
                        guard !isAgreeing else { return }
                        isAgreeing = true
                        Task {
                            await onAgree()
                            isAgreeing = false
                        }
                    } label: {
                        Group {
                            if isAgreeing {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Text("I Agree & Continue")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .foregroundStyle(.white)
                        .background(consentAccent, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(isAgreeing)

                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAgreeing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

#Preview {
    ConsentAttestationView(onAgree: {}, onCancel: {})
        .environment(ThemeManager())
}
