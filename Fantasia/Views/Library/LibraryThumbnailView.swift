// LibraryThumbnailView.swift
// Fantasia
// D-08: Individual cell in the Library 2-column grid
// Square thumbnail cell — consistent with iOS Photos.app pattern
// Thumbnail generated from first frame via AVAssetImageGenerator (same as GenerationCardView)

import SwiftUI
import AVFoundation

struct LibraryThumbnailView: View {
    let item: GenerationItem
    var onTap: () -> Void

    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Aspect ratio box — square cells in the grid for clean 2-column layout (D-08)
                Color.white.opacity(0.04)
                    .aspectRatio(1.0, contentMode: .fill)

                if let thumb = thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    // Loading shimmer placeholder
                    Color.white.opacity(0.04)
                    Image(systemName: "film")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 22))
                }

                // Play icon overlay
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onAppear {
            if let urlString = item.videoUrl, thumbnail == nil {
                loadThumbnail(urlString: urlString)
            }
        }
    }

    // AVAssetImageGenerator (same pattern as GenerationCardView) — RESEARCH.md Pattern 5
    private func loadThumbnail(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 300, height: 300)
            if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                thumbnail = UIImage(cgImage: cgImg)
            }
        }
    }
}
