// LetterboxCropper.swift
// Fantasia
// Plan 13-28 O4: conservatively removes symmetric baked black bars from legacy project covers
// at display time. New covers are already saved at source aspect and pass through unchanged.

import SwiftUI
import UIKit

enum LetterboxCropper {
    private static let analysisWidth = 48
    private static let darkLuminance: Double = 0.055
    private static let minimumBandFraction: Double = 0.06
    private static let maximumCombinedBandFraction: Double = 0.45
    private static let maximumAsymmetry: Double = 0.25

    static func stripLetterbox(_ image: UIImage) -> UIImage {
        guard let normalized = normalizedImage(image),
              let analysis = luminanceAnalysis(for: normalized)
        else { return image }

        let horizontal = cropCandidate(means: analysis.rowMeans)
        let vertical = cropCandidate(means: analysis.columnMeans)

        let axis: CropAxis
        let candidate: CropCandidate
        switch (horizontal, vertical) {
        case let (rows?, columns?):
            if rows.combinedFraction >= columns.combinedFraction {
                axis = .rows
                candidate = rows
            } else {
                axis = .columns
                candidate = columns
            }
        case let (rows?, nil):
            axis = .rows
            candidate = rows
        case let (nil, columns?):
            axis = .columns
            candidate = columns
        case (nil, nil):
            return image
        }

        guard let cgImage = normalized.cgImage else { return image }
        let cropRect: CGRect
        switch axis {
        case .rows:
            let top = CGFloat(candidate.leading) / CGFloat(analysis.rowMeans.count)
            let bottom = CGFloat(candidate.trailing) / CGFloat(analysis.rowMeans.count)
            let y = CGFloat(cgImage.height) * top
            let height = CGFloat(cgImage.height) * (1 - top - bottom)
            cropRect = CGRect(x: 0, y: y, width: CGFloat(cgImage.width), height: height)
        case .columns:
            let left = CGFloat(candidate.leading) / CGFloat(analysis.columnMeans.count)
            let right = CGFloat(candidate.trailing) / CGFloat(analysis.columnMeans.count)
            let x = CGFloat(cgImage.width) * left
            let width = CGFloat(cgImage.width) * (1 - left - right)
            cropRect = CGRect(x: x, y: 0, width: width, height: CGFloat(cgImage.height))
        }

        let integralCrop = cropRect.integral.intersection(
            CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
        guard integralCrop.width > 0, integralCrop.height > 0,
              let cropped = cgImage.cropping(to: integralCrop)
        else { return image }
        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }

    private enum CropAxis {
        case rows
        case columns
    }

    private struct CropCandidate {
        let leading: Int
        let trailing: Int
        let combinedFraction: Double
    }

    private struct LuminanceAnalysis {
        let rowMeans: [Double]
        let columnMeans: [Double]
    }

    private static func cropCandidate(means: [Double]) -> CropCandidate? {
        guard !means.isEmpty else { return nil }
        let leading = means.prefix { $0 < darkLuminance }.count
        let trailing = means.reversed().prefix { $0 < darkLuminance }.count
        guard leading > 0, trailing > 0 else { return nil }

        let count = Double(means.count)
        let leadingFraction = Double(leading) / count
        let trailingFraction = Double(trailing) / count
        let combinedFraction = leadingFraction + trailingFraction
        let asymmetry = Double(abs(leading - trailing)) / Double(max(leading, trailing))
        guard leadingFraction >= minimumBandFraction,
              trailingFraction >= minimumBandFraction,
              asymmetry <= maximumAsymmetry,
              combinedFraction <= maximumCombinedBandFraction
        else { return nil }
        return CropCandidate(
            leading: leading,
            trailing: trailing,
            combinedFraction: combinedFraction
        )
    }

    private static func normalizedImage(_ image: UIImage) -> UIImage? {
        if image.imageOrientation == .up, image.cgImage != nil { return image }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func luminanceAnalysis(for image: UIImage) -> LuminanceAnalysis? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let width = min(analysisWidth, cgImage.width)
        let height = max(1, Int((Double(cgImage.height) * Double(width) / Double(cgImage.width)).rounded()))
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let drewImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewImage else { return nil }

        var rowSums = [Double](repeating: 0, count: height)
        var columnSums = [Double](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = Double(pixels[offset]) / 255
                let green = Double(pixels[offset + 1]) / 255
                let blue = Double(pixels[offset + 2]) / 255
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                rowSums[y] += luminance
                columnSums[x] += luminance
            }
        }
        return LuminanceAnalysis(
            rowMeans: rowSums.map { $0 / Double(width) },
            columnMeans: columnSums.map { $0 / Double(height) }
        )
    }
}

@MainActor
private final class ProcessedCoverImageLoader {
    static let shared = ProcessedCoverImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 100
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if let existing = inFlight[url.absoluteString] { return await existing.value }

        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) { return nil }
            guard let source = UIImage(data: data) else { return nil }
            return LetterboxCropper.stripLetterbox(source)
        }
        inFlight[url.absoluteString] = task
        let processed = await task.value
        inFlight[url.absoluteString] = nil
        if let processed { cache.setObject(processed, forKey: key) }
        return processed
    }
}

/// Shared cover-thumbnail loader. The processed UIImage is cached once per presigned URL; callers
/// retain their existing fixed-shell + scaledToFill + clipped layout around this view.
struct LetterboxThumbnailView<Placeholder: View>: View {
    let url: URL
    let placeholder: Placeholder

    @State private var image: UIImage?

    init(url: URL, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await ProcessedCoverImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
