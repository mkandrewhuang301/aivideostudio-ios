// TransparentFullScreenBackground.swift
// Fantasia
// Clears the backing UIView's background so a .fullScreenCover can fade through to reveal
// the presenting view underneath, instead of the system's opaque cover-vertical dismiss.

import SwiftUI
import UIKit

struct TransparentFullScreenBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            view.superview?.superview?.backgroundColor = .clear
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
