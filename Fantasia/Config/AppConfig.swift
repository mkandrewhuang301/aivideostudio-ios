// AppConfig.swift
// Fantasia

import Foundation

enum AppConfig {
    // Update STAGING_BASE_URL after Railway deploy in plan 01-04
    static let baseURL: URL = {
        let urlString = ProcessInfo.processInfo.environment["API_BASE_URL"]
            ?? "https://aivideostudio-backend-production.up.railway.app"
        guard let url = URL(string: urlString) else {
            fatalError("Invalid API_BASE_URL: \(urlString)")
        }
        return url
    }()

    static let bundleId = "com.fantasia.app"
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1"
}
