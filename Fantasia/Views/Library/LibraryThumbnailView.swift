// LibraryThumbnailView.swift
// Fantasia
// Individual cell in the Library masonry grid.
// Height is driven by the video's native aspect ratio — caller passes the ratio.

import SwiftUI
import AVFoundation

struct LibraryThumbnailView: View {
    let item: GenerationItem
    let ratio: CGFloat          // native width/height e.g. 16/9, 9/16, 1/1
    var onTap: () -> Void

    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Color.white.opacity(0.04)

                if item.isImage {
                    // Images: AsyncImage thumbnail, no play overlay
                    if let urlString = item.completedMediaUrl, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                Color(.systemGray5)
                            }
                        }
                        .clipped()
                    } else {
                        Color(.systemGray5)
                    }
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
            .aspectRatio(ratio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
        .buttonStyle(.plain)
        .onAppear {
            if !item.isImage, let urlString = item.videoUrl, thumbnail == nil {
                loadThumbnail(urlString: urlString)
            }
        }
    }

    private func loadThumbnail(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                thumbnail = UIImage(cgImage: cgImg)
            }
        }
    }
}
