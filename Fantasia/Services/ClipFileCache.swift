// ClipFileCache.swift
// Fantasia
// Plan 13-26 M1 (Fix B): local disk cache for Edit Studio clip media, keyed by clip id (not URL —
// presigned R2 URLs rotate every refresh, but the underlying object per clip doesn't change until
// the clip is deleted/replaced). Root cause this fixes: every editor open re-downloaded every
// clip's full video from R2 to build the live preview composition/filmstrips, even for a project
// that had already been opened seconds ago — this cache makes the SECOND+ open of any given clip
// instant, matching VideoCache.swift's established pattern for generation videos (Caches dir,
// in-flight de-dup) but adding an LRU size cap (Edit Studio projects can hold far more/longer clips
// than a single generation feed) and living in Application Support (not Caches — Caches can be
// purged by the OS under storage pressure at any time, which would silently break an editor mid-
// session; Application Support persists until the app explicitly manages it, which this cache
// does itself via the LRU prune below).
//
// Never-fail contract: `localURL(clipId:remoteURL:)` returns `remoteURL` on ANY cache/download
// error — every caller (EditorCompositionBuilder, ClipPillView) already knows how to load directly
// from a remote URL, so a cache miss/failure degrades to the pre-M1 behavior instead of breaking
// playback.

import Foundation

actor ClipFileCache {
    static let shared = ClipFileCache()

    /// 500MB LRU cap — enforced after every successful insert (never blocks the caller; runs
    /// synchronously at the end of the insert since we're already off the main actor here).
    private static let maxCacheBytes: Int64 = 500 * 1024 * 1024

    private var inFlight: [String: Task<URL, Never>] = [:]

    private static var cacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("ClipCache", isDirectory: true)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
    }

    private static func fileURL(clipId: String, remoteURL: URL) -> URL {
        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        return cacheDirectory.appendingPathComponent(clipId).appendingPathExtension(ext)
    }

    /// Returns a local file URL for `clipId`, downloading it first if not already cached.
    /// Touches the file's access date on a cache hit (feeds the LRU prune below). On ANY error
    /// (download failure, disk-full, etc.) this returns `remoteURL` unchanged — callers never fail
    /// because of this cache.
    func localURL(clipId: String, remoteURL: URL) async -> URL {
        let dest = Self.fileURL(clipId: clipId, remoteURL: remoteURL)

        if FileManager.default.fileExists(atPath: dest.path) {
            touchAccessDate(dest)
            #if DEBUG
            print("[ClipFileCache] hit \(clipId)")
            #endif
            return dest
        }

        if let existing = inFlight[clipId] {
            return await existing.value
        }

        let task = Task<URL, Never> {
            do {
                let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmpURL, to: dest)
                #if DEBUG
                print("[ClipFileCache] miss \(clipId) — downloaded")
                #endif
                self.enforceLRUCap()
                return dest
            } catch {
                #if DEBUG
                print("[ClipFileCache] miss \(clipId) — download failed, falling back to remote: \(error)")
                #endif
                return remoteURL
            }
        }
        inFlight[clipId] = task
        defer { inFlight[clipId] = nil }
        return await task.value
    }

    /// Deletes any cached file(s) for the given clip ids — called on project delete (any extension,
    /// since we don't know which one was cached without a directory scan).
    func remove(clipIds: [String]) {
        guard !clipIds.isEmpty else { return }
        let idSet = Set(clipIds)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.cacheDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in entries where idSet.contains(fileURL.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func touchAccessDate(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Deletes least-recently-modified files (oldest `.contentModificationDateKey` first) until the
    /// directory's total size is back under `maxCacheBytes`. Runs synchronously on this actor right
    /// after an insert — cheap relative to the download it follows, and keeps eviction logic in one
    /// place rather than a separate background task that could race a fresh download.
    private func enforceLRUCap() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Self.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var files: [(url: URL, size: Int64, date: Date)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize
            else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }

        var totalSize = files.reduce(0) { $0 + $1.size }
        guard totalSize > Self.maxCacheBytes else { return }

        files.sort { $0.date < $1.date } // oldest-accessed first
        for file in files {
            guard totalSize > Self.maxCacheBytes else { break }
            try? FileManager.default.removeItem(at: file.url)
            totalSize -= file.size
            #if DEBUG
            print("[ClipFileCache] LRU evicted \(file.url.lastPathComponent)")
            #endif
        }
    }
}
