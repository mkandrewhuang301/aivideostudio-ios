// VideoCache.swift
// Fantasia
// Disk cache for generation video files, keyed by generation ID — not URL, since presigned
// R2 URLs rotate on every fetch but the underlying object per generation doesn't change.
// Mirrors ThumbnailCache's disk layer. Used so a video only ever downloads once: the
// full-screen player checks here before streaming, and GenerationCardView pre-warms the
// cache while a job is still showing its completion animation, so "tap to play" is instant.

import Foundation

actor VideoCache {
    static let shared = VideoCache()

    private var inFlight: [String: Task<URL, Error>] = [:]

    private static var diskURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("videos", isDirectory: true)
    }

    private static func fileURL(for id: String) -> URL {
        diskURL.appendingPathComponent(id + ".mp4")
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.diskURL, withIntermediateDirectories: true)
    }

    /// Local file URL if this generation's video is already fully downloaded.
    nonisolated func cachedURL(for id: String) -> URL? {
        let file = Self.fileURL(for: id)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Downloads to disk if not already cached; concurrent calls for the same id share one download.
    @discardableResult
    func ensureCached(id: String, remoteURL: URL) async throws -> URL {
        if let cached = cachedURL(for: id) { return cached }
        if let existing = inFlight[id] { return try await existing.value }

        let dest = Self.fileURL(for: id)
        let task = Task<URL, Error> {
            let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            return dest
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        return try await task.value
    }

    /// Fire-and-forget warm — used when playback starts from the network so the *next* open is instant.
    nonisolated func prefetch(id: String, remoteURL: URL) {
        guard cachedURL(for: id) == nil else { return }
        Task { try? await ensureCached(id: id, remoteURL: remoteURL) }
    }
}
