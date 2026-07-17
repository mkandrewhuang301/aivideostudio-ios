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

    static func isValidPayload(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 1_024,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 32) else { return false }
        return !prefix.starts(with: Data("<?xml".utf8))
            && !prefix.starts(with: Data("<Error".utf8))
            && !prefix.starts(with: Data("<!DOCTYPE html".utf8))
            && !prefix.starts(with: Data("{".utf8))
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.diskURL, withIntermediateDirectories: true)
    }

    /// Local file URL if this generation's video is already fully downloaded.
    nonisolated func cachedURL(for id: String) -> URL? {
        let file = Self.fileURL(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard Self.isValidPayload(at: file) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    /// Downloads to disk if not already cached; concurrent calls for the same id share one download.
    @discardableResult
    func ensureCached(id: String, remoteURL: URL) async throws -> URL {
        if let cached = cachedURL(for: id) { return cached }
        if let existing = inFlight[id] { return try await existing.value }

        let dest = Self.fileURL(for: id)
        let task = Task<URL, Error> {
            let (tmpURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  Self.isValidPayload(at: tmpURL)
            else {
                try? FileManager.default.removeItem(at: tmpURL)
                throw URLError(.badServerResponse)
            }
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
