// Format.swift
// Fantasia
// Codable models for the server-driven formats registry (GET /api/formats).

import Foundation

struct Format: Codable, Identifiable, Equatable {
    let formatId: String
    let title: String
    let subtitle: String?
    let section: String
    let badge: String?
    let sortOrder: Int
    let status: String
    let tile: FormatTile
    let styleGrid: [FormatStyle]
    let voices: [FormatVoice]
    let voiceDefault: String
    let musicMoods: [String]
    let durationTiers: [FormatDurationTier]
    let aspectRatios: [String]
    let sheet: FormatSheetMeta

    var id: String { formatId }
    var isLive: Bool { status == "live" }
    var defaultAspectRatio: String { aspectRatios.first ?? "9:16" }

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case title
        case subtitle
        case section
        case badge
        case sortOrder = "sort_order"
        case status
        case tile
        case styleGrid = "style_grid"
        case voices
        case voiceDefault = "voice_default"
        case musicMoods = "music_moods"
        case durationTiers = "duration_tiers"
        case aspectRatios = "aspect_ratios"
        case sheet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatId = try container.decode(String.self, forKey: .formatId)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        section = try container.decode(String.self, forKey: .section)
        badge = try container.decodeIfPresent(String.self, forKey: .badge)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        status = try container.decode(String.self, forKey: .status)
        tile = try container.decodeIfPresent(FormatTile.self, forKey: .tile)
            ?? FormatTile(posterUrl: nil, loopUrl: nil)

        // SOON rows are presentation-only by contract. Defaulting absent live-only fields keeps
        // the client model backward-compatible without making the server ship fake pricing or
        // pipeline configuration for teasers.
        styleGrid = try container.decodeIfPresent([FormatStyle].self, forKey: .styleGrid) ?? []
        voices = try container.decodeIfPresent([FormatVoice].self, forKey: .voices) ?? []
        voiceDefault = try container.decodeIfPresent(String.self, forKey: .voiceDefault) ?? ""
        musicMoods = try container.decodeIfPresent([String].self, forKey: .musicMoods) ?? []
        durationTiers = try container.decodeIfPresent([FormatDurationTier].self, forKey: .durationTiers) ?? []
        aspectRatios = try container.decodeIfPresent([String].self, forKey: .aspectRatios) ?? []
        sheet = try container.decodeIfPresent(FormatSheetMeta.self, forKey: .sheet)
            ?? FormatSheetMeta(description: subtitle ?? "", preparingLabel: "")
    }
}

struct FormatTile: Codable, Equatable {
    let posterUrl: String?
    let loopUrl: String?

    enum CodingKeys: String, CodingKey {
        case posterUrl = "poster_url"
        case loopUrl = "loop_url"
    }
}

struct FormatStyle: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let thumbUrl: String

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case thumbUrl = "thumb_url"
    }
}

struct FormatVoice: Codable, Equatable, Identifiable {
    let id: String
    let label: String
}

struct FormatDurationTier: Codable, Equatable {
    let seconds: Int
    let sceneCount: Int
    let credits: Int

    enum CodingKeys: String, CodingKey {
        case seconds
        case sceneCount = "scene_count"
        case credits
    }
}

struct FormatSheetMeta: Codable, Equatable {
    let description: String
    let preparingLabel: String

    enum CodingKeys: String, CodingKey {
        case description
        case preparingLabel = "preparing_label"
    }
}

struct FormatsResponse: Codable {
    let version: Int
    let formats: [Format]
}
