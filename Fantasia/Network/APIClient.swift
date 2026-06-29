// APIClient.swift
// Fantasia

import Foundation
import FirebaseAuth

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession = .shared
    private let baseURL = AppConfig.baseURL

    func healthCheck() async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse
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
            throw APIError.unexpectedResponse
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
            throw APIError.unexpectedResponse
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
    func fetchGenerations(cursor: String? = nil) async throws -> GenerationsResponse {
        var path = "api/generations"
        if let cursor, let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?cursor=\(encoded)"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let token = try await getIDToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.unexpectedResponse
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
            throw APIError.unexpectedResponse
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
    case unexpectedResponse
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

// Upload response — returned by POST /api/uploads (1-hour R2 presigned URL)
struct UploadResponse: Decodable {
    let url: String
}

// Generation request body — sent to POST /api/generations (GEN-01, GEN-02, GEN-03)
struct GenerationRequestBody: Encodable {
    let prompt: String
    let model: String
    let duration: Int
    let resolution: String
    let aspectRatio: String
    let audioEnabled: Bool
    let referenceImages: [String]?
    let referenceVideos: [String]?

    enum CodingKeys: String, CodingKey {
        case prompt, model, duration, resolution
        case aspectRatio = "aspect_ratio"
        case audioEnabled = "audio_enabled"
        case referenceImages = "reference_images"
        case referenceVideos = "reference_videos"
    }
}
