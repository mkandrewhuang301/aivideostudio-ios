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
