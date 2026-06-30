// FullScreenImageView.swift
// Fantasia
// Full-screen image viewer with pinch-to-zoom and share (image analog of
// FullScreenVideoPlayerView). Opened when a completed image generation is tapped.

import SwiftUI

struct FullScreenImageView: View {
    let item: GenerationItem
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let urlString = item.completedMediaUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .gesture(magnificationGesture)
                            .onTapGesture(count: 2) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    scale = scale > 1.5 ? 1.0 : 2.5
                                }
                                lastScale = scale
                            }
                    case .failure:
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 40))
                    case .empty:
                        ProgressView()
                            .tint(.white)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Overlay buttons — match FullScreenVideoPlayerView styling (top-right dismiss)
            VStack {
                HStack {
                    Spacer()

                    // Share button
                    Button {
                        shareImage()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(20)
                    }

                    // Dismiss button — top-right, matches FullScreenVideoPlayerView
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .statusBar(hidden: true)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(maxScale, max(minScale, newScale))
            }
            .onEnded { _ in
                lastScale = scale
                if scale < 1.0 {
                    withAnimation(.spring()) { scale = 1.0 }
                    lastScale = 1.0
                }
            }
    }

    private func shareImage() {
        guard let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        // Share the R2 URL directly — save to camera roll for images is deferred (08-CONTEXT.md)
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            activity.popoverPresentationController?.sourceView = scene.windows.first
            root.present(activity, animated: true)
        }
    }
}
