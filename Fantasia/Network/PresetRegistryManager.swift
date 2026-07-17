// PresetRegistryManager.swift
// Fantasia
// Fetches the server-driven preset registry from GET /api/presets (public endpoint) and exposes
// it to HomeView + PresetInputSheet. Mirrors RatesManager's shape exactly: unconditional load()
// at launch, loadIfNeeded() staleness guard, bundled-JSON fallback, disk snapshot so a cold start
// shows the latest known registry instead of the bundled placeholder (Home must never render
// blank — T-09.1-08 accepted risk, mitigated by this fallback chain).

import Foundation

@Observable
final class PresetRegistryManager {
    private static let snapshotName = "presetsSnapshot"
    // Registry rows are not user-specific — use a fixed key so the snapshot survives sign-out/in.
    private static let snapshotKey = "public"
    private static let staleAfter: TimeInterval = 3600

    private(set) var presets: [Preset] = PresetRegistryManager.bundledFallback
    private(set) var lastLoadDate: Date?
    private(set) var isLoaded = false

    init() {
        if let snapshot = ListSnapshotStore.load([Preset].self, name: Self.snapshotName, uid: Self.snapshotKey),
           !snapshot.items.isEmpty {
            presets = snapshot.items
            lastLoadDate = snapshot.fetchedAt
            isLoaded = true
        }
    }

    /// Loads the bundled `presets.json` fallback shipped in the app bundle. Used at init and
    /// whenever a network/decode failure occurs with no better snapshot available.
    private static let bundledFallback: [Preset] = {
        guard let url = Bundle.main.url(forResource: "presets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(PresetsResponse.self, from: data) else {
            return []
        }
        return response.presets
    }()

    func load() async {
        do {
            let url = AppConfig.baseURL.appendingPathComponent("api/presets")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(PresetsResponse.self, from: data)
            presets = decoded.presets
            lastLoadDate = Date()
            ListSnapshotStore.save(presets, name: Self.snapshotName, uid: Self.snapshotKey)
        } catch {
            // Keep whatever we already have (disk snapshot or bundled fallback) — never blank Home.
            if presets.isEmpty {
                presets = Self.bundledFallback
            }
        }
        isLoaded = true
    }

    /// Skips the network call unless we've never loaded successfully or it's been over an hour —
    /// same staleness guard as RatesManager.loadIfNeeded(), used on scenePhase == .active.
    func loadIfNeeded() async {
        let isStale = lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        guard isStale else { return }
        await load()
    }
}
