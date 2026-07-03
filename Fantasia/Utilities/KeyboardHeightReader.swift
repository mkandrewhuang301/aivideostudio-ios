// KeyboardHeightReader.swift
// Fantasia
// Reports the keyboard's live overlap with the window bottom (in points), including during
// interactive scroll-to-dismiss — UIKeyboardLayoutGuide tracks the drag frame-by-frame,
// unlike SwiftUI's keyboard safe-area avoidance (which only animates begin/end).

import SwiftUI
import UIKit

struct KeyboardHeightReader: UIViewRepresentable {
    @Binding var keyboardOverlap: CGFloat

    func makeUIView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onOverlapChange = { overlap in
            if abs(overlap - keyboardOverlap) > 0.1 {
                keyboardOverlap = overlap
            }
        }
        return v
    }

    func updateUIView(_ uiView: TrackerView, context: Context) {}

    final class TrackerView: UIView {
        var onOverlapChange: ((CGFloat) -> Void)?
        private var helper: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            helper?.removeFromSuperview()
            helper = nil
            guard let window else { return }
            let h = HelperView()
            h.isUserInteractionEnabled = false
            h.backgroundColor = .clear
            h.translatesAutoresizingMaskIntoConstraints = false
            h.onHeightChange = { [weak self] height in self?.onOverlapChange?(height) }
            window.addSubview(h)
            NSLayoutConstraint.activate([
                h.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                h.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                h.topAnchor.constraint(equalTo: window.keyboardLayoutGuide.topAnchor),
                h.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            ])
            helper = h
        }

        private final class HelperView: UIView {
            var onHeightChange: ((CGFloat) -> Void)?
            override func layoutSubviews() {
                super.layoutSubviews()
                onHeightChange?(bounds.height)
            }
        }
    }
}
