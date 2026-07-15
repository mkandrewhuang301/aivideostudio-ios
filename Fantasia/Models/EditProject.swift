// EditProject.swift
// Fantasia
// Codable DTOs for Phase 13 (Edit Studio), mirroring the backend project state shape —
// aivideostudio-backend src/routes/projects.ts + src/services/projectService.ts
// (FullProjectState / Project / ProjectClip / ProjectTextOverlay / ProjectAudioClip /
// ProjectCaptionCue / ProjectCaptionWord — read directly from the live backend, 2026-07-14).
//
// Backend snake_case columns decode into camelCase Swift properties via CodingKeys, matching
// the established GenerationItem.swift convention. `url` fields are always fresh 1h presigned
// R2 URLs generated server-side at query time — never a raw key (CLAUDE.md Rule 2).

import Foundation

// One global caption style for the whole project (SC5) — {fontSize, color, highlightColor,
// position}. Stored as an opaque `caption_style` jsonb column, round-tripped verbatim by the
// backend (PATCH /api/projects/:id just stores whatever object the client sends) — so, unlike
// every table-backed struct below, these JSON keys are ALREADY camelCase, not snake_case.
struct CaptionStyle: Codable, Equatable {
    var fontSize: Double
    var color: String
    var highlightColor: String
    var position: String   // "top" | "middle" | "bottom" — server-validated against this fixed enum

    enum CodingKeys: String, CodingKey {
        case fontSize, color, highlightColor, position
    }
}

struct CaptionWord: Codable, Identifiable, Equatable {
    // Optional: a word the editor is about to submit (e.g. from a caption-cue edit sheet) has no
    // server id yet. Words that came back from a GET/POST/PATCH response always have one.
    var id: String?
    var text: String
    var startSeconds: Double
    var endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct CaptionCue: Codable, Identifiable, Equatable {
    let id: String
    var sortOrder: Int
    var startSeconds: Double
    var endSeconds: Double
    var words: [CaptionWord]

    enum CodingKeys: String, CodingKey {
        case id
        case sortOrder = "sort_order"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case words
    }
}

// NOTE on `url`: GET /api/projects/:id (getProjectWithState) always returns a fresh presigned
// `url` here. The clip-mutation endpoints (POST/PATCH /api/projects/:id/clips[/:clipId]) return
// the RAW `project_clips` row instead (no `url` key present — see projectService.ts
// importClipByCopy/route PATCH handler, which `.returning()` the bare DB row). `url` is therefore
// optional and nil after a mutation; ProjectManager re-fetches the full project (GET /:id) after
// any clip mutation to obtain a fresh playable url rather than trusting a mutation response for
// playback (see also T-13-22/Pitfall 3 — presigned URLs expire mid-session either way). This
// struct has no `r2Key` property at all, so even though those mutation endpoints happen to
// include a raw `r2_key` field in their JSON, this client model never captures or surfaces it —
// see 13-08-SUMMARY.md Threat Flags for this backend-side information-disclosure gap.
struct ProjectClip: Codable, Identifiable, Equatable {
    let id: String
    var sortOrder: Int
    var url: String?
    var mediaType: String   // "video" | "image"
    var trimStartSeconds: Double
    var trimEndSeconds: Double?
    var originalDurationSeconds: Double?
    // Plan 13-22 B1: pixel dimensions probed server-side (rotation-corrected), nullable — powers
    // the "Original" canvas aspect ratio (EditorView.aspectFraction resolves it from clips[0]).
    var width: Int?
    var height: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case sortOrder = "sort_order"
        case url
        case mediaType = "media_type"
        case trimStartSeconds = "trim_start_seconds"
        case trimEndSeconds = "trim_end_seconds"
        case originalDurationSeconds = "original_duration_seconds"
        case width
        case height
    }
}

struct TextOverlay: Codable, Identifiable, Equatable {
    let id: String
    var text: String
    var xNorm: Double
    var yNorm: Double
    var widthNorm: Double?
    // Degrees, CLOCKWISE-positive (matches SwiftUI .rotationEffect) — 13-19 Task G3/H. Defaults to
    // 0 when absent so decoding a pre-migration row (or a slim mutation response) never crashes.
    var rotation: Double
    var startSeconds: Double
    var endSeconds: Double

    enum CodingKeys: String, CodingKey {
        case id, text
        case xNorm = "x_norm"
        case yNorm = "y_norm"
        case widthNorm = "width_norm"
        case rotation
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        xNorm = try container.decode(Double.self, forKey: .xNorm)
        yNorm = try container.decode(Double.self, forKey: .yNorm)
        widthNorm = try container.decodeIfPresent(Double.self, forKey: .widthNorm)
        rotation = (try? container.decodeIfPresent(Double.self, forKey: .rotation)) ?? 0
        startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        endSeconds = try container.decode(Double.self, forKey: .endSeconds)
    }

    init(
        id: String,
        text: String,
        xNorm: Double,
        yNorm: Double,
        widthNorm: Double? = nil,
        rotation: Double = 0,
        startSeconds: Double,
        endSeconds: Double
    ) {
        self.id = id
        self.text = text
        self.xNorm = xNorm
        self.yNorm = yNorm
        self.widthNorm = widthNorm
        self.rotation = rotation
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

// NOTE on `url`: same gap as ProjectClip.url above — POST/PATCH /api/projects/:id/audio[/:audioId]
// return the raw `project_audio_clips` row (no `url`), only GET /api/projects/:id resolves a
// fresh presigned url. Optional for the same reason; no `r2Key` property exists on this model.
struct AudioClip: Codable, Identifiable, Equatable {
    let id: String
    var url: String?
    var sourceType: String  // "upload" | "preset" | "narration"
    var startOffsetSeconds: Double
    var trimStartSeconds: Double
    var trimEndSeconds: Double?
    // Plan 13-21 B2/F9: probed via ffprobe at add-time (backend mediaProbe.probeDurationSeconds),
    // nil for rows added before that fix (self-heals server-side on next GET). This is the
    // fallback ProjectManager.splitAudioClip uses when trimEndSeconds has never been explicitly
    // set — the root cause of "audio split silently does nothing" was that fallback not existing
    // at all (the ONLY guard was trimEndSeconds, always nil for untrimmed audio).
    var originalDurationSeconds: Double?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, url
        case sourceType = "source_type"
        case startOffsetSeconds = "start_offset_seconds"
        case trimStartSeconds = "trim_start_seconds"
        case trimEndSeconds = "trim_end_seconds"
        case originalDurationSeconds = "original_duration_seconds"
        case sortOrder = "sort_order"
    }
}

// Project hub list row (GET /api/projects) — a lightweight summary, not full editable state.
struct ProjectSummary: Codable, Identifiable, Equatable {
    let id: String
    var title: String?
    var thumbnailUrl: String?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case thumbnailUrl = "thumbnail_url"
        case updatedAt = "updated_at"
    }
}

// Full editable project state — GET /api/projects/:id response, and (a SLIMMER version of)
// POST /api/projects's and PATCH /api/projects/:id's responses.
//
// NOTE: POST /api/projects (createProject) and PATCH /api/projects/:id (updateProject) both
// intentionally return just the raw `projects` row (id/title/aspect_ratio/caption_style/
// timestamps) — NOT the full clips/textOverlays/audioClips/captionCues arrays, and NOT a
// presigned thumbnail_url (only a raw thumbnail_r2_key, which this model has no property for and
// therefore silently ignores). See projectService.ts `createProject()`/`updateProject()`, which
// are distinct functions from `getProjectWithState()` (the only one that resolves child rows +
// presigned URLs). Decoding that slimmer response into this same EditProject type must not crash
// or silently wipe already-loaded editor state, so every array defaults to `[]` and thumbnailUrl
// defaults to `nil` when absent — mirrors the defensive decodeIfPresent pattern GenerationItem
// already uses for the same reason (multiple backend endpoints sharing one decode target with
// different response completeness). ProjectManager only ever pulls the specific changed field
// (title/aspectRatio/captionStyle) out of a decoded value like this and merges it into
// `loadedProject` in place — it never replaces the whole `loadedProject` with a create/update
// response, so this fallback never loses already-loaded clips/text/audio/caption state.
struct EditProject: Codable, Identifiable, Equatable {
    let id: String
    var title: String?
    var aspectRatio: String
    var thumbnailUrl: String?
    var captionStyle: CaptionStyle?
    var clips: [ProjectClip]
    var textOverlays: [TextOverlay]
    var audioClips: [AudioClip]
    var captionCues: [CaptionCue]
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case aspectRatio = "aspect_ratio"
        case thumbnailUrl = "thumbnail_url"
        case captionStyle = "caption_style"
        case clips
        case textOverlays = "text_overlays"
        case audioClips = "audio_clips"
        case captionCues = "caption_cues"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        aspectRatio = try container.decode(String.self, forKey: .aspectRatio)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        captionStyle = try container.decodeIfPresent(CaptionStyle.self, forKey: .captionStyle)
        clips = (try? container.decodeIfPresent([ProjectClip].self, forKey: .clips)) ?? []
        textOverlays = (try? container.decodeIfPresent([TextOverlay].self, forKey: .textOverlays)) ?? []
        audioClips = (try? container.decodeIfPresent([AudioClip].self, forKey: .audioClips)) ?? []
        captionCues = (try? container.decodeIfPresent([CaptionCue].self, forKey: .captionCues)) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
