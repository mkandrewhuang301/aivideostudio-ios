// ZoomPanScrollView.swift
// Fantasia
// Native UIScrollView-backed pinch-zoom + pan — the same mechanism Photos.app uses. Chosen over
// SwiftUI's MagnificationGesture/DragGesture + scaleEffect/offset (the old FullScreenImageView
// approach) because UIScrollView's zoom is driven directly by UIKit's gesture recognizers and
// CALayer, not the SwiftUI render loop — it tracks touch with no perceptible lag and gets
// momentum/bounce/double-tap-to-zoom for free instead of hand-rolled spring math.
//
// Content is supplied as a plain UIView (a UIImageView for stills, an AVPlayerLayer-backed view
// for video) sized to `contentSize` — the aspect-fit rect — so double-tap-to-zoom and centering
// line up with the actually-visible pixels rather than letterboxed dead space.

import SwiftUI
import UIKit

// UIViewRepresentable's makeUIView runs before SwiftUI has given the view its real frame, so
// centering there (or in updateUIView's initial call) operates against a zero-size bounds and
// pins the content to the top-left instead. layoutSubviews is the one hook guaranteed to fire
// with a valid bounds — both on first appearance and on rotation/resize.
private final class CenteringScrollView: UIScrollView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct ZoomPanScrollView<ContentView: UIView>: UIViewRepresentable {
    let makeContentView: () -> ContentView
    let updateContentView: (ContentView) -> Void
    let contentSize: CGSize
    var minZoom: CGFloat = 1.0
    var maxZoom: CGFloat = 5.0
    var doubleTapZoom: CGFloat = 2.5

    /// Fires while a pan happens at minimum zoom — the host view has nothing to pan internally
    /// at that point, so this is repurposed as the swipe-to-dismiss signal.
    var onUnzoomedPan: (_ translation: CGSize, _ velocity: CGSize, _ state: UIGestureRecognizer.State) -> Void = { _, _, _ in }
    var onSingleTap: () -> Void = {}
    var onZoomChanged: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = CenteringScrollView()
        scrollView.onLayout = { [weak coordinator = context.coordinator] in coordinator?.centerContent() }
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minZoom
        scrollView.maximumZoomScale = maxZoom
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        // Scroll view fills the whole screen (ignoresSafeArea at the call site) — auto safe-area
        // insets here would offset the centering math against the actually-full-bleed bounds.
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let contentView = makeContentView()
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.addSubview(contentView)
        scrollView.contentSize = contentSize
        context.coordinator.contentView = contentView
        context.coordinator.scrollView = scrollView
        context.coordinator.baseContentSize = contentSize

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // A second pan recognizer alongside the scroll view's own — at zoomScale == minimum
        // the scroll view has no overflow to pan, so this one runs unopposed and reports the
        // gesture back to the caller to drive swipe-to-dismiss. Once zoomed in, its handler
        // no-ops and the scroll view's built-in pan takes over content panning as normal.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        scrollView.addGestureRecognizer(pan)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        guard let contentView = context.coordinator.contentView else { return }
        updateContentView(contentView)
        if context.coordinator.baseContentSize != contentSize {
            context.coordinator.baseContentSize = contentSize
            scrollView.setZoomScale(minZoom, animated: false)
            contentView.frame = CGRect(origin: .zero, size: contentSize)
            scrollView.contentSize = contentSize
            context.coordinator.centerContent()
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomPanScrollView
        weak var contentView: ContentView?
        weak var scrollView: UIScrollView?
        var baseContentSize: CGSize = .zero

        init(_ parent: ZoomPanScrollView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
            parent.onZoomChanged(scrollView.zoomScale)
        }

        // Standard Apple recipe (PhotoScroller-style): once the zoomed content is smaller than
        // the scroll view's bounds on an axis, center it there instead of letting it hug the
        // top-left corner.
        func centerContent() {
            guard let scrollView, let contentView else { return }
            let boundsSize = scrollView.bounds.size
            var frame = contentView.frame
            frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
            frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
            contentView.frame = frame
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > parent.minZoom + 0.01 {
                scrollView.setZoomScale(parent.minZoom, animated: true)
            } else {
                let point = gesture.location(in: contentView)
                let targetScale = parent.doubleTapZoom
                let size = CGSize(width: scrollView.bounds.width / targetScale, height: scrollView.bounds.height / targetScale)
                let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
                scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
            }
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            parent.onSingleTap()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            guard scrollView.zoomScale <= parent.minZoom + 0.01, gesture.numberOfTouches <= 1 else {
                parent.onUnzoomedPan(.zero, .zero, .cancelled)
                return
            }
            let t = gesture.translation(in: scrollView)
            let v = gesture.velocity(in: scrollView)
            parent.onUnzoomedPan(CGSize(width: t.x, height: t.y), CGSize(width: v.x, height: v.y), gesture.state)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
