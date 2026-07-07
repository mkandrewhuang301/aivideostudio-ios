// LibraryThumbnailView.swift
// Fantasia
// Individual cell in the Library justified grid.
// The caller frames this view at the media's native aspect ratio, so
// scaledToFill fills the cell without cropping.

import SwiftUI
import AVFoundation

struct LibraryThumbnailView: View {
    let item: GenerationItem
    var onTap: () -> Void
    var onNameAsReference: () -> Void = {}
    var onRequestDelete: () -> Void = {}

    @Environment(ThemeManager.self) private var theme
    @State private var thumbnail: UIImage? = nil
    @State private var cachedImage: UIImage? = nil
    @State private var isMediaPreviewActive = false  // hides the tile while the long-press lift is on screen (no duplicate)

    var body: some View {
        // scaledToFill makes the thumbnail's LAYOUT FRAME larger than the cell (clipShape/
        // clipped only fix drawing, not hit testing), leaving invisible tappable overflow
        // over neighboring cells that opens the wrong item. Color.clear pins the label's
        // frame to the cell, allowsHitTesting(false) removes the media from hit testing,
        // and contentShape makes exactly the visible cell tappable.
        theme.surfaceStrong
            .overlay {
                ZStack {
                    if item.isImage {
                        // Images: cached loader (presigned URLs change per-fetch, URLCache won't hit)
                        Group {
                            if let img = cachedImage {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                theme.surfaceStrong
                            }
                        }
                    } else {
                        if let thumb = thumbnail {
                            Image(uiImage: thumb)
                                .resizable()
                                .scaledToFill()
                        } else {
                            theme.surfaceStrong
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 22))
                        }

                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .allowsHitTesting(false)
                // Hidden while the long-press preview is lifted so the lifted copy is the only
                // visible image (avoids the "two images" duplicate look).
                .opacity(isMediaPreviewActive ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if item.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(6)
                        .allowsHitTesting(false)
                        .opacity(isMediaPreviewActive ? 0 : 1)
                }
            }
            // Long-press context menu + tap, UIKit-backed. ⚠️ A SwiftUI .contextMenu here held
            // every touch-down while the grid was at rest, so very fast flicks starting on a
            // tile (i.e. anywhere on the grid) died before the ScrollView could claim them —
            // the "quick swipe from rest doesn't scroll" bug. See ScrollFriendlyContextMenu's
            // header. The overlay hit-tests the whole tile, so it forwards the plain tap too.
            .overlay {
                ScrollFriendlyContextMenu(
                    menu: {
                        UIMenu(children: [
                            UIAction(title: "Name as Reference", image: UIImage(systemName: "tag")) { _ in
                                onNameAsReference()
                            },
                            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                                onRequestDelete()
                            }
                        ])
                    },
                    previewImage: item.isImage ? cachedImage : thumbnail,
                    onTap: onTap,
                    onPreviewingChanged: { active in isMediaPreviewActive = active },
                    previewCornerRadius: 8,
                    showsPlayIcon: !item.isImage,
                    playIconSize: 28,
                    showsFavoriteBadge: item.isFavorite
                )
            }
            .onAppear {
                if !item.isImage, let urlString = item.videoUrl, thumbnail == nil {
                    loadThumbnail(urlString: urlString)
                }
                if item.isImage, cachedImage == nil {
                    loadCachedImage()
                }
            }
    }

    private func loadThumbnail(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task {
            if let cached = await ThumbnailCache.shared.image(for: item.id) { thumbnail = cached; return }
            // Prefer the already-downloaded local file (GenerationCardView caches every
            // completed video by id) so this never touches the network on a grid cell.
            let localURL = VideoCache.shared.cachedURL(for: item.id) ?? url
            let asset = AVURLAsset(url: localURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            // Async — never blocks the calling thread (unlike the old synchronous
            // copyCGImage(at:actualTime:), which stalled every grid cell's onAppear on a
            // main-thread network fetch + decode when many cells reset at once).
            guard let (cgImg, _) = try? await gen.image(at: .zero) else { return }
            let image = UIImage(cgImage: cgImg)
            ThumbnailCache.shared[item.id] = image
            thumbnail = image
        }
    }

    // Perf: grid cells previously decoded and cached the full-resolution generated image just
    // to display it at ~half-screen-width. Downscaled to match the video thumbnail path's
    // existing 400x400 cap (gen.maximumSize above), cached under a distinct "-grid" key so
    // full-screen/detail views (which read ThumbnailCache[item.id] directly) are unaffected
    // and keep loading/caching the full-resolution image independently.
    private func loadCachedImage() {
        guard let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        let gridKey = item.id + "-grid"
        Task {
            if let cached = await ThumbnailCache.shared.image(for: gridKey) { cachedImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let thumb = image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
            ThumbnailCache.shared[gridKey] = thumb
            cachedImage = thumb
        }
    }
}
