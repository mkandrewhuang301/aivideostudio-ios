// APIClient.swift
// Fantasia

import Foundation

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
}

struct HealthResponse: Decodable {
    let status: String
    let checks: [String: String]
}

enum APIError: Error, LocalizedError {
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "Unexpected server response"
        }
    }
}
