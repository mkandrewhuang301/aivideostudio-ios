// SocialSignInButton.swift
// Fantasia
// Reusable social sign-in button supporting Apple and Google providers.
// Used by SignInView (06-03) and reusable for future auth surfaces.
//
// D-06: Apple logo uses renderingMode(.template) + white — real logo (placeholder asset)
// D-07: Google logo uses full-color asset — no template rendering
// D-08: Logo + text left-aligned with padding(.leading, 20)

import SwiftUI

/// Identifies the OAuth provider for a social sign-in button.
enum SocialProvider {
    case apple
    case google

    /// Name of the image asset in Assets.xcassets
    var assetName: String {
        switch self {
        case .apple: return "apple_logo"
        case .google: return "google_logo"
        }
    }

    /// Button label text
    var label: String {
        switch self {
        case .apple: return "Continue with Apple"
        case .google: return "Continue with Google"
        }
    }
}

/// Glass-morphism social sign-in button with real logo mark.
///
/// Styling per UI-SPEC Screen 2 / CONTEXT.md social button tokens:
/// - Background: `Color.white.opacity(0.06)`
/// - Border: `Color.white.opacity(0.1)`, 1pt
/// - Height: 48pt, corner radius: 14pt
/// - Logo: 18×18pt, left-aligned with padding(.leading, 20) per D-08
struct SocialSignInButton: View {
    let provider: SocialProvider
    let action: () -> Void
    var isLoading: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                logoImage
                    .frame(width: 18, height: 18)

                Spacer().frame(width: 8)

                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(provider.label)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                }

                Spacer()
            }
            .padding(.leading, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .disabled(isLoading)
        .accessibilityLabel(provider.label)
    }

    @ViewBuilder
    private var logoImage: some View {
        switch provider {
        case .apple:
            Image(systemName: "apple.logo")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
        case .google:
            Image("google_logo")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
    }
}
