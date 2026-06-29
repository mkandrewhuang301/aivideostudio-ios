// GenerationItem.swift
// Fantasia
// Domain model types for the generation lifecycle.
// Maps to backend generations table (aivideostudio-backend/src/db/schema.ts).
// Used by GenerationManager, FeedView, LibraryView, GenerationCardView.

import Foundation

// Maps to backend generation_status enum values (including 'deleted' added in Plan 01)
enum GenerationStatus: String, Decodable, Equatable {
    case pending
    case processing
    case completed
    case failed
    case quarantined
    case refunded
    case deleted
}

// Maps to backend params JSONB column — camelCase Swift, snake_case CodingKeys
struct GenerationParams: Decodable, Equatable {
    let resolution: String       // "480p" | "720p"
    let duration: Int            // seconds
    let aspectRatio: String      // "16:9" | "9:16" | "1:1" | "4:3"
    let audioEnabled: Bool
    let hasReference: Bool?      // optional — older generations won't have this

    enum CodingKeys: String, CodingKey {
        case resolution
        case duration
        case aspectRatio = "aspect_ratio"
        case audioEnabled = "audio_enabled"
        case hasReference = "has_reference"
    }
}

// Primary model — one generation row from GET /api/generations or GET /api/generations/:id
struct GenerationItem: Decodable, Identifiable, Equatable {
    let id: String
    let model: String            // "bytedance/seedance-2.0-fast" | "bytedance/seedance-2.0-mini"
    let status: GenerationStatus
    let prompt: String?
    let params: GenerationParams
    let costCredits: Int
    let videoUrl: String?        // presigned R2 URL, only present when status == .completed
    let createdAt: Date
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case status
        case prompt
        case params
        case costCredits = "cost_credits"
        case videoUrl = "video_url"
        case createdAt = "created_at"
        case completedAt = "completed_at"
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
