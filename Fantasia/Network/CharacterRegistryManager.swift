// Public Cast registry with bundled fallback and disk snapshot, matching the preset/format
// registry resilience pattern so the Cast tab never renders blank when the backend is offline.

import Foundation

@Observable
final class CharacterRegistryManager {
    private static let snapshotName = "charactersSnapshot"
    private static let snapshotKey = "public"
    private static let staleAfter: TimeInterval = 3600

    private(set) var characters: [CastCharacter] = CharacterRegistryManager.bundledFallback
    private(set) var lastLoadDate: Date?
    private(set) var isLoaded = false

    init() {
        if let snapshot = ListSnapshotStore.load(
            [CastCharacter].self,
            name: Self.snapshotName,
            uid: Self.snapshotKey
        ), !snapshot.items.isEmpty {
            characters = snapshot.items
            lastLoadDate = snapshot.fetchedAt
            isLoaded = true
        }
    }

    private static let bundledFallback: [CastCharacter] = {
        guard let url = Bundle.main.url(forResource: "characters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(CharactersResponse.self, from: data) else {
            return []
        }
        return response.characters
    }()

    func load() async {
        do {
            let url = AppConfig.baseURL.appendingPathComponent("api/characters")
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let decoded = try JSONDecoder().decode(CharactersResponse.self, from: data)
            characters = decoded.characters
            lastLoadDate = Date()
            ListSnapshotStore.save(characters, name: Self.snapshotName, uid: Self.snapshotKey)
        } catch {
            if characters.isEmpty {
                characters = Self.bundledFallback
            }
        }
        isLoaded = true
    }

    func loadIfNeeded() async {
        let isStale = lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        guard isStale else { return }
        await load()
    }
}
