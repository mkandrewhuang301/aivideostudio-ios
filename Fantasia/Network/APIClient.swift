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
