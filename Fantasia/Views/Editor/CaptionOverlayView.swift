// CaptionOverlayView.swift
// Fantasia
// Phase 13, Plan 16: the live word-level karaoke caption renderer (SC5's render half — plan 15
// built the Captions track's timeline editing; this plan renders what's actually active at
// `state.currentTime`). Reproduces Spike 002's VALIDATED pattern
// (.planning/spikes/002-live-caption-overlay/Sources/CaptionOverlayView.swift) verbatim: ONE
// `Text(AttributedString)` with per-word color runs, `.lineLimit(1)` + `.minimumScaleFactor(0.4)`.
//
// REJECTED ALTERNATIVE (Spike 002's own finding, reproduced here for anyone tempted to "simplify"
// this later): the first spike attempt rendered each word as a separate `Text` in a horizontal
// per-word stack container to get per-word color. That container type never wraps, so longer
// lines overflowed/clipped instead of staying on one line. The follow-up fix (a manual
// `GeometryReader` + `PreferenceKey` width measurement + `.scaleEffect`) was ALSO flawed —
// `.scaleEffect` shrinks drawn pixels without reliably updating what the layout system thinks the
// view's size is, which broke centering and made the background box not match what was visually
// drawn. The real, validated fix is ONE `Text` built from an `AttributedString` with per-run
// color: a normal single `Text` view, so `.lineLimit(1)` + `.minimumScaleFactor()` "just work" the
// same reliable way they do for any other text, and the background naturally hugs whatever that
// `Text` actually renders — no manual measurement. NEVER go back to separate per-word `Text`
// views laid out side by side.
//
// Active-word emphasis is color-only (Spike 002's confirmed on-device fix for a visible-resize
// bug) — see the loop in `displayAttributedString(for:)` below. A font weight change there would
// reproduce that bug; this file never varies weight per word, only the single line-level `.bold`
// applied to the whole `Text`.
//
// Mounted twice: inline in EditorView's preview stage (Delta 6, same canvas frame as
// TextOverlayCanvasView) and again in FullscreenEditorPlayerView (SC6) — both read the SAME
// `EditorState.currentTime` clock, so the two surfaces always agree.

import SwiftUI

struct CaptionOverlayView: View {
    let state: EditorState

    private static let defaultStyle = CaptionStyle(
        fontSize: 22, color: "#FFFFFF", highlightColor: "#8C59FF", position: "bottom"
    )

    private var style: CaptionStyle {
        state.project.captionStyle ?? Self.defaultStyle
    }

    /// The one cue whose [startSeconds, endSeconds) window contains the current playhead — nil
    /// renders nothing (deliberate silent gaps between cues, matching Spike 002's behavior).
    private var activeCue: CaptionCue? {
        state.project.captionCues.first {
            state.currentTime >= $0.startSeconds && state.currentTime < $0.endSeconds
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if style.position == "top" {
                content
                Spacer(minLength: 0)
            } else if style.position == "middle" {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                content
            }
        }
        .padding(.top, style.position == "top" ? 20 : 0)
        .padding(.bottom, style.position == "bottom" ? 20 : 0)
        .animation(.easeOut(duration: 0.12), value: activeCue?.id)
    }

    @ViewBuilder
    private var content: some View {
        if let cue = activeCue, !cue.words.isEmpty {
            karaokeText(for: cue)
        }
    }

    // MARK: - Spike 002's validated pattern, verbatim

    private func karaokeText(for cue: CaptionCue) -> some View {
        captionBackground {
            Text(displayAttributedString(for: cue))
                .font(.system(size: style.fontSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
    }

    private func displayAttributedString(for cue: CaptionCue) -> AttributedString {
        let baseColor = Color(hexString: style.color) ?? .white
        let highlightColor = Color(hexString: style.highlightColor)
            ?? Color(red: 0.55, green: 0.35, blue: 1.0) // #8C59FF fallback

        var result = AttributedString()
        for (index, word) in cue.words.enumerated() {
            var run = AttributedString(word.text)
            let isActive = state.currentTime >= word.startSeconds && state.currentTime < word.endSeconds
            // Color-only emphasis — never varied per word beyond color (see file header).
            run.foregroundColor = isActive ? highlightColor : baseColor
            result += run
            if index < cue.words.count - 1 { result += AttributedString(" ") }
        }
        return result
    }

    private func captionBackground<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
    }
}

// MARK: - Hex color parsing

extension Color {
    /// Parses a "#RRGGBB" (or bare "RRGGBB") hex string — the shape `CaptionStyle.color`/
    /// `highlightColor` are persisted as, and the fixed 6-swatch palette in CaptionStyleSheet is
    /// authored as. Returns nil for malformed input so callers fall back to a known-good default
    /// instead of silently rendering black.
    init?(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
