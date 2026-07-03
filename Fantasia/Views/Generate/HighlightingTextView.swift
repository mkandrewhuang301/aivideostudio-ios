// HighlightingTextView.swift
// Fantasia
// UIViewRepresentable wrapper around UITextView that applies [token] highlighting directly to
// its NSTextStorage. Replaces the old ghost-layer approach (invisible TextField + visible Text
// drawing the highlighted glyphs) in GenerateView's prompt bar — the two layers used different
// text layout engines (UIKit's TextField vs SwiftUI's Text), so long words wrapped at different
// points and the caret drifted mid-word once the layers diverged. Caret and glyphs sharing one
// UITextView makes that class of bug structurally impossible.
//
// Display vs model text: `text` (the binding) stays plain [token]-bracketed text end to end —
// the @-mention logic, rebuildPromptTokens, and dispatch all keep operating on it unchanged.
// Only the UITextView's on-screen attributedText differs: each [token] is collapsed into a
// single NSTextAttachment character (a rendered pill with an optional thumbnail), so a token
// that's N characters in the model is exactly 1 character on screen. displayLocation/
// modelLocation below are the pure offset-mapping functions that translate between the two
// coordinate spaces; every caret/selection read or write has to go through them.

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
    /// Keys are a token's inner text (no brackets), lowercased — see GenerateView's
    /// rebuildTokenThumbnails(). Tokens with no entry render text-only pills.
    var tokenThumbnails: [String: UIImage] = [:]
    /// Fired with a token's inner content (no brackets) when a backspace/delete atomically
    /// removed a whole [token] — see Coordinator.textView(_:shouldChangeTextIn:replacementText:).
    var onTokenDeleted: ((String) -> Void)?

    private static let bracketTokenRegex = try? NSRegularExpression(pattern: #"\[[^\]]+\]"#)
    private static let pillCache = NSCache<NSString, UIImage>()

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
        // Drags that begin inside a tall (scrolling) prompt also track the keyboard down,
        // matching the surrounding history ScrollView's .scrollDismissesKeyboard(.interactively).
        tv.keyboardDismissMode = .interactive
        tv.attributedText = displayAttributedString(from: text)
        tv.typingAttributes = [.font: font, .foregroundColor: textColor]
        context.coordinator.lastAppliedTextColor = textColor
        context.coordinator.lastThumbKeys = Set(tokenThumbnails.keys)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self

        // Compare against the live displayed text's model projection, not a cached flag — a
        // rebuild is needed whenever the SwiftUI-side `text` diverges from what's on screen
        // (programmatic changes: insertToken, rebuildPromptTokens, remix), when the accent/text
        // color changes, or when a token's thumbnail arrives/changes. Ordinary typing never
        // triggers this: textViewDidChange keeps `text` in sync with the displayed text on every
        // keystroke, so the two stay equal and this block is a no-op mid-typing (this is also
        // why re-running full CoreText layout only on genuine divergence — not the live getter —
        // matters here, per the note that used to guard just the color check below).
        let currentModelText = Self.modelText(from: uiView.attributedText)
        let currentThumbKeys = Set(tokenThumbnails.keys)
        let needsRebuild = context.coordinator.lastAppliedTextColor != textColor
            || currentModelText != text
            || context.coordinator.lastThumbKeys != currentThumbKeys

        if needsRebuild {
            context.coordinator.lastAppliedTextColor = textColor
            context.coordinator.lastThumbKeys = currentThumbKeys
            uiView.textColor = textColor

            // Preserve caret position through the rebuild: map the OLD display caret into OLD
            // model coordinates, clamp to the NEW text's length, then map back into NEW display
            // coordinates. Mirrors the old plain-text clamp (`min(range.location, ns.length)`)
            // but through the display<->model projection instead of a direct 1:1 offset.
            let oldTokens = Self.tokenRanges(in: currentModelText)
            let oldModelLoc = Self.modelLocation(forDisplayLocation: uiView.selectedRange.location, tokens: oldTokens)

            uiView.attributedText = displayAttributedString(from: text)

            let newTokens = Self.tokenRanges(in: text)
            let clampedModelLoc = min(oldModelLoc, (text as NSString).length)
            let newDisplayLoc = Self.displayLocation(forModelLocation: clampedModelLoc, tokens: newTokens)
            let ns = uiView.text as NSString
            let clampedDisplayLoc = min(max(newDisplayLoc, 0), ns.length)
            let newRange = NSRange(location: clampedDisplayLoc, length: 0)
            uiView.selectedRange = newRange
            uiView.scrollRangeToVisible(newRange)
            uiView.typingAttributes = [.font: font, .foregroundColor: textColor]
        }

        // Mirrors a caller writing `selectedRange` directly (not currently done anywhere in this
        // app, but kept for parity with the pre-attachment version) — `selectedRange` is in
        // MODEL coordinates (GenerateView's @-mention logic operates on `text` offsets), so it
        // must be projected to DISPLAY coordinates before being applied to the UITextView.
        if let selectedRange {
            let tokens = Self.tokenRanges(in: text)
            let desiredDisplayRange = Self.displayRange(forModelRange: selectedRange, tokens: tokens)
            let ns = uiView.text as NSString
            if desiredDisplayRange != uiView.selectedRange, NSMaxRange(desiredDisplayRange) <= ns.length {
                uiView.selectedRange = desiredDisplayRange
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(fit.height, maxHeight))
    }

    // MARK: - Display attributed string (model text -> pill-rendered display text)

    private func displayAttributedString(from modelText: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ns = modelText as NSString
        var lastEnd = 0
        if let re = Self.bracketTokenRegex {
            for match in re.matches(in: modelText, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > lastEnd {
                    let plain = ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                    result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: textColor]))
                }
                let tokenText = ns.substring(with: match.range)
                let inner = String(tokenText.dropFirst().dropLast())
                let thumb = tokenThumbnails[inner.lowercased()]
                let pillImage = Self.pillImage(inner: inner, thumbnail: thumb, accent: accentColor, font: font)
                let attachment = TokenPillAttachment(tokenText: tokenText, image: pillImage, font: font)
                let attachmentString = NSMutableAttributedString(attachment: attachment)
                attachmentString.addAttribute(.font, value: font, range: NSRange(location: 0, length: attachmentString.length))
                result.append(attachmentString)
                lastEnd = NSMaxRange(match.range)
            }
        }
        if lastEnd < ns.length {
            let plain = ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
            result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: textColor]))
        }
        return result
    }

    /// Reconstructs the plain-text model string from a displayed attributed string — attachment
    /// runs contribute their full bracketed token text, everything else contributes its
    /// characters verbatim.
    static func modelText(from attributed: NSAttributedString?) -> String {
        guard let attributed, attributed.length > 0 else { return "" }
        var result = ""
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            if let pill = value as? TokenPillAttachment {
                result += pill.tokenText
            } else {
                result += (attributed.string as NSString).substring(with: range)
            }
        }
        return result
    }

    /// [token] matches (with brackets) against the MODEL text, in order — the shared input to
    /// every display<->model offset mapping below.
    static func tokenRanges(in modelText: String) -> [NSRange] {
        guard let re = bracketTokenRegex else { return [] }
        let ns = modelText as NSString
        return re.matches(in: modelText, range: NSRange(location: 0, length: ns.length)).map { $0.range }
    }

    // MARK: - Offset mapping (the crux — see file header)
    // Each token contributes tokenText.utf16.count characters in MODEL coordinates but exactly
    // 1 character (its attachment) in DISPLAY coordinates. Both functions are pure and O(tokens).

    static func displayLocation(forModelLocation modelLoc: Int, tokens: [NSRange]) -> Int {
        var runningModel = 0
        var runningDisplay = 0
        for token in tokens {
            if modelLoc <= token.location {
                return runningDisplay + (modelLoc - runningModel)
            }
            if modelLoc < NSMaxRange(token) {
                // Caret conceptually "inside" a token's model text — can't be represented in
                // display coordinates (the token is one atomic character); clamp to just after it.
                return runningDisplay + (token.location - runningModel) + 1
            }
            runningDisplay += (token.location - runningModel) + 1
            runningModel = NSMaxRange(token)
        }
        return runningDisplay + (modelLoc - runningModel)
    }

    static func modelLocation(forDisplayLocation displayLoc: Int, tokens: [NSRange]) -> Int {
        var runningModel = 0
        var runningDisplay = 0
        for token in tokens {
            let gapLen = token.location - runningModel
            if displayLoc <= runningDisplay + gapLen {
                return runningModel + (displayLoc - runningDisplay)
            }
            runningDisplay += gapLen + 1
            runningModel = NSMaxRange(token)
        }
        return runningModel + (displayLoc - runningDisplay)
    }

    static func modelRange(forDisplayRange displayRange: NSRange, tokens: [NSRange]) -> NSRange {
        let start = modelLocation(forDisplayLocation: displayRange.location, tokens: tokens)
        let end = modelLocation(forDisplayLocation: NSMaxRange(displayRange), tokens: tokens)
        return NSRange(location: start, length: max(0, end - start))
    }

    static func displayRange(forModelRange modelRange: NSRange, tokens: [NSRange]) -> NSRange {
        let start = displayLocation(forModelLocation: modelRange.location, tokens: tokens)
        let end = displayLocation(forModelLocation: NSMaxRange(modelRange), tokens: tokens)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Pill rendering

    private static func pillImage(inner: String, thumbnail: UIImage?, accent: UIColor, font: UIFont) -> UIImage {
        let hasThumb = thumbnail != nil
        // Bug fix: the cache key must identify *which* thumbnail, not just whether one is
        // present — otherwise removing a reference and attaching a different image under the
        // same token inner text (e.g. "Image1") returns the stale cached pill. ObjectIdentifier
        // is stable per UIImage instance, and thumbnails come from ThumbnailCache, which returns
        // stable instances per key.
        let thumbId = thumbnail.map { String(UInt(bitPattern: ObjectIdentifier($0))) } ?? "none"
        let cacheKey = "\(inner)|\(thumbId)|\(hexString(accent))" as NSString
        if let cached = pillCache.object(forKey: cacheKey) { return cached }

        let textFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .medium)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: textFont, .foregroundColor: accent]
        let textSize = (inner as NSString).size(withAttributes: textAttrs)

        let height: CGFloat = max(font.lineHeight - 2, 14)
        let thumbSize: CGFloat = hasThumb ? height - 6 : 0
        let spacing: CGFloat = hasThumb ? 3 : 0
        let padding: CGFloat = 4
        let width = padding + thumbSize + spacing + textSize.width + padding

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            let capsuleRect = CGRect(x: 0, y: 0, width: width, height: height)
            accent.withAlphaComponent(0.18).setFill()
            UIBezierPath(roundedRect: capsuleRect, cornerRadius: height / 2).fill()

            var textX = padding
            if hasThumb, let thumbnail {
                let thumbRect = CGRect(x: padding, y: (height - thumbSize) / 2, width: thumbSize, height: thumbSize)
                ctx.cgContext.saveGState()
                UIBezierPath(roundedRect: thumbRect, cornerRadius: 3).addClip()
                let aspect = thumbnail.size.width / max(thumbnail.size.height, 1)
                var drawRect = thumbRect
                if aspect > 1 {
                    drawRect.size.width = thumbRect.height * aspect
                    drawRect.origin.x = thumbRect.midX - drawRect.width / 2
                } else {
                    drawRect.size.height = thumbRect.width / max(aspect, 0.0001)
                    drawRect.origin.y = thumbRect.midY - drawRect.height / 2
                }
                thumbnail.draw(in: drawRect)
                ctx.cgContext.restoreGState()
                textX = thumbRect.maxX + spacing
            }
            let textRect = CGRect(x: textX, y: (height - textSize.height) / 2, width: textSize.width, height: textSize.height)
            (inner as NSString).draw(in: textRect, withAttributes: textAttrs)
        }
        pillCache.setObject(image, forKey: cacheKey)
        return image
    }

    private static func hexString(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
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
        var lastThumbKeys: Set<String> = []
        /// Display-coordinate selection from the previous delegate call — feeds
        /// scrollSelectionIntoView's "which edge moved" heuristic. Deliberately separate from
        /// parent.selectedRange, which is in MODEL coordinates for GenerateView's consumption;
        /// mixing the two coordinate spaces here would scroll to the wrong place whenever a
        /// pill precedes the caret.
        private var lastDisplayRange: NSRange?
        /// Inner tokens whose attachment is about to be removed by the deletion currently in
        /// flight — captured in shouldChangeTextIn, drained at the END of the textViewDidChange
        /// that follows. Ordering matters: GenerateView's onTokenDeleted handler
        /// (dereferenceToken) rewrites `text` to a renumbered [ImageN]/[VideoN] prompt via
        /// rebuildPromptTokens(), and that write must be the LAST one to `parent.text` for this
        /// edit — firing it before textViewDidChange's own `parent.text = modelText(...)` write
        /// would have the un-renumbered value clobber it right back (this is why the old
        /// plain-text version called textViewDidChange(textView) manually BEFORE onTokenDeleted;
        /// deferring here preserves that same ordering with the natural-deletion path).
        private var pendingDeletedTokens: [String] = []

        init(_ parent: HighlightingTextView) {
            self.parent = parent
        }

        // Deletion is atomic "for free" now: each [token] is exactly one attachment character in
        // display coordinates, so a plain backspace/forward-delete on it already removes the
        // whole token in one edit — no manual range-union against the model text needed (unlike
        // the old plain-text version, which had to expand a partial in-token deletion itself).
        // This just detects which attachment(s) are about to be removed; onTokenDeleted itself
        // fires later, from textViewDidChange (see pendingDeletedTokens doc comment).
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard range.length > 0, let attributed = textView.attributedText, attributed.length > 0 else { return true }
            let clamped = NSRange(location: range.location, length: min(range.length, attributed.length - range.location))
            guard clamped.length > 0 else { return true }
            attributed.enumerateAttribute(.attachment, in: clamped, options: []) { value, _, _ in
                if let pill = value as? TokenPillAttachment {
                    pendingDeletedTokens.append(String(pill.tokenText.dropFirst().dropLast()))
                }
            }
            return true
        }

        func textViewDidChange(_ textView: UITextView) {
            // Ordinary typing never re-tokenizes: attachments persist through it untouched, and
            // typingAttributes (reset below) keeps freshly typed/autocorrected characters plain
            // instead of inheriting an adjacent pill's attributes. `text` is kept in sync purely
            // by reading back what's already on screen — no attributedText rewrite here, which is
            // what keeps the caret from ever needing to be reconstructed mid-keystroke.
            let displayCaret = textView.selectedRange
            let modelText = HighlightingTextView.modelText(from: textView.attributedText)
            let tokens = HighlightingTextView.tokenRanges(in: modelText)
            parent.text = modelText
            parent.selectedRange = HighlightingTextView.modelRange(forDisplayRange: displayCaret, tokens: tokens)
            parent.recalcHeight(textView)
            textView.typingAttributes = [.font: parent.font, .foregroundColor: parent.textColor]
            // Once content exceeds maxHeight, re-applying attributedText on every keystroke
            // destroys UITextView's built-in caret-tracking scroll — without this, typing on
            // an early line leaves the view pinned to the last lines. (No longer re-applying
            // attributedText here at all, but scrolling explicitly still matters for parity.)
            textView.scrollRangeToVisible(displayCaret)

            if !pendingDeletedTokens.isEmpty {
                let deleted = pendingDeletedTokens
                pendingDeletedTokens.removeAll()
                for inner in deleted { parent.onTokenDeleted?(inner) }
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let modelText = HighlightingTextView.modelText(from: textView.attributedText)
            let tokens = HighlightingTextView.tokenRanges(in: modelText)
            parent.selectedRange = HighlightingTextView.modelRange(forDisplayRange: textView.selectedRange, tokens: tokens)
            scrollSelectionIntoView(textView, previousRange: lastDisplayRange)
            lastDisplayRange = textView.selectedRange
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        // Follows the moving end of a drag-selection: scrolls to whichever edge just
        // extended so autoscroll tracks the finger both when the selection grows downward
        // (dragging past the bottom of the visible text) and upward. Operates purely in
        // DISPLAY coordinates (see lastDisplayRange doc comment above).
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

// MARK: - TokenPillAttachment

/// Renders a single [token] as one attachment character: a capsule with an optional leading
/// thumbnail and the token's inner text. `tokenText` carries the full bracketed source
/// ("[bob]") so modelText(from:) can reconstruct the plain-text model losslessly.
final class TokenPillAttachment: NSTextAttachment {
    let tokenText: String

    init(tokenText: String, image: UIImage, font: UIFont) {
        self.tokenText = tokenText
        super.init(data: nil, ofType: nil)
        self.image = image
        let height = font.lineHeight - 2
        let width = image.size.width * (height / max(image.size.height, 1))
        // Baseline-relative y-offset (descender-based) keeps the pill vertically centered on the
        // line without growing line height — the same trick UIKit uses for inline image runs.
        self.bounds = CGRect(x: 0, y: font.descender + 1, width: width, height: height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
