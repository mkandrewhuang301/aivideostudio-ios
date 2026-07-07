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
    let section: String            // "hero" | "video_effects" | "photo_effects" | "avatar_center" | "shows_vlogs"
    let sortOrder: Int
    let status: String             // "live" | "soon"
    let badge: String?             // "NEW" | "HOT"
    let tile: PresetTile
    // Only populated for status == "live":
    let mediaType: String?         // "video" | "image" | "avatar" | "upscale"
    let model: String?
    let inputSchema: PresetInputSchema?
    let cost: PresetCost?
    // Preset Sheet Redesign: server-driven copy/options for PresetInputSheet — optional, nil for
    // SOON rows and any preset that hasn't been given sheet copy yet.
    let sheet: PresetSheetMeta?

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
        case sheet
    }

    /// True when this tile is a not-yet-shipped destination/preset (registry-driven SOON state, D-04).
    var isSoon: Bool { status == "soon" }
}

// Server-driven copy/options for the redesigned PresetInputSheet (Higgsfield-style layout).
// Mirrors backend PresetSheetMeta exactly. Every field is optional: a preset declares EITHER
// `aspectRatios` (+ `defaultAspectRatio`) for a selectable chip row, OR `aspectLabel` (+ optional
// `durationLabel`/`resolutionLabel`) for a fixed caption row — never both.
struct PresetSheetMeta: Codable, Equatable {
    let description: String?
    let aspectRatios: [String]?
    let defaultAspectRatio: String?
    let aspectLabel: String?
    let durationLabel: String?
    let resolutionLabel: String?

    enum CodingKeys: String, CodingKey {
        case description
        case aspectRatios = "aspect_ratios"
        case defaultAspectRatio = "default_aspect_ratio"
        case aspectLabel = "aspect_label"
        case durationLabel = "duration_label"
        case resolutionLabel = "resolution_label"
    }
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
    // 09.1-11/12 (Clothes Swap): absent/false = required (default, preserves every pre-existing
    // preset's all-required behavior). true = this slot may be submitted empty — see
    // PresetInputSheet.isValid / generate().
    let optional: Bool

    enum CodingKeys: String, CodingKey {
        case kind, label, source, optional
    }

    init(kind: String, label: String, source: String, optional: Bool = false) {
        self.kind = kind
        self.label = label
        self.source = source
        self.optional = optional
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        source = try container.decode(String.self, forKey: .source)
        optional = try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
    }
}

// Optional free-text field alongside the media slots.
struct PresetText: Codable, Equatable {
    let label: String
    let required: Bool
}

// Client-side filter only (PresetInputSheet's "Feminine / Masculine / All" chip) — never
// affects generation. Unrecognized/missing values decode to nil so a style with no tag
// (or a future tag value) just never gets filtered out.
enum PresetStyleGenderTag: String, Codable, Equatable {
    case feminine
    case masculine
    case unisex
}

// One entry in an optional style grid (e.g. Hairstyle's named styles).
struct PresetStyle: Codable, Equatable {
    let id: String
    let label: String
    let thumbUrlString: String?
    let genderTag: PresetStyleGenderTag?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case thumbUrlString = "thumb_url"
        case genderTag = "gender_tag"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        thumbUrlString = try container.decodeIfPresent(String.self, forKey: .thumbUrlString)
        genderTag = try? container.decodeIfPresent(PresetStyleGenderTag.self, forKey: .genderTag)
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
