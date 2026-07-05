// Preset.swift
// Fantasia
// Codable models for the server-driven preset registry (GET /api/presets).
// Mirrors the backend registry row schema exactly (RESEARCH.md Pattern 1). Per D-11, the
// server-side-only expanded template string is never serialized in this response, so
// intentionally no such field exists on this model at all.

import Foundation

// A single registry row — one Home tile (live preset or "soon" placeholder).
struct Preset: Codable, Identifiable, Equatable {
    let presetId: String
    let title: String
    let subtitle: String?
    let section: String            // "hero" | "photo_tools" | "effects" | "avatar_center" | "shows_vlogs"
    let sortOrder: Int
    let status: String             // "live" | "soon"
    let badge: String?             // "NEW" | "HOT"
    let tile: PresetTile
    // Only populated for status == "live":
    let mediaType: String?         // "video" | "image" | "avatar" | "upscale"
    let model: String?
    let inputSchema: PresetInputSchema?
    let cost: PresetCost?

    var id: String { presetId }

    enum CodingKeys: String, CodingKey {
        case presetId = "preset_id"
        case title
        case subtitle
        case section
        case sortOrder = "sort_order"
        case status
        case badge
        case tile
        case mediaType = "media_type"
        case model
        case inputSchema = "input_schema"
        case cost
    }

    /// True when this tile is a not-yet-shipped destination/preset (registry-driven SOON state, D-04).
    var isSoon: Bool { status == "soon" }
}

// Stable art URLs for a tile — poster shown immediately, loop fades in once cached (D-08).
struct PresetTile: Codable, Equatable {
    let posterUrlString: String
    let loopUrlString: String
    let aspect: String?

    enum CodingKeys: String, CodingKey {
        case posterUrlString = "poster_url"
        case loopUrlString = "loop_url"
        case aspect
    }

    var posterURL: URL? { URL(string: posterUrlString) }
    var loopURL: URL? { URL(string: loopUrlString) }
}

// Schema-driven PresetInputSheet input description (D-10).
struct PresetInputSchema: Codable, Equatable {
    let slots: [PresetSlot]
    let text: PresetText?
    let styleGrid: [PresetStyle]?

    enum CodingKeys: String, CodingKey {
        case slots
        case text
        case styleGrid = "style_grid"
    }
}

// One media input slot (e.g. "person photo", "garment photo", "driving video").
struct PresetSlot: Codable, Equatable {
    let kind: String     // "image" | "video"
    let label: String
    let source: String   // "any" | "my_look_default"
}

// Optional free-text field alongside the media slots.
struct PresetText: Codable, Equatable {
    let label: String
    let required: Bool
}

// One entry in an optional style grid (e.g. Hairstyle's named styles).
struct PresetStyle: Codable, Equatable {
    let id: String
    let label: String
    let thumbUrlString: String?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case thumbUrlString = "thumb_url"
    }

    var thumbURL: URL? {
        guard let thumbUrlString else { return nil }
        return URL(string: thumbUrlString)
    }
}

// Discriminated union: {type:'flat', credits} | {type:'per_second', credits_per_sec, max_seconds?}
enum PresetCost: Codable, Equatable {
    case flat(credits: Int)
    case perSecond(creditsPerSec: Double, maxSeconds: Int?)

    private enum CodingKeys: String, CodingKey {
        case type
        case credits
        case creditsPerSec = "credits_per_sec"
        case maxSeconds = "max_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "flat":
            let credits = try container.decode(Int.self, forKey: .credits)
            self = .flat(credits: credits)
        case "per_second":
            let creditsPerSec = try container.decode(Double.self, forKey: .creditsPerSec)
            let maxSeconds = try container.decodeIfPresent(Int.self, forKey: .maxSeconds)
            self = .perSecond(creditsPerSec: creditsPerSec, maxSeconds: maxSeconds)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown preset cost type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flat(let credits):
            try container.encode("flat", forKey: .type)
            try container.encode(credits, forKey: .credits)
        case .perSecond(let creditsPerSec, let maxSeconds):
            try container.encode("per_second", forKey: .type)
            try container.encode(creditsPerSec, forKey: .creditsPerSec)
            try container.encodeIfPresent(maxSeconds, forKey: .maxSeconds)
        }
    }

    /// Flat display credits for `.flat` presets. Returns nil for `.perSecond` — callers must
    /// compute from the picked media's real duration (e.g. Motion Transfer, D-18).
    var flatCredits: Int? {
        if case .flat(let credits) = self { return credits }
        return nil
    }
}

// Top-level GET /api/presets response envelope.
struct PresetsResponse: Codable {
    let version: Int?
    let presets: [Preset]
}
