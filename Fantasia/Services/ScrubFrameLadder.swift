// ScrubFrameLadder.swift
// Fantasia
//
// Dense, source-time-anchored preview frames for editor scrubbing. AVPlayer seek completion is
// intentionally not the display path here: long-GOP video cannot decode arbitrary seeks quickly
// enough to follow a finger. Each video clip is decoded once at 0.3-second intervals and the UI
// reads the nearest already-available frame at or before the requested source time.

import AVFoundation
import Observation
import UIKit

@Observable
@MainActor
final class ScrubFrameLadder {
    static let stepSeconds = 0.3

    /// `NSCache` is the sole strong owner of decoded frames, so its count limit is a real memory
    /// bound. The per-clip map retains only stable cache keys used for nearest-frame lookup.
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()
    private var frameKeys: [String: [Int: NSString]] = [:]
    private var generationTasks: [String: Task<Void, Never>] = [:]
    private var completedClipIds: Set<String> = []
    private var presentClipIds: Set<String> = []

    /// Read by `frame(...)` so progressive cache population invalidates observing SwiftUI views.
    private var revision: UInt = 0

    /// Warms every video clip, putting the clip under `globalTime` first. Existing clip ids keep
    /// their source-time ladders across trim changes; an id removed from the project is discarded
    /// and will receive a fresh ladder if it later reappears.
    func warm(
        project clips: [ProjectClip],
        ranges: [EditorCompositionBuilder.ClipRange],
        at globalTime: Double = 0
    ) {
        let currentIds = Set(clips.map(\.id))
        let removedIds = presentClipIds.subtracting(currentIds)
        for clipId in removedIds {
            generationTasks[clipId]?.cancel()
            generationTasks[clipId] = nil
            completedClipIds.remove(clipId)
            if let keys = frameKeys.removeValue(forKey: clipId)?.values {
                keys.forEach(imageCache.removeObject)
            }
        }
        presentClipIds = currentIds

        let prioritizedClipId = activeRange(at: globalTime, ranges: ranges)?.clipId
        let orderedVideos = clips
            .filter { $0.mediaType == "video" }
            .sorted { lhs, rhs in
                if lhs.id == prioritizedClipId { return true }
                if rhs.id == prioritizedClipId { return false }
                return lhs.sortOrder < rhs.sortOrder
            }

        for clip in orderedVideos {
            guard generationTasks[clip.id] == nil, !completedClipIds.contains(clip.id) else { continue }
            let task = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                await self.generateFrames(for: clip)
            }
            generationTasks[clip.id] = task
        }
    }

    /// Returns the nearest populated ladder frame at or below the resolved source time.
    func frame(
        project clips: [ProjectClip],
        at globalTime: Double,
        ranges: [EditorCompositionBuilder.ClipRange]
    ) -> UIImage? {
        _ = revision
        guard let range = activeRange(at: globalTime, ranges: ranges),
              let clip = clips.first(where: { $0.id == range.clipId }),
              clip.mediaType == "video",
              let keys = frameKeys[clip.id]
        else { return nil }

        let sourceTime = max(0, clip.trimStartSeconds + (globalTime - range.start))
        var bucket = Int(floor((sourceTime + 0.000_001) / Self.stepSeconds))
        while bucket >= 0 {
            if let key = keys[bucket], let image = imageCache.object(forKey: key) {
                return image
            }
            bucket -= 1
        }
        return nil
    }

    private func generateFrames(for clip: ProjectClip) async {
        defer { generationTasks[clip.id] = nil }
        guard presentClipIds.contains(clip.id),
              let urlString = clip.url,
              let remoteURL = URL(string: urlString)
        else { return }

        let localURL = await ClipFileCache.shared.localURL(clipId: clip.id, remoteURL: remoteURL)
        guard !Task.isCancelled, presentClipIds.contains(clip.id) else { return }

        let asset = AVURLAsset(url: localURL)
        let loadedDuration = try? await asset.load(.duration)
        let assetDuration = loadedDuration?.seconds ?? 0
        let declaredDuration = clip.originalDurationSeconds ?? 0
        let duration = max(assetDuration.isFinite ? assetDuration : 0, declaredDuration)
        guard duration > 0 else {
            completedClipIds.insert(clip.id)
            return
        }

        let lastBucket = max(0, Int(floor(duration / Self.stepSeconds)))
        let times = (0...lastBucket).map {
            CMTime(seconds: min(Double($0) * Self.stepSeconds, duration), preferredTimescale: 600)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        for await result in generator.images(for: times) {
            guard !Task.isCancelled, presentClipIds.contains(clip.id) else {
                generator.cancelAllCGImageGeneration()
                return
            }
            guard case let .success(requestedTime, cgImage, _) = result else { continue }
            let bucket = max(0, Int((requestedTime.seconds / Self.stepSeconds).rounded()))
            let key = NSString(string: "\(clip.id):\(bucket)")
            imageCache.setObject(UIImage(cgImage: cgImage), forKey: key)
            frameKeys[clip.id, default: [:]][bucket] = key
            revision &+= 1
        }

        if presentClipIds.contains(clip.id) {
            completedClipIds.insert(clip.id)
        }
    }

    private func activeRange(
        at globalTime: Double,
        ranges: [EditorCompositionBuilder.ClipRange]
    ) -> EditorCompositionBuilder.ClipRange? {
        guard let last = ranges.last else { return nil }
        let clampedTime = min(max(0, globalTime), last.end)
        if clampedTime >= last.end { return last }
        return ranges.first { clampedTime >= $0.start && clampedTime < $0.end }
    }
}
