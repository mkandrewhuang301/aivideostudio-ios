// ListSnapshotStore.swift
// Fantasia
// Generic JSON snapshot store in Caches, keyed per-user, so lists (generations, uploads) can
// render instantly on cold start instead of showing a spinner until the network responds.
// Mirrors CreditManager's per-uid cached-balance pattern (Credits/CreditManager.swift), but
// backed by a file instead of UserDefaults since these lists can grow much larger.

import Foundation

enum ListSnapshotStore {
    private struct Snapshot<T: Codable>: Codable {
        let items: [T]
        let fetchedAt: Date
    }

    private static func url(name: String, uid: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("\(name)-\(uid).json")
    }

    static func load<T: Codable>(_ type: [T].Type, name: String, uid: String) -> (items: [T], fetchedAt: Date)? {
        guard let url = url(name: name, uid: uid),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot<T>.self, from: data) else { return nil }
        return (snapshot.items, snapshot.fetchedAt)
    }

    static func save<T: Codable>(_ items: [T], name: String, uid: String) {
        guard let url = url(name: name, uid: uid),
              let data = try? JSONEncoder().encode(Snapshot(items: items, fetchedAt: Date())) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear(name: String, uid: String) {
        guard let url = url(name: name, uid: uid) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Account deletion cleanup for all UID-keyed list/detail snapshots, including editor
    /// snapshots whose project IDs may no longer be present in the currently loaded page.
    static func clearAll(uid: String) {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return }
        let suffix = "-\(uid).json"
        for file in files where file.lastPathComponent.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
