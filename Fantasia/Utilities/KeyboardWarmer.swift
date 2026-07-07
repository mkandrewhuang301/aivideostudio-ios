// KeyboardWarmer.swift
// Fantasia

import UIKit

/// Pre-loads the iOS keyboard subsystem once per process so the FIRST real tap on a text
/// field doesn't pay the ~100–500ms cold-start hitch. Uses a throwaway offscreen UITextField
/// on a hidden UIWindow: becomeFirstResponder forces UIKit to build the keyboard machinery,
/// then we immediately resign and tear the window down. Nothing is ever visible.
///
/// NOT related to the Generate composer's keyboard positioning (that is frozen — see
/// .planning/notes/keyboard-composer-architecture.md). This never touches GenerateView.
@MainActor
enum KeyboardWarmer {
    private static var didWarm = false
    private static var warmWindow: UIWindow?

    static func warmUp() {
        guard !didWarm else { return }
        didWarm = true

        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }

        let window = UIWindow(windowScene: scene)
        // Below the app's real window(s), effectively invisible, and non-interactive.
        window.windowLevel = .normal - 1
        window.isHidden = false
        window.alpha = 0
        window.isUserInteractionEnabled = false

        let field = UITextField(frame: .zero)
        // Match the real composer's input traits so the warmed keyboard config is reused,
        // not rebuilt on first real focus (HighlightingTextView uses .sentences / .default).
        field.autocapitalizationType = .sentences
        field.autocorrectionType = .default
        let root = UIViewController()
        root.view.addSubview(field)
        window.rootViewController = root
        warmWindow = window

        field.becomeFirstResponder()

        // Resign + tear down on the next runloop tick — long enough for UIKit to spin up the
        // keyboard subsystem, short enough that the transient keyboard never actually paints.
        DispatchQueue.main.async {
            field.resignFirstResponder()
            warmWindow?.isHidden = true
            warmWindow = nil
        }
    }
}
