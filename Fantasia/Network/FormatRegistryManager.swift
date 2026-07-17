// FormatRegistryManager.swift
// Fantasia
// Fetches the server-driven formats registry from GET /api/formats and keeps a bundled fallback
// plus a disk snapshot so Home never renders blank when the network is unavailable.

import Foundation

@Observable
final class FormatRegistryManager {
    private static let snapshotName = "formatsSnapshot"
    // Registry rows are public and not user-specific, so the cache survives sign-out/in.
    private static let snapshotKey = "public"
    private static let staleAfter: TimeInterval = 3600

    private(set) var formats: [Format] = FormatRegistryManager.bundledFallback
    private(set) var lastLoadDate: Date?
    private(set) var isLoaded = false

    init() {
        if let snapshot = ListSnapshotStore.load([Format].self, name: Self.snapshotName, uid: Self.snapshotKey),
           !snapshot.items.isEmpty {
            formats = snapshot.items
            lastLoadDate = snapshot.fetchedAt
            isLoaded = true
        }
    }

    /// Loads the bundled `formats.json` fallback shipped in the app bundle. Used at init and
    /// whenever a network or decode failure occurs without a better cached snapshot.
    private static let bundledFallback: [Format] = {
        guard let url = Bundle.main.url(forResource: "formats", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(FormatsResponse.self, from: data) else {
            return []
        }
        return response.formats
    }()

    func load() async {
        do {
            let url = AppConfig.baseURL.appendingPathComponent("api/formats")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(FormatsResponse.self, from: data)
            formats = decoded.formats
            lastLoadDate = Date()
            ListSnapshotStore.save(formats, name: Self.snapshotName, uid: Self.snapshotKey)
        } catch {
            // Keep the disk snapshot or bundled fallback already in memory — never blank Home.
            if formats.isEmpty {
                formats = Self.bundledFallback
            }
        }
        isLoaded = true
    }

    /// Skips the network call unless the registry has never loaded or is over an hour old.
    func loadIfNeeded() async {
        let isStale = lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        guard isStale else { return }
        await load()
    }
}
