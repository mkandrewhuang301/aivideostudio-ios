// GenerationItem.swift
// Fantasia
// Domain model types for the generation lifecycle.
// Maps to backend generations table (aivideostudio-backend/src/db/schema.ts).
// Used by GenerationManager, FeedView, LibraryView, GenerationCardView.

import Foundation

// Maps to backend generation_status enum values (including 'deleted' added in Plan 01)
enum GenerationStatus: String, Codable, Equatable {
    case pending
    case processing
    case completed
    case failed
    case quarantined
    case refunded
    case deleted
}

// Distinguishes image generations from video generations.
// Encoded as "video" | "image" in backend JSON field `media_type`.
enum MediaType: String, Codable, Equatable {
    case video
    case image
}

// A reference media item attached to a generation (image or video)
struct GenerationReference: Codable, Equatable {
    let url: String
    let isVideo: Bool
}

// Maps to backend params JSONB column — camelCase Swift, snake_case CodingKeys
// All video-specific fields are optional so image generation rows (which have no
// duration/resolution/aspectRatio/audio) decode without error.
struct GenerationParams: Codable, Equatable {
    let resolution: String?     // "480p" | "720p"; nil for image generations
    let duration: Int?          // seconds; nil for image generations
    let aspectRatio: String?    // "16:9" | "9:16" | "1:1" | "4:3"; nil for image generations
    let audioEnabled: Bool?     // nil for image generations
    let hasReference: Bool?     // optional — older generations won't have this
    let width: Int?             // image-only: e.g. 1024
    let height: Int?            // image-only: e.g. 1024
    // D-11/T-09.1-03: stamped by the backend presetResolver (09.1-07) onto preset-run rows only.
    // Default `= nil` so every existing call site constructing GenerationParams (freeform
    // generations, PresetInputSheet's own placeholder) keeps compiling unchanged.
    let presetId: String?                    // registry preset id — nil for freeform generations
    // Stored slot upload ids — Remix reopens PresetInputSheet prefilled from these. Index-aligned
    // to the preset's input_schema.slots; `nil` entries are empty OPTIONAL slots (09.1-11 Clothes
    // Swap). MUST stay `[String?]` (not `[String]`) — a `null` JSON element would otherwise throw
    // a decoding error for the entire GenerationItem.
    let presetInputUploadIds: [String?]?

    enum CodingKeys: String, CodingKey {
        case resolution
        case duration
        case aspectRatio = "aspect_ratio"
        case audioEnabled = "audio_enabled"
        case hasReference = "has_reference"
        case width
        case height
        case presetId = "preset_id"
        case presetInputUploadIds = "preset_input_upload_ids"
    }

    init(
        resolution: String?,
        duration: Int?,
        aspectRatio: String?,
        audioEnabled: Bool?,
        hasReference: Bool?,
        width: Int?,
        height: Int?,
        presetId: String? = nil,
        presetInputUploadIds: [String?]? = nil
    ) {
        self.resolution = resolution
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.audioEnabled = audioEnabled
        self.hasReference = hasReference
        self.width = width
        self.height = height
        self.presetId = presetId
        self.presetInputUploadIds = presetInputUploadIds
    }
}

// Primary model — one generation row from GET /api/generations or GET /api/generations/:id
struct GenerationItem: Codable, Identifiable, Equatable {
    let id: String
    let model: String            // "bytedance/seedance-2.0-fast" | "bytedance/seedance-2.0-mini"
    let status: GenerationStatus
    let mediaType: MediaType     // .video | .image; defaults to .video when field absent in JSON
    let prompt: String?
    let params: GenerationParams
    let costCredits: Int
    let videoUrl: String?        // presigned R2 URL for the completed media (video or image)
    let referenceUrls: [GenerationReference]?  // presigned URLs for reference media (remix/regen)
    let createdAt: Date
    let completedAt: Date?
    let failureReason: String?   // 'content_policy' | 'copyright' | 'generic_error' | nil (legacy rows)
    var isFavorite: Bool         // FAV-01: the one mutable field — flipped in place by GenerationManager for optimistic UI

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case status
        case mediaType = "media_type"
        case prompt
        case params
        case costCredits = "cost_credits"
        case videoUrl = "video_url"
        case referenceUrls = "reference_urls"
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case failureReason = "failure_reason"
        case isFavorite = "is_favorite"
    }

    // Custom init: decodes mediaType with a .video fallback for existing rows that have no
    // media_type column (pre-08-01 rows) or have media_type = 'video'.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // model is null for preset rows (backend hides the underlying model — D-G, 09.2-13). Decode
        // defensively so a null never throws and kills the WHOLE list fetch (that froze the feed:
        // no completion updates, no delete reconciliation). Empty string is a safe default — the
        // only readers are `.contains("mini"/"grok")` checks, which correctly yield false.
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? ""
        status = try container.decode(GenerationStatus.self, forKey: .status)
        mediaType = (try? container.decode(MediaType.self, forKey: .mediaType)) ?? .video
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        params = try container.decode(GenerationParams.self, forKey: .params)
        costCredits = try container.decode(Int.self, forKey: .costCredits)
        videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
        referenceUrls = try container.decodeIfPresent([GenerationReference].self, forKey: .referenceUrls)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        isFavorite = (try? container.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? false
    }

    /// Builds a client-only placeholder row for optimistic submit — shown instantly while the
    /// real POST /api/generations round trip is still in flight, then replaced once the
    /// authoritative row lands via the next fetch (see GenerationManager.mergeLatest).
    init(
        localPlaceholderId id: String,
        model: String,
        mediaType: MediaType,
        prompt: String?,
        params: GenerationParams,
        costCredits: Int,
        referenceUrls: [GenerationReference]?,
        createdAt: Date
    ) {
        self.id = id
        self.model = model
        self.status = .pending
        self.mediaType = mediaType
        self.prompt = prompt
        self.params = params
        self.costCredits = costCredits
        self.videoUrl = nil
        self.referenceUrls = referenceUrls
        self.createdAt = createdAt
        self.completedAt = nil
        self.failureReason = nil
        self.isFavorite = false
    }

    /// True when this item is an unconfirmed optimistic row inserted by dispatchGeneration(),
    /// not yet backed by a real server row.
    var isLocalPlaceholder: Bool { id.hasPrefix("local-") }

    /// True when this item is an image generation (not a video).
    var isImage: Bool { mediaType == .image }

    /// True when this generation was created from a preset (registry `preset_id` stamped by the
    /// backend presetResolver). Gates prompt-row suppression on the feed card/detail sheet and
    /// forks Remix to reopen PresetInputSheet instead of the composer (D-11/T-09.1-03).
    var isPreset: Bool { params.presetId != nil }

    /// The presigned R2 URL for the completed media (video or image).
    /// Backend returns image URLs under the `video_url` key to avoid a breaking API change.
    var completedMediaUrl: String? { videoUrl }

    /// Shared failure copy — used by both GenerationCardView (card) and GenerationDetailSheet
    /// (detail sheet) so the two surfaces never drift out of sync with each other.
    var failureMessage: String? {
        guard status == .failed else { return nil }
        switch failureReason {
        case "content_policy":
            return "Your prompt may not adhere to our community guidelines. Your credits have been refunded."
        case "copyright":
            return "This prompt may reference copyrighted characters or real people. Credits refunded."
        case "provider_error":
            return "The video service hit a temporary problem. Your credits have been refunded — please try again."
        default:
            return "An error has occurred. Your credits have been refunded."
        }
    }
}

// Paginated list response from GET /api/generations
struct GenerationsResponse: Decodable {
    let items: [GenerationItem]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "nextCursor"  // backend uses camelCase here
    }
}
