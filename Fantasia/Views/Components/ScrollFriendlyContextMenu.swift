// ScrollFriendlyContextMenu.swift
// Fantasia
// UIKit-backed long-press context menu that does NOT eat fast scroll flicks.
//
// ⚠️ Why this exists — do not replace with SwiftUI's .contextMenu:
// SwiftUI's .contextMenu installs a touch-holding recognizer over the entire attached view.
// When the enclosing ScrollView is AT REST, every touch-down on the view is held while the
// recognizer disambiguates "long press?" vs "scroll?" — a very fast flick is finished before
// that arbitration resolves, so the touch dies and the feed doesn't scroll at all. Once the
// scroll view is already moving it claims new touches directly (tracking mode) and the card's
// recognizers never see them — which is why quick swipes "work while scrolling but not from
// rest". This regressed twice in this project (fixed 2026-07-03 by removing .contextMenu in
// commit 9213c27, regressed each time menus were re-added: 90a5a2a Library tiles, then the
// 2026-07-06 feed-card media menu).
//
// UIKit's UIContextMenuInteraction participates in the native UIScrollView gesture arbitration
// instead (the same mechanism Photos uses): flicks start scrolling immediately, while a genuine
// held press still lifts the preview and opens the menu.

import SwiftUI
import UIKit

final class ContextMenuHitTestView: UIView {
    var passthroughTopTrailingSize: CGSize = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard passthroughTopTrailingSize.width > 0,
              passthroughTopTrailingSize.height > 0 else {
            return super.point(inside: point, with: event)
        }
        let passthroughRect = CGRect(
            x: bounds.maxX - passthroughTopTrailingSize.width,
            y: bounds.minY,
            width: passthroughTopTrailingSize.width,
            height: passthroughTopTrailingSize.height
        )
        return passthroughRect.contains(point)
            ? false
            : super.point(inside: point, with: event)
    }
}

/// Transparent overlay carrying a UIContextMenuInteraction (+ optional tap forwarding).
///
/// Because this UIKit view hit-tests across its whole frame, it sits ABOVE any SwiftUI tap
/// gestures underneath it — plain taps must be forwarded via `onTap`. Vertical scroll flicks,
/// the SwipeToDeleteRow horizontal drag, and other ancestor SwiftUI gestures are unaffected
/// (gesture recognizers observe touches anywhere in their view's subtree).
///
/// ⚠️ No-duplicate lift (user request 2026-07-06): the overlay is transparent, so a naive
/// `previewProvider` would lift a SEPARATE snapshot platter while the real SwiftUI image stayed
/// fully visible underneath during the highlight phase — reading as "two images". Instead we
/// build a `UITargetedPreview` anchored exactly over the media box (so the lift looks like *the*
/// image rising in place, correctly sized), and we tell the SwiftUI parent via
/// `onPreviewingChanged` to hide the underlying media for the duration of the interaction so
/// there is never a visible duplicate.
struct ScrollFriendlyContextMenu: UIViewRepresentable {
    /// nil disables the menu entirely — the interaction returns no configuration, so a long
    /// press does nothing and no preview is lifted (e.g. while a generation is in flight).
    var menu: () -> UIMenu?
    /// Rendered into the lifted `UITargetedPreview`, sized to fill the media box. The overlay
    /// itself is transparent, so without this there'd be nothing to lift.
    var previewImage: UIImage?
    /// Plain taps land on this overlay (not the SwiftUI views under it) and are forwarded here.
    var onTap: (() -> Void)?
    /// Fired with `true` when the lift begins and `false` once it has settled back. The parent
    /// hides its own media while `true` so the lifted preview is the ONLY visible copy.
    var onPreviewingChanged: ((Bool) -> Void)?
    /// Corner radius of the lifted preview — match the media box's own `clipShape` radius.
    var previewCornerRadius: CGFloat = 12
    /// Bakes a centered "play.circle.fill" badge into the lifted preview for video media — the
    /// underlying SwiftUI view draws this same badge over its thumbnail, but the lift only
    /// grabs `previewImage` (the bare frame), so without this the badge would vanish for the
    /// duration of the long-press (user report 2026-07-06).
    var showsPlayIcon: Bool = false
    /// Point size of the play badge — GenerationCardView (36pt) and LibraryThumbnailView (28pt)
    /// render it at different sizes to match their own overlay.
    var playIconSize: CGFloat = 36
    /// Bakes a bottom-leading "heart.fill" badge into the lifted preview for favorited media —
    /// same rationale as `showsPlayIcon` (LibraryThumbnailView only).
    var showsFavoriteBadge: Bool = false
    /// Optional top-trailing region that should pass touches through to controls layered below
    /// this UIKit view. The context-menu preview remains full-size; only hit-testing changes.
    var passthroughTopTrailingSize: CGSize = .zero

    func makeUIView(context: Context) -> ContextMenuHitTestView {
        let view = ContextMenuHitTestView()
        view.backgroundColor = .clear
        view.passthroughTopTrailingSize = passthroughTopTrailingSize
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.didTap))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: ContextMenuHitTestView, context: Context) {
        context.coordinator.parent = self
        uiView.passthroughTopTrailingSize = passthroughTopTrailingSize
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var parent: ScrollFriendlyContextMenu
        private var isPreviewing = false
        init(parent: ScrollFriendlyContextMenu) { self.parent = parent }

        @objc func didTap() { parent.onTap?() }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let menu = parent.menu() else { return nil }
            // previewProvider is nil: the targeted preview from previewForHighlighting is reused
            // for the presented menu, so we never spin up a second, separately-sized platter.
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            guard let preview = makePreview(for: interaction) else { return nil }
            setPreviewing(true)
            return preview
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            // Animate the lift back into the exact same box on dismiss.
            makePreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            willEndFor configuration: UIContextMenuConfiguration,
            animator: UIContextMenuInteractionAnimating?
        ) {
            // Restore the SwiftUI media only once the preview has finished settling back so the
            // hidden→visible swap is hidden behind the still-present preview.
            if let animator {
                animator.addCompletion { [weak self] in self?.setPreviewing(false) }
            } else {
                setPreviewing(false)
            }
        }

        /// A preview anchored to fill the media box exactly, so the lift reads as the real image.
        /// Wrapped in a plain container (instead of lifting the UIImageView directly) so the
        /// play/favorite badges below can be layered on top of it, matching what's on screen.
        private func makePreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view, let image = parent.previewImage else { return nil }
            let bounds = CGRect(origin: .zero, size: view.bounds.size)
            let container = UIView(frame: bounds)
            container.clipsToBounds = true
            container.layer.cornerRadius = parent.previewCornerRadius

            let imageView = UIImageView(image: image)
            imageView.frame = bounds
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            container.addSubview(imageView)

            if parent.showsPlayIcon {
                let config = UIImage.SymbolConfiguration(pointSize: parent.playIconSize, weight: .regular)
                let playView = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: config))
                playView.tintColor = UIColor.white.withAlphaComponent(0.85)
                playView.sizeToFit()
                playView.center = CGPoint(x: bounds.midX, y: bounds.midY)
                container.addSubview(playView)
            }

            if parent.showsFavoriteBadge {
                let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                let heartView = UIImageView(image: UIImage(systemName: "heart.fill", withConfiguration: config))
                heartView.tintColor = .white
                heartView.layer.shadowColor = UIColor.black.withAlphaComponent(0.35).cgColor
                heartView.layer.shadowRadius = 2
                heartView.layer.shadowOffset = CGSize(width: 0, height: 1)
                heartView.layer.shadowOpacity = 1
                heartView.sizeToFit()
                heartView.frame.origin = CGPoint(x: 6, y: bounds.height - heartView.frame.height - 6)
                container.addSubview(heartView)
            }

            let params = UIPreviewParameters()
            params.backgroundColor = .clear
            params.visiblePath = UIBezierPath(roundedRect: bounds, cornerRadius: parent.previewCornerRadius)
            let target = UIPreviewTarget(container: view,
                                         center: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            return UITargetedPreview(view: container, parameters: params, target: target)
        }

        private func setPreviewing(_ value: Bool) {
            guard isPreviewing != value else { return }
            isPreviewing = value
            // Delegate callbacks fire during a UIKit layout pass; defer the SwiftUI state change.
            DispatchQueue.main.async { [weak self] in self?.parent.onPreviewingChanged?(value) }
        }
    }
}
