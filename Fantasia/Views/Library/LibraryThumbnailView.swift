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

    @State private var thumbnail: UIImage? = nil
    @State private var cachedImage: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Color.white.opacity(0.04)

                if item.isImage {
                    // Images: cached loader (presigned URLs change per-fetch, URLCache won't hit)
                    Group {
                        if let img = cachedImage {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Color(.systemGray5)
                        }
                    }
                    .clipped()
                } else {
                    if let thumb = thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.white.opacity(0.04)
                        Image(systemName: "film")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 22))
                    }

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
        .buttonStyle(.plain)
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
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let image = UIImage(cgImage: cgImg)
                ThumbnailCache.shared[item.id] = image
                thumbnail = image
            }
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
