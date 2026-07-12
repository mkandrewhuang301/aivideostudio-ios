// MediaPrepService.swift
// Fantasia
// Off-main-actor helper for reference-video attachment: writing picked data to disk, probing
// duration, HEVC transcoding, and thumbnail extraction. All of this used to run inline on
// GenerateView's calling context (MainActor), doing synchronous file I/O and a blocking
// AVAssetImageGenerator frame extraction — that stuttered the UI while attaching a reference.
// A plain `actor` (not @MainActor) guarantees this work runs on a background executor.

import Foundation
import AVFoundation
import UIKit

actor MediaPrepService {
    static let shared = MediaPrepService()

    struct WrittenVideo {
        let url: URL
        let durationSeconds: Double
    }

    /// Writes picked video data to a temp file and probes its duration.
    /// Split out from prepareForUpload so the caller can enforce the 15s total-duration cap
    /// (which needs MainActor-bound view state) before spending CPU on transcoding.
    func writeAndProbeDuration(_ data: Data) async throws -> WrittenVideo {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
        try data.write(to: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        return WrittenVideo(url: url, durationSeconds: duration)
    }

    struct PreparedVideo {
        let data: Data
        let url: URL
        let thumbnail: UIImage?
    }

    /// Transcodes HEVC input to H.264 if needed, reads the final file back into memory, and
    /// extracts a thumbnail frame for the reference card — all off the main actor.
    func prepareForUpload(inputURL: URL, fallbackData: Data) async -> PreparedVideo {
        let finalURL = (try? await transcodeToH264IfNeeded(url: inputURL)) ?? inputURL
        let finalData = (try? Data(contentsOf: finalURL)) ?? fallbackData
        let thumbnail = Self.extractThumbnail(from: finalURL)
        return PreparedVideo(data: finalData, url: finalURL, thumbnail: thumbnail)
    }

    /// Poster frame for a local or remote video URL — used by reference chips and inline
    /// token pills when no in-memory thumbnail is available yet.
    func thumbnailFromVideo(at url: URL) -> UIImage? {
        Self.extractThumbnail(from: url)
    }

    private static func extractThumbnail(from url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init)
    }

    // MARK: - Magic Editor alpha-mask export (09.2-10, SC4)
    //
    // A pure, testable helper (no view/actor-state dependency) — a plain `static func` on an
    // actor type is NOT actor-isolated (only instance members are), so this is callable directly
    // as `MediaPrepService.alphaMaskPNG(...)` from any context, including MaskEditorView's
    // MainActor-isolated submit path, without an `await` hop.
    //
    // RESEARCH Pitfall 3 (mask alpha convention is inverted from intuition): OpenAI's gpt-image-2
    // `/v1/images/edits` convention is TRANSPARENT (alpha=0) = edit, OPAQUE (alpha=255) = preserve.
    // A naive "painted = white/opaque" export inverts the edit. This fills the whole canvas
    // opaque white first (preserve), then draws the painted-stroke image on top with
    // `.destinationOut`, which punches the painted region's alpha down to 0 (edit) wherever the
    // stroke image has any alpha — leaving everywhere else at the initial opaque fill.
    //
    // RESEARCH Pitfall 2/7 (dimension + size constraints): must render at the SOURCE image's
    // exact pixel size — mismatched dims between image/mask → undefined behavior server-side.
    // Callers (MaskEditorView) are responsible for resizing the source to satisfy gpt-image-2's
    // own constraints (edges multiple of 16, total px bounds) BEFORE calling this, and must pass
    // that same (possibly resized) pixel size here so image and mask stay dimension-matched.
    static func alphaMaskPNG(strokeImage: UIImage, sourcePixelSize: CGSize) -> Data {
        // BUG FIX (2026-07-12): UIGraphicsImageRenderer(size:)'s convenience init defaults
        // format.scale to the MAIN SCREEN's scale (2x or 3x on every current device) — the
        // rendered PNG's actual pixel dimensions were sourcePixelSize * scale, NOT
        // sourcePixelSize, silently violating the "must render at the source's exact pixel
        // size" invariant this function's own doc comment describes (caught by
        // FantasiaTests/MaskEditorExportTests.swift, which asserts the exported mask's pixel
        // dimensions against sourcePixelSize directly). sourcePixelSize is already in raw
        // pixels (it comes from a UIImage's .size after prepareSourceImage — see
        // MaskEditorView — used as a POINT size here), so the renderer must use scale 1.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: sourcePixelSize, format: format)
        return renderer.pngData { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: sourcePixelSize)) // opaque = preserve
            strokeImage.draw(in: CGRect(origin: .zero, size: sourcePixelSize), blendMode: .destinationOut, alpha: 1) // painted → alpha 0 = edit
        }
    }
}

// MARK: - HEVC transcoding helper
// Moved from GenerateView.swift — was previously @MainActor for no functional reason (nothing
// here touches UI state), which forced this work onto the main thread whenever awaited from a
// MainActor-isolated caller. Neither this function nor exportAsync() need to run on any
// particular actor; calling them from MediaPrepService (a plain, non-MainActor actor) keeps
// them off the main thread.

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: self.error ?? NSError(domain: "AVExport", code: -1))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: NSError(domain: "AVExport", code: -1))
                }
            }
        }
    }
}

private func transcodeToH264IfNeeded(url: URL) async throws -> URL {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { return url }
    let descs = try await track.load(.formatDescriptions)
    let isHEVC = descs.contains {
        CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) == kCMVideoCodecType_HEVC
    }
    guard isHEVC else { return url }

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp4")
    guard let session = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
    ) else {
        throw NSError(domain: "AVExport", code: -1)
    }
    session.outputURL = tmpURL
    session.outputFileType = .mp4
    try await session.exportAsync()
    return tmpURL
}
