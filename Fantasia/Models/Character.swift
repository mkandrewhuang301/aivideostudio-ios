// Codable client model for the public Cast registry (GET /api/characters).

import Foundation

/// Named CastCharacter to avoid shadowing Swift.Character throughout the app module.
struct CastCharacter: Codable, Identifiable, Equatable {
    let characterId: String
    let name: String
    let category: String
    let status: String
    let artUrl: String
    let bio: String
    let voiceLabel: String
    let sortOrder: Int

    var id: String { characterId }
    var artURL: URL? { URL(string: artUrl) }
    var isSoon: Bool { status == "soon" }

    var categoryTitle: String {
        switch category {
        case "3d_generated": "3D Generated"
        default: category.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    enum CodingKeys: String, CodingKey {
        case characterId = "character_id"
        case name
        case category
        case status
        case artUrl = "art_url"
        case bio
        case voiceLabel = "voice_label"
        case sortOrder = "sort_order"
    }
}

struct CharactersResponse: Codable {
    let version: Int
    let characters: [CastCharacter]
}
