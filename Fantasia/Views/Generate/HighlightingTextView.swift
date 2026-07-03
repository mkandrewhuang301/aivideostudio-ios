// HighlightingTextView.swift
// Fantasia
// UIViewRepresentable wrapper around UITextView that applies [token] highlighting directly to
// its NSTextStorage. Replaces the old ghost-layer approach (invisible TextField + visible Text
// drawing the highlighted glyphs) in GenerateView's prompt bar — the two layers used different
// text layout engines (UIKit's TextField vs SwiftUI's Text), so long words wrapped at different
// points and the caret drifted mid-word once the layers diverged. Caret and glyphs sharing one
// UITextView makes that class of bug structurally impossible.

import SwiftUI
import UIKit

struct HighlightingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    @Binding var isFocused: Bool
    @Binding var contentHeight: CGFloat

    var accentColor: UIColor
    var textColor: UIColor = .white
    var maxHeight: CGFloat = 112
    var font: UIFont = .preferredFont(forTextStyle: .body)
    /// Fired with a token's inner content (no brackets) when a backspace/delete atomically
    /// removed a whole [token] — see Coordinator.textView(_:shouldChangeTextIn:replacementText:).
    var onTokenDeleted: ((String) -> Void)?

    private static let bracketTokenRegex = try? NSRegularExpression(pattern: #"\[[^\]]+\]"#)

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.font = font
        tv.textColor = textColor
        tv.tintColor = accentColor
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byWordWrapping
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .sentences
        tv.showsVerticalScrollIndicator = false
        applyHighlighting(to: tv, text: text)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Compare against the Coordinator's own record of what we last applied, not
        // uiView.textColor read back from UIKit: applyHighlighting sets attributedText with a
        // per-character .foregroundColor attribute, and UITextView's textColor getter doesn't
        // reliably echo back a value that's `==` the concrete UIColor we set once attributedText
        // is in play. Comparing against the live getter made this condition true on literally
        // every SwiftUI re-render, re-running full CoreText layout each time — the main thread
        // hang report ("screen froze") traced directly back to this loop.
        if context.coordinator.lastAppliedTextColor != textColor {
            context.coordinator.lastAppliedTextColor = textColor
            uiView.textColor = textColor
            applyHighlighting(to: uiView, text: text)
        }
        if uiView.text != text {
            let range = uiView.selectedRange
            applyHighlighting(to: uiView, text: text)
            // Preserve caret position through a programmatic text write (e.g. inserting an
            // [ImageN] token) rather than resetting it to the end.
            let ns = uiView.text as NSString
            let clamped = NSRange(location: min(range.location, ns.length), length: 0)
            uiView.selectedRange = clamped
            uiView.scrollRangeToVisible(clamped)
        }
        if let selectedRange, selectedRange != uiView.selectedRange {
            let ns = uiView.text as NSString
            if selectedRange.location + selectedRange.length <= ns.length {
                uiView.selectedRange = selectedRange
            }
        }
        if isFocused, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        recalcHeight(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func applyHighlighting(to tv: UITextView, text: String) {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: textColor]
        )
        if let re = Self.bracketTokenRegex {
            let ns = text as NSString
            for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                attributed.addAttribute(.foregroundColor, value: accentColor, range: match.range)
                attributed.addAttribute(.backgroundColor, value: accentColor.withAlphaComponent(0.18), range: match.range)
            }
        }
        tv.attributedText = attributed
    }

    private func recalcHeight(_ tv: UITextView) {
        let width = tv.bounds.width > 0 ? tv.bounds.width : UIScreen.main.bounds.width
        let fitSize = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let capped = min(fitSize.height, maxHeight)
        let shouldScroll = fitSize.height > maxHeight
        if tv.isScrollEnabled != shouldScroll { tv.isScrollEnabled = shouldScroll }
        if abs(contentHeight - capped) > 0.5 {
            DispatchQueue.main.async { contentHeight = capped }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: HighlightingTextView
        var lastAppliedTextColor: UIColor?

        init(_ parent: HighlightingTextView) {
            self.parent = parent
        }

        // Atomic token deletion, done here rather than via the SwiftUI text round trip: a
        // backspace that lands inside [bob] used to delete one char, bounce through
        // parent.text -> onChange(of:) -> a rewrite of the whole token -> back into
        // updateUIView, which resets attributedText and restores the caret to the *old*
        // character offset (never adjusted for the characters removed before it) — the caret
        // landed visually inside a later word. Deleting the whole token directly against
        // textStorage means only one write happens, so the caret we set is the caret that stays.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text.isEmpty else { return true }
            guard let re = HighlightingTextView.bracketTokenRegex else { return true }
            let ns = textView.text as NSString
            let matches = re.matches(in: textView.text, range: NSRange(location: 0, length: ns.length))
            guard let tokenMatch = matches.first(where: {
                NSMaxRange($0.range) > range.location && $0.range.location < NSMaxRange(range)
            }) else { return true }

            // Union the token's range with the proposed deletion range — covers a plain
            // backspace at "]", a forward-delete at "[", and a selection that clips into the
            // token from either side.
            var removeRange = NSUnionRange(tokenMatch.range, range)

            // Eat one flanking space to avoid double-spaces: prefer the leading space, else
            // the trailing one.
            if removeRange.location > 0, ns.character(at: removeRange.location - 1) == 32 {
                removeRange.location -= 1
                removeRange.length += 1
            } else if NSMaxRange(removeRange) < ns.length, ns.character(at: NSMaxRange(removeRange)) == 32 {
                removeRange.length += 1
            }

            let tokenText = ns.substring(with: tokenMatch.range)
            let inner = String(tokenText.dropFirst().dropLast())

            textView.textStorage.replaceCharacters(in: removeRange, with: "")
            textView.selectedRange = NSRange(location: removeRange.location, length: 0)
            textViewDidChange(textView)
            parent.onTokenDeleted?(inner)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            // Re-apply attributes by mutating textStorage-backed attributedText, never by
            // resetting `text` from the SwiftUI side — that path is what preserves the caret.
            let caret = textView.selectedRange
            parent.applyHighlighting(to: textView, text: textView.text)
            textView.selectedRange = caret
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
            parent.recalcHeight(textView)
            // Once content exceeds maxHeight, re-applying attributedText on every keystroke
            // destroys UITextView's built-in caret-tracking scroll — without this, typing on
            // an early line leaves the view pinned to the last lines.
            textView.scrollRangeToVisible(caret)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let previous = parent.selectedRange
            parent.selectedRange = textView.selectedRange
            scrollSelectionIntoView(textView, previousRange: previous)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        // Follows the moving end of a drag-selection: scrolls to whichever edge just
        // extended so autoscroll tracks the finger both when the selection grows downward
        // (dragging past the bottom of the visible text) and upward.
        private func scrollSelectionIntoView(_ textView: UITextView, previousRange: NSRange?) {
            let current = textView.selectedRange
            guard let previous = previousRange, current.length > 0 else {
                textView.scrollRangeToVisible(current)
                return
            }
            let previousEnd = previous.location + previous.length
            let currentEnd = current.location + current.length
            if current.location < previous.location {
                textView.scrollRangeToVisible(NSRange(location: current.location, length: 0))
            } else if currentEnd > previousEnd {
                textView.scrollRangeToVisible(NSRange(location: currentEnd, length: 0))
            } else {
                textView.scrollRangeToVisible(current)
            }
        }
    }
}
