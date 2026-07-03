// FullScreenImageView.swift
// Fantasia
// Full-screen image viewer with pinch-to-zoom and pan. Dismiss via X button or swipe.

import SwiftUI

struct FullScreenImageView: View {
    let item: GenerationItem
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    @State private var loadedImage: UIImage? = nil
    @State private var isLoading = false
    @State private var isDismissDragging = false
    @State private var isDismissing = false
    @State private var dragOffset: CGSize = .zero
    @State private var zoomScale: CGFloat = 1.0

    private let dismissDistanceThreshold: CGFloat = 120
    // True gesture velocity in points/second (UIPanGestureRecognizer.velocity), not the old
    // SwiftUI DragGesture predictedEndTranslation approximation — recalibrated accordingly.
    private let dismissVelocityThreshold: CGFloat = 1200
    private let exitDistance: CGFloat = 900

    /// 0...1 progress of an in-flight swipe-to-dismiss drag (only active when unzoomed).
    /// Reaches 1 well before the image is fully off-screen so the backdrop finishes
    /// fading to reveal the presenting view underneath as the image flies out.
    private var dismissProgress: CGFloat {
        guard zoomScale <= 1.01 else { return 0 }
        return min(1, abs(dragOffset.height) / 300)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
                .opacity(1 - dismissProgress)

            if let img = loadedImage {
                GeometryReader { geo in
                    ZoomPanScrollView(
                        makeContentView: {
                            let imageView = UIImageView(image: img)
                            imageView.contentMode = .scaleAspectFit
                            return imageView
                        },
                        updateContentView: { (imageView: UIImageView) in
                            imageView.image = img
                        },
                        contentSize: fittedSize(imageSize: img.size, containerSize: geo.size),
                        onUnzoomedPan: { translation, velocity, state in
                            handleUnzoomedPan(translation: translation, velocity: velocity, state: state)
                        },
                        onZoomChanged: { zoomScale = $0 }
                    )
                }
                .ignoresSafeArea()
                .scaleEffect(1 - dismissProgress * 0.15, anchor: .center)
                .offset(dragOffset)
            } else {
                // T21 fix: this branch (cache miss / still loading / error) previously had no
                // dismiss gesture at all — only ZoomPanScrollView's UIPanGestureRecognizer in the
                // loadedImage branch above handled swipe-to-dismiss, so the first swipe on a cold
                // cache did nothing until the image finished loading. Mirrors
                // FullScreenVideoPlayerView.dismissDragGesture, which exists for the same reason
                // (its own no-content branch).
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 40))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(placeholderDismissGesture)
            }

            // Floating dismiss button — no bar background, so zoomed content can go full-bleed.
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { commitDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary.opacity(0.9))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.vertical, 12)
                }
                Spacer()
            }
            .opacity(1 - dismissProgress)
        }
        .background(TransparentFullScreenBackground())
        .statusBar(hidden: true)
        .nameAsReferenceAlert()
        .onAppear {
            Task {
                if let cached = await ThumbnailCache.shared.image(for: item.id) {
                    loadedImage = cached
                } else {
                    await fetchAndCacheImage()
                }
            }
        }
    }

    // MARK: - Gestures

    // Driven by ZoomPanScrollView's UIPanGestureRecognizer, which only forwards while unzoomed —
    // zoomed-in panning is handled natively by the UIScrollView itself.
    private func handleUnzoomedPan(translation: CGSize, velocity: CGSize, state: UIGestureRecognizer.State) {
        switch state {
        case .began, .changed:
            isDismissDragging = true
            dragOffset = translation
        case .ended, .cancelled:
            isDismissDragging = false
            if abs(translation.height) > dismissDistanceThreshold || abs(velocity.height) > dismissVelocityThreshold {
                commitDismiss(from: translation)
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = .zero
                }
            }
        default:
            break
        }
    }

    /// Legacy SwiftUI-gesture path — only reachable while loadedImage is nil (cache miss/loading/
    /// error), where ZoomPanScrollView (and its native, frame-by-frame pan) isn't in the tree yet.
    private var placeholderDismissGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                let velocity = abs(value.predictedEndTranslation.height - value.translation.height)
                if abs(value.translation.height) > dismissDistanceThreshold || velocity > 800 {
                    commitDismiss(from: value.translation)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { dragOffset = .zero }
                }
            }
    }

    // MARK: - Geometry

    /// Size of the image as rendered by `.scaledToFit()` at scale == 1, accounting
    /// for letterboxing/pillarboxing within `containerSize`.
    private func fittedSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return containerSize
        }
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        if imageAspect > containerAspect {
            let width = containerSize.width
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = containerSize.height
            return CGSize(width: height * imageAspect, height: height)
        }
    }

    /// Carries the fly-out + fade started by a drag (or the X button) to completion, then
    /// dismisses — by the time the system removes the cover, the content is already
    /// transparent, so the presenting view is revealed via fade rather than a slide-away.
    private func commitDismiss(from dragOffsetOverride: CGSize? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        let base = dragOffsetOverride ?? dragOffset
        let verticalSign: CGFloat = base.height < 0 ? -1 : 1
        withAnimation(.easeOut(duration: 0.22)) {
            dragOffset = CGSize(width: base.width, height: verticalSign * exitDistance)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.22))
            dismiss()
        }
    }

    // MARK: - Load

    private func fetchAndCacheImage() async {
        guard let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        isLoading = true
        defer { isLoading = false }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        // T20: same decode-off-render-path fix as GenerationDetailSheet.loadCachedImage —
        // UIImage(data:) decodes lazily on first draw, which could otherwise stall the main
        // thread during presentation and eat the initial dismiss-swipe touch.
        let prepared = await image.byPreparingForDisplay() ?? image
        ThumbnailCache.shared[item.id] = prepared
        loadedImage = prepared
    }
}
