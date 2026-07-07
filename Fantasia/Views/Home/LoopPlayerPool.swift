// LoopPlayerPool.swift
// Fantasia
// Bounded pool of muted, looping AVQueuePlayers for the Home preset grid (D-08, RESEARCH
// Pattern 4). At most `maxPlayers` players are ever live app-wide — tiles acquire a player
// on-screen and release it off-screen. Requesting beyond the cap while every slot is ACTIVE
// (on-screen) returns nil rather than stealing — a visible tile must never lose its player out
// from under it (2026-07-08 fix: stealing an active slot left the ORIGINAL tile displaying that
// slot's player after it got reassigned+paused elsewhere, i.e. "plays a few seconds then freezes
// on a frame that isn't even this tile's video" — see notes/2026-07-08-home-preset-loop-freeze-plan.md).
// Only IDLE (already off-screen, already-detached) slots are ever reused. Players are created
// ONCE and reused (AVPlayerItems are swapped in), never allocated per tile (Pitfall 3:
// main-thread AVPlayer allocation is expensive and stalls scroll).

import AVFoundation
import Observation

@MainActor
@Observable
final class LoopPlayerPool {
    static let shared = LoopPlayerPool()

    /// Covers a full Home screenful + lazy-load lookahead: hero(1) + Video Effects(4) +
    /// Photo Effects(6) + Avatar Center(1) = 12 (Shows & Vlogs' 2 tiles are further down the
    /// scroll and pick up a freed slot via `availabilityGeneration` once one exists). Raised from
    /// 6 (2026-07-08) — 6 was below a single screen's tile count, which forced constant stealing
    /// even before the active-slot-steal bug above. Bounds concurrent AVPlayer instances so
    /// scroll never drops frames (Pitfall 3, T-09.1-09) — re-profile scroll perf if raised further.
    static let maxPlayers = 12

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

    /// Bumped every time `release()` frees a slot (marks it idle). Tiles that were denied a
    /// player (pool full of active slots) observe this via `.task(id:)` and retry — the ONLY way
    /// a poster-only tile ever upgrades to playing, since `acquire` is otherwise called just once
    /// in `.onAppear`. Reading this from a View's `body` during a `.task(id:)` registers it for
    /// Observation tracking like any other `@Observable` property, even accessed via `.shared`.
    private(set) var availabilityGeneration = 0

    private init() {}

    /// Downloads `loopURL` fully to disk (file-first — never streamed, RESEARCH Pattern 4 rule
    /// 3) via `LoopFileCache`, then hands back a muted, playing `AVQueuePlayer` looping the local
    /// file for `presetId`. Returns nil while the download is still in flight or fails; the
    /// caller (PresetTileView) shows its poster in the meantime (D-08 Option A — no spinner).
    func acquire(presetId: String, loopURL: URL) async -> AVQueuePlayer? {
        guard let localURL = try? await LoopFileCache.shared.ensureCached(presetId: presetId, remoteURL: loopURL) else {
            return nil
        }

        // Already assigned (e.g. tile scrolled back on-screen before its now-idle slot was
        // reused by another tile) — just resume; the item is already loaded, so playback is
        // instant.
        if let index = assignments[presetId], entries[index].presetId == presetId {
            entries[index].isActive = true
            entries[index].lastUsed = Date()
            entries[index].player.isMuted = true
            entries[index].player.play()
            return entries[index].player
        }

        // No idle slot and pool is full of ACTIVE (on-screen) tiles — do not steal one; the
        // caller keeps showing its poster (D-08's existing no-player state) and retries via
        // availabilityGeneration once something frees up.
        guard let index = indexForNewAssignment() else { return nil }
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
    /// different tile reuses the now-idle slot first via `indexForNewAssignment`. Bumps
    /// `availabilityGeneration` so any tile currently showing just its poster (denied a player
    /// while the pool was full of active slots) gets a chance to retry `acquire`.
    func release(presetId: String) {
        guard let index = assignments[presetId], entries[index].presetId == presetId else { return }
        entries[index].isActive = false
        entries[index].player.pause()
        availabilityGeneration += 1
    }

    /// Idle slots (released, off-screen) are reused first; otherwise grow up to the cap;
    /// otherwise nil — an ACTIVE (on-screen) slot is never stolen (2026-07-08, see file header).
    private func indexForNewAssignment() -> Int? {
        if let idleIndex = entries.indices.first(where: { !entries[$0].isActive }) {
            return idleIndex
        }
        if entries.count < Self.maxPlayers {
            let player = AVQueuePlayer()
            player.isMuted = true
            entries.append(PoolEntry(player: player))
            return entries.count - 1
        }
        return nil
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
