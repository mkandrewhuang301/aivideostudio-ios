import SwiftUI

enum AppTheme: String {
    case dark, light
}

// Experimental Light Mode toggle (SideDrawerView, PREFERENCES section). Colors across the
// app are literal RGB values rather than semantic/asset-catalog colors, so views read
// theme-driven semantic properties here instead of `.primary`/`.secondary`, which would
// follow the system appearance rather than this in-app override.
@Observable
final class ThemeManager {
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "appTheme") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "appTheme").flatMap(AppTheme.init(rawValue:))
        theme = saved ?? .dark
    }

    var isLight: Bool { theme == .light }
    var colorScheme: ColorScheme { isLight ? .light : .dark }

    // MARK: - Semantic colors

    /// Page background (Feed, Library, Generate, Drawer).
    var background: Color {
        isLight ? Color(red: 0.925, green: 0.925, blue: 0.937) : Color(red: 0.09, green: 0.085, blue: 0.105)
    }

    /// Slightly lighter background used behind top bars, tab bar, and day-section headers.
    var elevatedBackground: Color {
        isLight ? Color(red: 0.955, green: 0.955, blue: 0.965) : Color(red: 0.13, green: 0.125, blue: 0.15)
    }

    /// Thin accent strip under the custom tab bar / hairline separators.
    var recessedBackground: Color {
        isLight ? Color(red: 0.885, green: 0.885, blue: 0.90) : Color(red: 0.063, green: 0.059, blue: 0.075)
    }

    /// Card/chip fill that sits on top of `background`.
    var surface: Color {
        isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06)
    }

    var surfaceBorder: Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.1)
    }

    /// A more prominent surface for "active"/selected chip states.
    var surfaceStrong: Color {
        isLight ? Color.black.opacity(0.09) : Color.white.opacity(0.12)
    }

    var surfaceStrongBorder: Color {
        isLight ? Color.black.opacity(0.16) : Color.white.opacity(0.25)
    }

    var divider: Color {
        isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.09)
    }

    var textPrimary: Color {
        isLight ? Color(red: 0.08, green: 0.08, blue: 0.1) : .white
    }

    /// Matches the common `.white.opacity(0.5-0.65)` usage for subtitles/body-secondary text.
    var textSecondary: Color {
        isLight ? Color.black.opacity(0.55) : Color.white.opacity(0.6)
    }

    /// Matches the common `.white.opacity(0.3-0.45)` usage for labels/captions/placeholders.
    var textTertiary: Color {
        isLight ? Color.black.opacity(0.35) : Color.white.opacity(0.4)
    }
}
