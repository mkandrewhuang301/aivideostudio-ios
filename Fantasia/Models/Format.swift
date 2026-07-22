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
    let flow: String?
    let tile: FormatTile
    let styleGrid: [FormatStyle]
    let voices: [FormatVoice]
    let voiceDefault: String
    let musicMoods: [String]
    let durationTiers: [FormatDurationTier]
    let aspectRatios: [String]
    let outputDurations: [Int]
    let pricing: FormatPricing?
    let sheet: FormatSheetMeta
    // Language Lessons fields (client-safe only — voice ids, anchor keys, and prompts are
    // server-only and never serialized). Empty on rows that don't ship them (Explainer, SOON).
    let templates: [FormatTemplate]
    let teachers: [FormatTeacher]
    let languages: [FormatLanguage]

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
        case flow
        case tile
        case styleGrid = "style_grid"
        case voices
        case voiceDefault = "voice_default"
        case musicMoods = "music_moods"
        case durationTiers = "duration_tiers"
        case aspectRatios = "aspect_ratios"
        case outputDurations = "output_durations"
        case pricing
        case sheet
        case templates
        case teachers
        case languages
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
        flow = try container.decodeIfPresent(String.self, forKey: .flow)
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
        outputDurations = try container.decodeIfPresent([Int].self, forKey: .outputDurations) ?? []
        pricing = try container.decodeIfPresent(FormatPricing.self, forKey: .pricing)
        sheet = try container.decodeIfPresent(FormatSheetMeta.self, forKey: .sheet)
            ?? FormatSheetMeta(description: subtitle ?? "", preparingLabel: "")
        templates = try container.decodeIfPresent([FormatTemplate].self, forKey: .templates) ?? []
        teachers = try container.decodeIfPresent([FormatTeacher].self, forKey: .teachers) ?? []
        languages = try container.decodeIfPresent([FormatLanguage].self, forKey: .languages) ?? []
    }
}

struct FormatPricing: Codable, Equatable {
    let sourceMinuteCredits: Int
    let outputSecondCredits: Int
    let minimumCredits: Int

    enum CodingKeys: String, CodingKey {
        case sourceMinuteCredits = "source_minute_credits"
        case outputSecondCredits = "output_second_credits"
        case minimumCredits = "minimum_credits"
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

/// A Language Lessons visual template (Teacher / Cartoon / Mini Drama). `castLabel` drives the
/// cast slot's caption ("Teacher" vs "Characters"); `artStyles` is the per-template look picker
/// (Cartoon's Doodle/Storybook/Anime/Paper — D-4) and stays empty on templates without one.
struct FormatTemplate: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let blurb: String?
    let thumbUrl: String?
    let castLabel: String
    let artStyles: [FormatStyle]

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case blurb
        case thumbUrl = "thumb_url"
        case castLabel = "cast_label"
        case artStyles = "art_styles"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        blurb = try container.decodeIfPresent(String.self, forKey: .blurb)
        thumbUrl = try container.decodeIfPresent(String.self, forKey: .thumbUrl)
        castLabel = try container.decodeIfPresent(String.self, forKey: .castLabel) ?? "Teacher"
        artStyles = try container.decodeIfPresent([FormatStyle].self, forKey: .artStyles) ?? []
    }
}

/// A curated teacher character. Client-safe shape only: the Gemini `voice_id` and anchor R2 key
/// are server-only (stripped in CLIENT_FORMATS per D-3) — the client sees a display label and an
/// optional short sample clip for the ▶ preview.
struct FormatTeacher: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let artUrl: String?
    let voiceLabel: String
    let voiceSampleUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artUrl = "art_url"
        case voiceLabel = "voice_label"
        case voiceSampleUrl = "voice_sample_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artUrl = try container.decodeIfPresent(String.self, forKey: .artUrl)
        voiceLabel = try container.decodeIfPresent(String.self, forKey: .voiceLabel) ?? ""
        voiceSampleUrl = try container.decodeIfPresent(String.self, forKey: .voiceSampleUrl)
    }
}

/// A selectable language for the Learning / I speak pair. `id` is a BCP-47-ish code the server
/// resolves (`en`, `es`, `zh-Hans`, …).
struct FormatLanguage: Codable, Equatable, Identifiable {
    let id: String
    let label: String
}

struct FormatsResponse: Codable {
    let version: Int
    let formats: [Format]
}
