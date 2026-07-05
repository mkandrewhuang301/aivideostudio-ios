// APIClient.swift
// Fantasia

import Foundation
import FirebaseAuth

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
    private let baseURL = AppConfig.baseURL

    // Issue 6: fire-and-forget warm-up ping so a sleeping Railway instance is already awake by
    // the time the user submits sign-in credentials. No auth token, errors intentionally ignored.
    func pingHealth() async {
        _ = try? await session.data(from: baseURL.appendingPathComponent("health"))
    }

    // GET /rates — public endpoint, no auth token needed
    func fetchRates() async throws -> RatesResponse {
        let url = baseURL.appendingPathComponent("rates")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        return try JSONDecoder().decode(RatesResponse.self, from: data)
    }

    func healthCheck() async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    // Private: Gets fresh Firebase ID token. Auto-refreshes if within 5 min of expiry.
    private func getIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw APIError.notAuthenticated
        }
        return try await user.getIDToken()
    }

    // Public: Use this for all authenticated API calls.
    // Adds Authorization: Bearer {token} + Content-Type: application/json headers.
    func authorizedRequest<T: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> T {
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "no body"
            print("[APIClient] \(method) \(path) → HTTP \(status): \(body)")
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["code"]
            throw APIError.unexpectedResponse(statusCode: status, code: code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchMe() async throws -> MeResponse {
        return try await authorizedRequest(path: "api/me")
    }

    // Use for PATCH/POST endpoints that respond 204 No Content (no body to decode).
    func authorizedRequestNoContent(
        path: String,
        method: String = "PATCH",
        body: Data? = nil
    ) async throws {
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 204 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
    }

    func updateDeviceToken(_ token: String) async throws {
        let body = try JSONEncoder().encode(["deviceToken": token])
        try await authorizedRequestNoContent(path: "api/me/device-token", body: body)
    }

    func updatePreferences(_ preferences: [String: [String]]) async throws {
        let body = try JSONEncoder().encode(["preferences": preferences])
        try await authorizedRequestNoContent(path: "api/me/preferences", body: body)
    }

    // MARK: - Generation API

    // D-31: GET /api/generations with optional cursor parameter
    // Uses custom JSONDecoder with .iso8601 to decode createdAt/completedAt Date fields.
    func fetchGenerations(cursor: String? = nil, limit: Int = 50) async throws -> GenerationsResponse {
        // Query params must go through URLComponents — appendingPathComponent percent-encodes
        // "?" into the path (…/generations%3Flimit=50), which 404s on the backend. That 404
        // was swallowed upstream and rendered as an empty library after login.
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/generations"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let token = try await getIDToken()
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[APIClient] GET api/generations → HTTP \(status): \(String(data: data, encoding: .utf8) ?? "no body")")
            throw APIError.unexpectedResponse(statusCode: status, code: nil)
        }
        return try decoder.decode(GenerationsResponse.self, from: data)
    }

    // D-32: GET /api/generations/:id
    // Uses custom JSONDecoder with .iso8601 to decode createdAt/completedAt Date fields.
    func fetchGeneration(id: String) async throws -> GenerationItem {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generations/\(id)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        return try decoder.decode(GenerationItem.self, from: data)
    }

    // POST /api/generations — GEN-01, GEN-02, GEN-03
    func submitGeneration(body: GenerationRequestBody) async throws -> GenerationSubmitResponse {
        let bodyData = try JSONEncoder().encode(body)
        return try await authorizedRequest(path: "api/generations", method: "POST", body: bodyData)
    }

    // D-37: DELETE /api/generations/:id — soft-delete
    func deleteGeneration(id: String) async throws {
        try await authorizedRequestNoContent(path: "api/generations/\(id)", method: "DELETE")
    }

    // PATCH /api/generations/:id/favorite — FAV-01
    func setFavorite(id: String, isFavorite: Bool) async throws {
        let body = try JSONEncoder().encode(["is_favorite": isFavorite])
        try await authorizedRequestNoContent(path: "api/generations/\(id)/favorite", method: "PATCH", body: body)
    }

    // D-23, D-24: POST /api/uploads — multipart/form-data file upload
    // Returns UploadResponse.url (1-hour R2 presigned URL for use as reference_images[0] or reference_videos[0])
    // RESEARCH.md Pattern 9: manually construct multipart boundary (no Alamofire dependency needed)
    // GET /api/uploads — user's previously-uploaded reference media, newest first
    func fetchMyUploads() async throws -> [ReferenceUploadItem] {
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("[APIClient] fetchMyUploads HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data, encoding: .utf8) ?? "no body")")
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        print("[APIClient] fetchMyUploads raw: \(String(data: data, encoding: .utf8) ?? "nil")")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UploadsListResponse.self, from: data).uploads
    }

    func deleteUpload(id: String) async throws {
        try await authorizedRequestNoContent(path: "api/uploads/\(id)", method: "DELETE")
    }

    // PATCH /api/uploads/:id — set or clear display name. Empty string clears to nil.
    func renameUpload(id: String, displayName: String) async throws {
        let body = try JSONEncoder().encode(["display_name": displayName])
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads/\(id)"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
    }

    // POST /api/uploads/from-generation — promote a completed generation's output into the
    // permanent reference library (named, non-expiring) instead of the one-shot "Reference"
    // attach that only reuses the generation's short-lived presigned URL.
    func createReferenceFromGeneration(generationId: String, displayName: String) async throws -> UploadResponse {
        let body = try JSONEncoder().encode([
            "generation_id": generationId,
            "display_name": displayName,
        ])
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads/from-generation"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        return try JSONDecoder().decode(UploadResponse.self, from: responseData)
    }

    func uploadReferenceMedia(data: Data, mimeType: String, fileName: String) async throws -> UploadResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(data)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/uploads"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse(statusCode: -1, code: nil)
        }
        return try JSONDecoder().decode(UploadResponse.self, from: responseData)
    }
}

// GET /rates response — rates are in credits/sec, no dollar conversion needed client-side
struct RatesResponse: Decodable {
    let rates: [String: [String: [String: Double]]]
    let imageCosts: [String: Int]?   // flat credits per image model; optional for backward compat
    let grokImagineRate: Int?        // flat credits/sec for xai/grok-imagine-video-1.5; optional for backward compat
    // D-21/Pitfall 1: previously served but dropped by the client — DreamActor (Motion Transfer)
    // and video-upscaler (Enhancer) rates, both already on the cents scale server-side.
    let dreamactorRate: Double?      // flat credits/sec for bytedance/dreamactor-m2.0
    let upscalerRates: [String: [String: [String: Double]]]?  // [tier: [resolution: [fpsBand: credits/sec]]]

    enum CodingKeys: String, CodingKey {
        case rates
        case imageCosts = "imageCosts"
        case grokImagineRate = "grokImagineRate"
        case dreamactorRate = "dreamactorRate"
        case upscalerRates = "upscalerRates"
    }
}

struct HealthResponse: Decodable {
    let status: String
    let checks: [String: String]
}

// MeResponse — returned by GET /api/me (extended in Phase 3)
struct MeResponse: Decodable {
    let user: UserInfo
    let creditsBalance: Int
    let subscriptionAllotment: Int
    let activeTopupBalance: Int
    let entitlementLevel: String?

    enum CodingKeys: String, CodingKey {
        case user
        case creditsBalance = "credits_balance"
        case subscriptionAllotment = "subscription_allotment"
        case activeTopupBalance = "active_topup_balance"
        case entitlementLevel = "entitlement_level"
    }
}

struct UserInfo: Decodable {
    let uid: String
    let email: String?
    let dbUserId: String?
}

enum APIError: Error, LocalizedError {
    case unexpectedResponse(statusCode: Int, code: String?)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Unexpected server response"
        case .notAuthenticated:
            return "Not signed in"
        }
    }
}

// Generation submit response — returned by POST /api/generations
struct GenerationSubmitResponse: Decodable {
    let generationId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case generationId = "generation_id"
        case status
    }
}

// Upload response — returned by POST /api/uploads and POST /api/uploads/from-generation
struct UploadResponse: Decodable {
    let id: String?   // reference_uploads UUID — stored so remix/regen can restore the reference
    let url: String
    let mimeType: String?     // only set by /from-generation
    let displayName: String?  // only set by /from-generation

    enum CodingKeys: String, CodingKey {
        case id, url
        case mimeType = "mime_type"
        case displayName = "display_name"
    }
}

// A previously-uploaded reference file returned by GET /api/uploads
struct ReferenceUploadItem: Identifiable, Codable {
    let id: String
    let url: String
    let mimeType: String
    var displayName: String?   // user-assigned name; nil = unnamed → uses [ImageN]/[VideoN]

    var isVideo: Bool { mimeType.contains("video") }

    enum CodingKeys: String, CodingKey {
        case id, url
        case mimeType    = "mime_type"
        case displayName = "display_name"
    }
}

private struct UploadsListResponse: Decodable {
    let uploads: [ReferenceUploadItem]
}

// Generation request body — sent to POST /api/generations
// Video fields (duration/resolution/aspectRatio/audioEnabled) are optional so that image
// generation requests can omit them; imageAspectRatio is image-only.
struct GenerationRequestBody: Encodable {
    let prompt: String
    let model: String
    let mediaType: String?          // "video" | "image"; nil omits from JSON (backend defaults to video)
    let duration: Int?              // video-only; nil for image mode
    let resolution: String?         // video-only; nil for image mode
    let aspectRatio: String?        // video-only; nil for image mode
    let audioEnabled: Bool?         // video-only; nil for image mode
    let imageAspectRatio: String?   // image-only; nil for video mode
    let imageQuality: String?       // "high" | "standard"; GPT Image 2 only
    let referenceImages: [String]?
    let referenceVideos: [String]?
    let referenceUploadIds: [String]?   // reference_uploads UUIDs — stored server-side for remix/regen
    // Parallel arrays aligned by index to referenceImages/referenceVideos (id-or-null per entry).
    // Lets the backend re-sign each reference URL from its owning row right before dispatch,
    // since client-sent presigned URLs (1hr upload TTL / 24hr generation-output TTL) can be
    // stale by submit time. nil entries mean "no known id — keep the URL as sent."
    let referenceImageUploadIds: [String?]?
    let referenceVideoUploadIds: [String?]?
    let referenceImageGenerationIds: [String?]?
    let referenceVideoGenerationIds: [String?]?

    enum CodingKeys: String, CodingKey {
        case prompt, model
        case mediaType = "media_type"
        case duration, resolution
        case aspectRatio = "aspect_ratio"
        case audioEnabled = "audio_enabled"
        case imageAspectRatio = "image_aspect_ratio"
        case imageQuality = "image_quality"
        case referenceImages = "reference_images"
        case referenceVideos = "reference_videos"
        case referenceUploadIds = "reference_upload_ids"
        case referenceImageUploadIds = "reference_image_upload_ids"
        case referenceVideoUploadIds = "reference_video_upload_ids"
        case referenceImageGenerationIds = "reference_image_generation_ids"
        case referenceVideoGenerationIds = "reference_video_generation_ids"
    }
}
