// LoopPlayerPool.swift
// Fantasia
// Bounded pool of muted, looping AVQueuePlayers for the Home preset grid (D-08, RESEARCH
// Pattern 4). At most `maxPlayers` players are ever live app-wide — tiles acquire a player
// on-screen and release it off-screen; requesting beyond the cap steals the least-recently-used
// slot. Players are created ONCE and reused (AVPlayerItems are swapped in), never allocated per
// tile (Pitfall 3: main-thread AVPlayer allocation is expensive and stalls scroll).

import AVFoundation
import Observation

@MainActor
@Observable
final class LoopPlayerPool {
    static let shared = LoopPlayerPool()

    /// Roughly what fits one screen of 2-col ~3:4 tiles plus a row of lookahead (RESEARCH
    /// Pattern 4 rule 1). Bounds concurrent AVPlayer instances so scroll never drops frames
    /// (Pitfall 3, T-09.1-09).
    static let maxPlayers = 6

    private struct PoolEntry {
        let player: AVQueuePlayer
        // AVPlayerLooper must be retained alongside its player or looping silently stops
        // (RESEARCH Pattern 4 rule 4 / documented pitfall).
        var looper: AVPlayerLooper?
        var presetId: String?
        var isActive = false
        var lastUsed = Date.distantPast
    }

    private var entries: [PoolEntry] = []
    private var assignments: [String: Int] = [:]

    private init() {}

    /// Downloads `loopURL` fully to disk (file-first — never streamed, RESEARCH Pattern 4 rule
    /// 3) via `LoopFileCache`, then hands back a muted, playing `AVQueuePlayer` looping the local
    /// file for `presetId`. Returns nil while the download is still in flight or fails; the
    /// caller (PresetTileView) shows its poster in the meantime (D-08 Option A — no spinner).
    func acquire(presetId: String, loopURL: URL) async -> AVQueuePlayer? {
        guard let localURL = try? await LoopFileCache.shared.ensureCached(presetId: presetId, remoteURL: loopURL) else {
            return nil
        }

        // Already assigned (e.g. tile scrolled back on-screen before its slot was stolen) —
        // just resume; the item is already loaded, so playback is instant.
        if let index = assignments[presetId], entries[index].presetId == presetId {
            entries[index].isActive = true
            entries[index].lastUsed = Date()
            entries[index].player.isMuted = true
            entries[index].player.play()
            return entries[index].player
        }

        let index = indexForNewAssignment()
        let previousPresetId = entries[index].presetId
        if let previousPresetId, previousPresetId != presetId {
            assignments[previousPresetId] = nil
        }

        let player = entries[index].player
        player.pause()
        player.removeAllItems()
        let item = AVPlayerItem(url: localURL)
        let looper = AVPlayerLooper(player: player, templateItem: item)

        entries[index].looper = looper
        entries[index].presetId = presetId
        entries[index].isActive = true
        entries[index].lastUsed = Date()
        assignments[presetId] = index

        player.isMuted = true
        player.play()
        return player
    }

    /// Pauses the tile's player and marks its slot idle — never keeps an off-screen player
    /// playing. The player + item stay assigned (for instant resume on re-appearance) unless a
    /// different tile steals the slot first via `indexForNewAssignment`'s idle-preference.
    func release(presetId: String) {
        guard let index = assignments[presetId], entries[index].presetId == presetId else { return }
        entries[index].isActive = false
        entries[index].player.pause()
    }

    /// Idle slots (released, off-screen) are reused first; otherwise grow up to the cap;
    /// otherwise steal the least-recently-used slot (RESEARCH Pattern 4 rule 1).
    private func indexForNewAssignment() -> Int {
        if let idleIndex = entries.indices.first(where: { !entries[$0].isActive }) {
            return idleIndex
        }
        if entries.count < Self.maxPlayers {
            let player = AVQueuePlayer()
            player.isMuted = true
            entries.append(PoolEntry(player: player))
            return entries.count - 1
        }
        return entries.indices.min(by: { entries[$0].lastUsed < entries[$1].lastUsed }) ?? 0
    }
}

// File-first disk cache for preset loop videos, keyed by presetId + the loop URL's filename
// (RESEARCH Pattern 4 rule 3 — the ingestion script's version-suffixed filenames, e.g.
// loop-v2.mp4, give free cache-busting: a new version is a new cache key). Mirrors
// VideoCache.swift's actor shape exactly. Downloads fully before playback ever starts, so
// AVPlayer never stalls the network mid-scroll and loop start is instant on revisit.
actor LoopFileCache {
    static let shared = LoopFileCache()

    private var inFlight: [String: Task<URL, Error>] = [:]

    private static var diskURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("preset-loops", isDirectory: true)
    }

    private static func fileURL(for key: String) -> URL {
        diskURL.appendingPathComponent(key + ".mp4")
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.diskURL, withIntermediateDirectories: true)
    }

    nonisolated func cachedURL(for key: String) -> URL? {
        let file = Self.fileURL(for: key)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    @discardableResult
    func ensureCached(presetId: String, remoteURL: URL) async throws -> URL {
        let key = presetId + "-" + remoteURL.lastPathComponent
        if let cached = cachedURL(for: key) { return cached }
        if let existing = inFlight[key] { return try await existing.value }

        let dest = Self.fileURL(for: key)
        let task = Task<URL, Error> {
            let (tmpURL, _) = try await URLSession.shared.download(from: remoteURL)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            return dest
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}
