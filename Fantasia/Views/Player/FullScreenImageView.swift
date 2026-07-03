// FullScreenImageView.swift
// Fantasia
// Full-screen image viewer with pinch-to-zoom and pan. Dismiss via X button or swipe.

import SwiftUI

struct FullScreenImageView: View {
    let item: GenerationItem
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationManager.self) private var generationManager

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var loadedImage: UIImage? = nil
    @State private var isLoading = false
    @State private var isDismissDragging = false
    @State private var isDismissing = false

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0
    private let dismissDistanceThreshold: CGFloat = 120
    private let dismissVelocityThreshold: CGFloat = 800
    private let exitDistance: CGFloat = 900

    /// 0...1 progress of an in-flight swipe-to-dismiss drag (only active when unzoomed).
    /// Reaches 1 well before the image is fully off-screen so the backdrop finishes
    /// fading to reveal the presenting view underneath as the image flies out.
    private var dismissProgress: CGFloat {
        guard scale <= minScale else { return 0 }
        return min(1, abs(offset.height) / 300)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .opacity(1 - dismissProgress)

            if let img = loadedImage {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale * (1 - dismissProgress * 0.15), anchor: .center)
                        .offset(offset)
                        .simultaneousGesture(pinchAndPanGesture(imageSize: img.size, containerSize: geo.size))
                        .onTapGesture(count: 2) { handleDoubleTap() }
                        .contextMenu {
                            if item.status == .completed {
                                Button("Name as reference", systemImage: "tag") {
                                    generationManager.pendingNameAsReference = item
                                    NotificationCenter.default.post(name: .nameAsReferenceRequested, object: nil)
                                    dismiss()
                                }
                            }
                        }
                }
                .ignoresSafeArea()
            } else if isLoading {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 40))
            }

            // Dismiss button row with opaque black background so zoomed image can't bleed through
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { commitDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.vertical, 12)
                }
                .background(Color.black)
                Spacer()
            }
            .opacity(1 - dismissProgress)
        }
        .background(TransparentFullScreenBackground())
        .statusBar(hidden: true)
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

    private func pinchAndPanGesture(imageSize: CGSize, containerSize: CGSize) -> some Gesture {
        SimultaneousGesture(MagnificationGesture(), DragGesture())
            .onChanged { value in
                if let magnification = value.first {
                    scale = min(maxScale, max(minScale, lastScale * magnification))
                }
                if let drag = value.second {
                    if scale > minScale {
                        let maxOff = maxOffset(imageSize: imageSize, containerSize: containerSize, scale: scale)
                        let rawX = lastOffset.width + drag.translation.width
                        let rawY = lastOffset.height + drag.translation.height
                        offset = CGSize(
                            width: rubberBanded(rawX, limit: maxOff.width, dimension: containerSize.width),
                            height: rubberBanded(rawY, limit: maxOff.height, dimension: containerSize.height)
                        )
                    } else {
                        // Unzoomed: track the drag directly as a swipe-to-dismiss gesture.
                        isDismissDragging = true
                        offset = drag.translation
                    }
                } else {
                    // No active drag this event (e.g. a static pinch) — re-clamp in case
                    // the scale change alone moved us out of bounds.
                    offset = clampedOffset(offset, imageSize: imageSize, containerSize: containerSize, scale: scale)
                }
            }
            .onEnded { value in
                if value.first != nil {
                    lastScale = scale
                }
                if scale > minScale {
                    let clamped = clampedOffset(offset, imageSize: imageSize, containerSize: containerSize, scale: scale)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        offset = clamped
                    }
                    lastOffset = clamped
                } else if isDismissDragging {
                    isDismissDragging = false
                    let translation = value.second?.translation ?? .zero
                    let predicted = value.second?.predictedEndTranslation ?? .zero
                    let velocityProxy = predicted.height - translation.height
                    if abs(translation.height) > dismissDistanceThreshold || abs(velocityProxy) > dismissVelocityThreshold {
                        commitDismiss(from: translation)
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            offset = .zero
                        }
                        lastOffset = .zero
                    }
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

    /// Maximum allowed |offset| per axis at a given scale. An axis whose scaled
    /// image is still smaller than the container yields 0 (no panning on that axis).
    private func maxOffset(imageSize: CGSize, containerSize: CGSize, scale: CGFloat) -> CGSize {
        let fitted = fittedSize(imageSize: imageSize, containerSize: containerSize)
        let scaledWidth = fitted.width * scale
        let scaledHeight = fitted.height * scale
        return CGSize(
            width: max(0, (scaledWidth - containerSize.width) / 2),
            height: max(0, (scaledHeight - containerSize.height) / 2)
        )
    }

    private func clampedOffset(_ offset: CGSize, imageSize: CGSize, containerSize: CGSize, scale: CGFloat) -> CGSize {
        let m = maxOffset(imageSize: imageSize, containerSize: containerSize, scale: scale)
        return CGSize(
            width: min(m.width, max(-m.width, offset.width)),
            height: min(m.height, max(-m.height, offset.height))
        )
    }

    /// UIScrollView-style rubber-band resistance for a value past its limit.
    private func rubberBandOverflow(_ overflow: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (1.0 - (1.0 / ((overflow * coefficient / dimension) + 1.0))) * dimension
    }

    private func rubberBanded(_ value: CGFloat, limit: CGFloat, dimension: CGFloat) -> CGFloat {
        if value > limit {
            return limit + rubberBandOverflow(value - limit, dimension: dimension)
        } else if value < -limit {
            return -limit - rubberBandOverflow(-limit - value, dimension: dimension)
        } else {
            return value
        }
    }

    /// Carries the fly-out + fade started by a drag (or the X button) to completion, then
    /// dismisses — by the time the system removes the cover, the content is already
    /// transparent, so the presenting view is revealed via fade rather than a slide-away.
    private func commitDismiss(from dragOffset: CGSize? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        let base = dragOffset ?? offset
        let verticalSign: CGFloat = base.height < 0 ? -1 : 1
        withAnimation(.easeOut(duration: 0.22)) {
            offset = CGSize(width: base.width, height: verticalSign * exitDistance)
        }
        Task {
            try? await Task.sleep(for: .seconds(0.22))
            dismiss()
        }
    }

    private func handleDoubleTap() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if scale > 1.5 {
                scale = 1.0; lastScale = 1.0
                offset = .zero; lastOffset = .zero
            } else {
                scale = 2.5; lastScale = 2.5
            }
        }
    }

    // MARK: - Load

    private func fetchAndCacheImage() async {
        guard let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        isLoading = true
        defer { isLoading = false }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        ThumbnailCache.shared[item.id] = image
        loadedImage = image
    }
}
