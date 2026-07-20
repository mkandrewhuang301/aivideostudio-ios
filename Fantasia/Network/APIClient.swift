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

    // PATCH /api/me/consent — SC2: records first-use face-input consent attestation (204, no body)
    func updateConsent() async throws {
        try await authorizedRequestNoContent(path: "api/me/consent", method: "PATCH")
    }

    // DELETE /api/me — 401 is idempotent success: the server may have committed deletion and
    // removed the Firebase user before a prior 204 response reached the client.
    func deleteAccount() async throws {
        let token = try await getIDToken()
        let path = "api/me"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 204 || status == 401 else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["code"]
            throw APIError.unexpectedResponse(statusCode: status, code: code)
        }
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
        try await submitGenerationBody(body)
    }

    // POST /api/generations/:id/translate — source media is resolved server-side from the owned
    // completed generation. The app sends only the exact provider-enum language value.
    func translateVideo(id: String, outputLanguage: String) async throws -> GenerationSubmitResponse {
        let body = try JSONEncoder().encode(VideoTranslationRequestBody(outputLanguage: outputLanguage))
        return try await authorizedRequest(
            path: "api/generations/\(id)/translate",
            method: "POST",
            body: body
        )
    }

    // POST /api/generations — server-resolved Formats path. The body contains only user choices;
    // formatResolver owns provider routing and authoritative duration-tier billing.
    func submitFormatGeneration(
        formatId: String,
        styleId: String,
        prompt: String,
        durationSeconds: Int,
        voiceId: String,
        music: String,
        aspectRatio: String?,
        attachmentIds: [String] = [],
        sourceUrl: String? = nil
    ) async throws -> GenerationSubmitResponse {
        let trimmedSourceURL = sourceUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = FormatGenerationRequestBody(
            formatId: formatId,
            styleId: styleId,
            prompt: prompt,
            durationSeconds: durationSeconds,
            voiceId: voiceId,
            music: music,
            aspectRatio: aspectRatio,
            attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds,
            sourceUrl: trimmedSourceURL?.isEmpty == false ? trimmedSourceURL : nil
        )
        return try await submitGenerationBody(body)
    }

    private func submitGenerationBody<Body: Encodable>(_ body: Body) async throws -> GenerationSubmitResponse {
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

    // MARK: - Edit Studio: Project API (Phase 13, Plan 08)
    // Every endpoint here mirrors aivideostudio-backend/src/routes/projects.ts, read directly
    // 2026-07-14. Paths are built as plain interpolated strings (memory: appendingPathComponent
    // percent-encodes '?', so this file avoids it entirely for the new project methods —
    // query params, where needed, go through URLComponents exactly like fetchGenerations does).

    // Builds "\(baseURL)/\(path)" without appendingPathComponent.
    private func projectURL(_ path: String) -> URL {
        URL(string: "\(baseURL.absoluteString)/\(path)")!
    }

    // Shared JSON request/decode helper for every project endpoint below. Uses an .iso8601
    // JSONDecoder (unlike the generic authorizedRequest<T>) since EditProject/ProjectSummary
    // carry created_at/updated_at Date fields. expectedStatus lets callers accept 200/201/202 —
    // the generic authorizedRequest only ever accepts 200, which doesn't fit these routes'
    // 201 (create) / 202 (export) responses. On an unexpected status, the backend's
    // `{ error: "..." }` body (this router's convention, distinct from other routes' `{ code }`)
    // is parsed into a typed APIError so callers never crash-decode an error body as a DTO.
    private func projectRequest<T: Decodable>(
        path: String,
        method: String,
        body: Data? = nil,
        expectedStatus: Set<Int> = [200]
    ) async throws -> T {
        let token = try await getIDToken()
        var request = URLRequest(url: projectURL(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, expectedStatus.contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
            print("[APIClient] \(method) \(path) → HTTP \(status): \(bodyStr)")
            let errorMessage = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.unexpectedResponse(statusCode: status, code: errorMessage)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // Multipart POST for clip/audio file uploads — mirrors uploadReferenceMedia's manual
    // boundary construction, generalized with optional extra text fields (numeric trim/offset
    // params the backend's multer routes read via req.body, coerced server-side by
    // parseOptionalNumber since multipart fields always arrive as strings).
    private func multipartProjectRequest<T: Decodable>(
        path: String,
        fileFieldName: String = "file",
        fileName: String,
        mimeType: String,
        fileData: Data,
        textFields: [String: String] = [:],
        expectedStatus: Set<Int> = [201]
    ) async throws -> T {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let crlf = "\r\n"
        for (key, value) in textFields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }
        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(fileName)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(fileData)
        body.append("\(crlf)--\(boundary)--\(crlf)".data(using: .utf8)!)

        let token = try await getIDToken()
        var request = URLRequest(url: projectURL(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, expectedStatus.contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorMessage = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.unexpectedResponse(statusCode: status, code: errorMessage)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    // POST /api/projects — NOTE: this specific endpoint's request body is camelCase
    // (`aspectRatio`), unlike PATCH /api/projects/:id's snake_case `aspect_ratio` — a real
    // inconsistency in the already-shipped backend route (routes/projects.ts POST '/' destructures
    // `{ title, aspectRatio }` directly off req.body), not something this iOS-only plan can fix.
    // Response is the slim `Project` row shape (see EditProject's doc comment).
    func createProject(title: String? = nil, aspectRatio: String? = nil) async throws -> EditProject {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let aspectRatio { body["aspectRatio"] = aspectRatio }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: ProjectResponse = try await projectRequest(
            path: "api/projects", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.project
    }

    // GET /api/projects — cursor-paginated project hub list, newest-first (D-06).
    func listProjects(cursor: String? = nil, limit: Int = 20) async throws -> (items: [ProjectSummary], nextCursor: String?) {
        var components = URLComponents(url: projectURL("api/projects"), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        let token = try await getIDToken()
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[APIClient] GET api/projects → HTTP \(status): \(String(data: data, encoding: .utf8) ?? "no body")")
            throw APIError.unexpectedResponse(statusCode: status, code: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectsListResponse.self, from: data)
        return (decoded.items, decoded.nextCursor)
    }

    // GET /api/projects/:id — full editable project state (D-01), fresh presigned urls for
    // every clip/audio element.
    func getProject(id: String) async throws -> EditProject {
        let response: ProjectResponse = try await projectRequest(path: "api/projects/\(id)", method: "GET")
        return response.project
    }

    // PATCH /api/projects/:id — the SINGLE update method both Plan 11 (title rename, aspect
    // toggle) and Plan 16 (Caption Style sheet) call. Sends ONLY the non-nil parameters so
    // omitted fields are never overwritten with `null` — matches the backend's "ANY subset"
    // contract (routes/projects.ts PATCH '/:id'). A 400 (invalid aspect_ratio / caption_style
    // .position) surfaces as a typed APIError.unexpectedResponse via projectRequest, never a
    // crash-decode of the error body as EditProject.
    func updateProject(
        id: String,
        title: String? = nil,
        aspectRatio: String? = nil,
        captionStyle: CaptionStyle? = nil
    ) async throws -> EditProject {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let aspectRatio { body["aspect_ratio"] = aspectRatio }
        if let captionStyle {
            var captionStyleBody: [String: Any] = [
                "fontSize": captionStyle.fontSize,
                "color": captionStyle.color,
                "highlightColor": captionStyle.highlightColor,
                "position": captionStyle.position,
            ]
            // Item 3: only included when set — an absent key (not a JSON null, which
            // JSONSerialization can't represent for a Double? anyway) lets the backend's own
            // CAPTION_POSITION_PRESETS fallback apply for styles that never had a drag offset set.
            if let yOffsetNorm = captionStyle.yOffsetNorm {
                captionStyleBody["yOffsetNorm"] = yOffsetNorm
            }
            body["caption_style"] = captionStyleBody
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: ProjectResponse = try await projectRequest(
            path: "api/projects/\(id)", method: "PATCH", body: bodyData, expectedStatus: [200]
        )
        return response.project
    }

    // DELETE /api/projects/:id — reuses the existing swipe/long-press confirm-dialog pattern (D-04).
    func deleteProject(id: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(id)", method: "DELETE")
    }

    // POST /api/projects/:id/cover — sets a custom project cover from a scrubbed frame (Plan
    // 13-21 B3/F17). `atSeconds` is the picked global timeline position resolved to a LOCAL
    // seconds-within-that-clip value by the caller (CoverPickerSheet, via the composition's clip
    // ranges) — the backend clamps it into the clip's own real duration server-side either way.
    // Returns a fresh presigned thumbnail_url.
    // unused since 13-24 K6, kept for API parity
    func setProjectCover(id: String, clipId: String, atSeconds: Double) async throws -> String {
        let body: [String: Any] = ["clip_id": clipId, "at_seconds": atSeconds]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: CoverResponse = try await projectRequest(
            path: "api/projects/\(id)/cover", method: "POST", body: bodyData, expectedStatus: [200]
        )
        return response.thumbnailUrl
    }

    // Plan 13-24 K-B1/K6: multipart cover image upload (client-composited JPEG).
    func setProjectCoverImage(id: String, imageData: Data) async throws -> String {
        let response: CoverResponse = try await multipartProjectRequest(
            path: "api/projects/\(id)/cover",
            fileName: "cover.jpg",
            mimeType: "image/jpeg",
            fileData: imageData,
            expectedStatus: [200]
        )
        return response.thumbnailUrl
    }

    // POST /api/projects/:id/clips — import by copy from an owned, completed generation (D-03).
    func importClipFromGeneration(projectId: String, generationId: String) async throws -> ProjectClip {
        let body: [String: Any] = ["source_type": "generation", "generation_id": generationId]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: ClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/clips", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.clip
    }

    // POST /api/projects/:id/clips — import a freshly-uploaded file (camera roll/Files, D-08)
    // as multipart/form-data. mediaType only picks a content-type fallback when the file's own
    // extension isn't recognized — the backend infers media_type from the multipart mimetype.
    func uploadClip(projectId: String, fileURL: URL, mediaType: String) async throws -> ProjectClip {
        let fileData = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "mp4": mimeType = "video/mp4"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "png": mimeType = "image/png"
        case "webp": mimeType = "image/webp"
        default: mimeType = mediaType == "image" ? "image/jpeg" : "video/mp4"
        }
        let response: ClipResponse = try await multipartProjectRequest(
            path: "api/projects/\(projectId)/clips",
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType,
            fileData: fileData,
            expectedStatus: [201]
        )
        return response.clip
    }

    // PATCH /api/projects/:id/clips/:clipId — trim/reorder a clip (SC2).
    func updateClip(
        projectId: String,
        clipId: String,
        sortOrder: Int? = nil,
        trimStart: Double? = nil,
        trimEnd: Double? = nil
    ) async throws -> ProjectClip {
        var body: [String: Any] = [:]
        if let sortOrder { body["sort_order"] = sortOrder }
        if let trimStart { body["trim_start_seconds"] = trimStart }
        if let trimEnd { body["trim_end_seconds"] = trimEnd }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: ClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/clips/\(clipId)", method: "PATCH", body: bodyData, expectedStatus: [200]
        )
        return response.clip
    }

    // DELETE /api/projects/:id/clips/:clipId — now a soft-delete server-side (Plan 13-21 B1); the
    // R2 object and row are kept for 24h so restoreClip below can undo it.
    func deleteClip(projectId: String, clipId: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(projectId)/clips/\(clipId)", method: "DELETE")
    }

    // POST /api/projects/:id/clips/:clipId/restore — undoes a clip soft-delete (Plan 13-21 B1.3/
    // F8). A 404 (row missing, never deleted, or already purged past the 24h window) surfaces as
    // APIError.unexpectedResponse(statusCode: 404, _) — ProjectManager.restoreClip maps that to
    // PurgedRestoreError so EditorHistory can show the dedicated "file was removed" toast.
    func restoreClip(projectId: String, clipId: String) async throws -> ProjectClip {
        let response: ClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/clips/\(clipId)/restore", method: "POST", expectedStatus: [200]
        )
        return response.clip
    }

    // POST /api/projects/:id/clips/:clipId/split — T-13-19 Task G1/F. Server copies the source
    // r2_key to a new object, shrinks the original's trim_end to `originalTrimEnd`, and inserts the
    // second half at `newSortOrder`. Returns the NEW clip; the caller re-fetches the full project
    // (mirrors every other clip-mutation's url-less-response convention) rather than trusting
    // either half's response for playback.
    func splitClip(
        projectId: String,
        clipId: String,
        originalTrimEnd: Double,
        newTrimStart: Double,
        newTrimEnd: Double,
        newSortOrder: Int
    ) async throws -> ProjectClip {
        let body: [String: Any] = [
            "original_trim_end": originalTrimEnd,
            "new_trim_start": newTrimStart,
            "new_trim_end": newTrimEnd,
            "new_sort_order": newSortOrder,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: ClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/clips/\(clipId)/split", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.clip
    }

    // POST /api/projects/:id/text — add a draggable Text overlay (SC3).
    func addTextOverlay(
        projectId: String,
        text: String,
        xNorm: Double,
        yNorm: Double,
        widthNorm: Double? = nil,
        rotation: Double? = nil,
        rowIndex: Int? = nil,
        startSeconds: Double,
        endSeconds: Double
    ) async throws -> TextOverlay {
        var body: [String: Any] = [
            "text": text, "x_norm": xNorm, "y_norm": yNorm,
            "start_seconds": startSeconds, "end_seconds": endSeconds,
        ]
        if let widthNorm { body["width_norm"] = widthNorm }
        if let rotation { body["rotation"] = rotation }
        if let rowIndex { body["row_index"] = rowIndex }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: TextOverlayResponse = try await projectRequest(
            path: "api/projects/\(projectId)/text", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.textOverlay
    }

    // PATCH /api/projects/:id/text/:textId — move/retime/resize/rotate a Text overlay.
    func updateTextOverlay(
        projectId: String,
        textId: String,
        text: String? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        widthNorm: Double? = nil,
        rotation: Double? = nil,
        rowIndex: Int? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) async throws -> TextOverlay {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let xNorm { body["x_norm"] = xNorm }
        if let yNorm { body["y_norm"] = yNorm }
        if let widthNorm { body["width_norm"] = widthNorm }
        if let rotation { body["rotation"] = rotation }
        if let rowIndex { body["row_index"] = rowIndex }
        if let startSeconds { body["start_seconds"] = startSeconds }
        if let endSeconds { body["end_seconds"] = endSeconds }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: TextOverlayResponse = try await projectRequest(
            path: "api/projects/\(projectId)/text/\(textId)", method: "PATCH", body: bodyData, expectedStatus: [200]
        )
        return response.textOverlay
    }

    // DELETE /api/projects/:id/text/:textId
    func deleteTextOverlay(projectId: String, textId: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(projectId)/text/\(textId)", method: "DELETE")
    }

    // POST /api/projects/:id/audio — add an audio clip from a fresh upload (multipart). Numeric
    // fields are sent as multipart TEXT fields (never JSON) — the backend's multer route coerces
    // them server-side via parseOptionalNumber, exactly like the file path requires.
    func addAudioClip(
        projectId: String,
        fileURL: URL,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil
    ) async throws -> AudioClip {
        let fileData = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "m4a": mimeType = "audio/mp4"
        case "mp3": mimeType = "audio/mpeg"
        case "wav": mimeType = "audio/wav"
        default: mimeType = "audio/mp4"
        }
        var textFields: [String: String] = [:]
        if let startOffsetSeconds { textFields["start_offset_seconds"] = String(startOffsetSeconds) }
        if let trimStartSeconds { textFields["trim_start_seconds"] = String(trimStartSeconds) }
        if let trimEndSeconds { textFields["trim_end_seconds"] = String(trimEndSeconds) }
        let response: AudioClipResponse = try await multipartProjectRequest(
            path: "api/projects/\(projectId)/audio",
            fileName: fileURL.lastPathComponent,
            mimeType: mimeType,
            fileData: fileData,
            textFields: textFields,
            expectedStatus: [201]
        )
        return response.audioClip
    }

    // POST /api/projects/:id/audio — add a preset background-music track (server-side R2 copy,
    // no file upload) as a plain JSON body so multer's multipart parser doesn't engage.
    func addPresetAudio(
        projectId: String,
        presetMusicId: String,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil
    ) async throws -> AudioClip {
        var body: [String: Any] = ["source_type": "preset", "preset_music_id": presetMusicId]
        if let startOffsetSeconds { body["start_offset_seconds"] = startOffsetSeconds }
        if let trimStartSeconds { body["trim_start_seconds"] = trimStartSeconds }
        if let trimEndSeconds { body["trim_end_seconds"] = trimEndSeconds }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: AudioClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/audio", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.audioClip
    }

    // PATCH /api/projects/:id/audio/:audioId — reposition/retrim/reorder an audio clip.
    func updateAudioClip(
        projectId: String,
        audioId: String,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        sortOrder: Int? = nil
    ) async throws -> AudioClip {
        var body: [String: Any] = [:]
        if let startOffsetSeconds { body["start_offset_seconds"] = startOffsetSeconds }
        if let trimStartSeconds { body["trim_start_seconds"] = trimStartSeconds }
        if let trimEndSeconds { body["trim_end_seconds"] = trimEndSeconds }
        if let sortOrder { body["sort_order"] = sortOrder }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: AudioClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/audio/\(audioId)", method: "PATCH", body: bodyData, expectedStatus: [200]
        )
        return response.audioClip
    }

    // DELETE /api/projects/:id/audio/:audioId
    func deleteAudioClip(projectId: String, audioId: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(projectId)/audio/\(audioId)", method: "DELETE")
    }

    // POST /api/projects/:id/audio/:audioId/restore — undoes an audio clip soft-delete (Plan
    // 13-21 B1.3/F8). Same 404-means-purged contract as restoreClip above.
    func restoreAudioClip(projectId: String, audioId: String) async throws -> AudioClip {
        let response: AudioClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/audio/\(audioId)/restore", method: "POST", expectedStatus: [200]
        )
        return response.audioClip
    }

    // POST /api/projects/:id/audio/:audioId/split — T-13-19 Task G2/F. Same copy-then-insert shape
    // as splitClip. Returns the NEW audio clip; caller re-fetches for a fresh presigned url.
    func splitAudioClip(
        projectId: String,
        audioId: String,
        originalTrimEnd: Double,
        newTrimStart: Double,
        newTrimEnd: Double,
        newStartOffsetSeconds: Double
    ) async throws -> AudioClip {
        let body: [String: Any] = [
            "original_trim_end": originalTrimEnd,
            "new_trim_start": newTrimStart,
            "new_trim_end": newTrimEnd,
            "new_start_offset_seconds": newStartOffsetSeconds,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: AudioClipResponse = try await projectRequest(
            path: "api/projects/\(projectId)/audio/\(audioId)/split", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.audioClip
    }

    // POST /api/projects/:id/captions — add a caption cue (+ its words).
    func addCaptionCue(
        projectId: String,
        startSeconds: Double,
        endSeconds: Double,
        words: [CaptionWord]? = nil
    ) async throws -> CaptionCue {
        var body: [String: Any] = ["start_seconds": startSeconds, "end_seconds": endSeconds]
        if let words {
            body["words"] = words.map { ["text": $0.text, "start_seconds": $0.startSeconds, "end_seconds": $0.endSeconds] }
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: CaptionCueResponse = try await projectRequest(
            path: "api/projects/\(projectId)/captions", method: "POST", body: bodyData, expectedStatus: [201]
        )
        return response.captionCue
    }

    // PATCH /api/projects/:id/captions/:cueId — retime a cue and/or REPLACE its word list
    // (backend deletes+reinserts words wholesale when `words` is present — never a per-word PATCH).
    func updateCaptionCue(
        projectId: String,
        cueId: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        words: [CaptionWord]? = nil
    ) async throws -> CaptionCue {
        var body: [String: Any] = [:]
        if let startSeconds { body["start_seconds"] = startSeconds }
        if let endSeconds { body["end_seconds"] = endSeconds }
        if let words {
            body["words"] = words.map { ["text": $0.text, "start_seconds": $0.startSeconds, "end_seconds": $0.endSeconds] }
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let response: CaptionCueResponse = try await projectRequest(
            path: "api/projects/\(projectId)/captions/\(cueId)", method: "PATCH", body: bodyData, expectedStatus: [200]
        )
        return response.captionCue
    }

    // DELETE /api/projects/:id/captions/:cueId — delete a single cue (+ its words).
    func deleteCaptionCue(projectId: String, cueId: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(projectId)/captions/\(cueId)", method: "DELETE")
    }

    // DELETE /api/projects/:id/captions — bulk clear the ENTIRE Captions track (D-13). Distinct
    // path shape from the single-cue delete above (no :cueId segment).
    func deleteAllCaptions(projectId: String) async throws {
        try await authorizedRequestNoContent(path: "api/projects/\(projectId)/captions", method: "DELETE")
    }

    // POST /api/projects/:id/clips/:clipId/captions/auto-generate — Whisper word-level
    // auto-captions from a clip's audio (SC5). A transcription failure surfaces as a 502, mapped
    // by projectRequest into a typed APIError, never a silent empty result.
    func autoGenerateCaptions(projectId: String, clipId: String) async throws -> [CaptionCue] {
        let response: CaptionCuesListResponse = try await projectRequest(
            path: "api/projects/\(projectId)/clips/\(clipId)/captions/auto-generate", method: "POST", expectedStatus: [200]
        )
        return response.cues
    }

    // POST /api/projects/:id/export — real free export (D-07/D-10/D-12/SC7). Returns the new
    // generation_id so the caller reuses the EXISTING GenerationManager poll loop
    // (GET /api/generations/:id) — no new export-status polling code (RESEARCH Don't-Hand-Roll).
    func exportProject(id: String) async throws -> String {
        let response: ExportResponse = try await projectRequest(
            path: "api/projects/\(id)/export", method: "POST", expectedStatus: [202]
        )
        return response.generationId
    }
}

// MARK: - Project API response wrappers (private — decode targets only, never surfaced directly)

private struct ProjectResponse: Decodable {
    let project: EditProject
}

private struct CoverResponse: Decodable {
    let thumbnailUrl: String
    enum CodingKeys: String, CodingKey {
        case thumbnailUrl = "thumbnail_url"
    }
}

private struct ProjectsListResponse: Decodable {
    let items: [ProjectSummary]
    let nextCursor: String?
}

private struct ClipResponse: Decodable {
    let clip: ProjectClip
}

private struct TextOverlayResponse: Decodable {
    let textOverlay: TextOverlay
    enum CodingKeys: String, CodingKey {
        case textOverlay = "text_overlay"
    }
}

private struct AudioClipResponse: Decodable {
    let audioClip: AudioClip
    enum CodingKeys: String, CodingKey {
        case audioClip = "audio_clip"
    }
}

private struct CaptionCueResponse: Decodable {
    let captionCue: CaptionCue
    enum CodingKeys: String, CodingKey {
        case captionCue = "caption_cue"
    }
}

private struct CaptionCuesListResponse: Decodable {
    let cues: [CaptionCue]
}

private struct ExportResponse: Decodable {
    let generationId: String
    enum CodingKeys: String, CodingKey {
        case generationId = "generation_id"
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
    let falKlingV3StandardRates: [String: Double]? // audioOff/audioOn credits per second
    let falKlingO3StandardRates: [String: Double]? // Kling O3 reference-to-video audioOff/audioOn credits per second
    let klingMotionStandardRate: Double? // Replicate Motion Control std+audio credits per second

    enum CodingKeys: String, CodingKey {
        case rates
        case imageCosts = "imageCosts"
        case grokImagineRate = "grokImagineRate"
        case dreamactorRate = "dreamactorRate"
        case upscalerRates = "upscalerRates"
        case falKlingV3StandardRates = "falKlingV3StandardRates"
        case falKlingO3StandardRates = "falKlingO3StandardRates"
        case klingMotionStandardRate = "klingMotionStandardRate"
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
    let hasFaceConsent: Bool

    enum CodingKeys: String, CodingKey {
        case user
        case creditsBalance = "credits_balance"
        case subscriptionAllotment = "subscription_allotment"
        case activeTopupBalance = "active_topup_balance"
        case entitlementLevel = "entitlement_level"
        case hasFaceConsent = "has_face_consent"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(UserInfo.self, forKey: .user)
        creditsBalance = try container.decode(Int.self, forKey: .creditsBalance)
        subscriptionAllotment = try container.decode(Int.self, forKey: .subscriptionAllotment)
        activeTopupBalance = try container.decode(Int.self, forKey: .activeTopupBalance)
        entitlementLevel = try container.decodeIfPresent(String.self, forKey: .entitlementLevel)
        // Backend always sends has_face_consent (09.2-03), but decode defensively for older responses.
        hasFaceConsent = try container.decodeIfPresent(Bool.self, forKey: .hasFaceConsent) ?? false
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

private struct VideoTranslationRequestBody: Encodable {
    let outputLanguage: String

    enum CodingKeys: String, CodingKey {
        case outputLanguage = "output_language"
    }
}

// Formats submission body. Optional grounding fields are nil on the common path so synthesized
// Encodable omits them entirely instead of sending an empty attachment_ids array or source_url.
private struct FormatGenerationRequestBody: Encodable {
    let formatId: String
    let styleId: String
    let prompt: String
    let durationSeconds: Int
    let voiceId: String
    let music: String
    let aspectRatio: String?
    let attachmentIds: [String]?
    let sourceUrl: String?

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case styleId = "style_id"
        case prompt
        case durationSeconds = "duration_seconds"
        case voiceId = "voice_id"
        case music
        case aspectRatio = "aspect_ratio"
        case attachmentIds = "attachment_ids"
        case sourceUrl = "source_url"
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
    // Preset submission (09.1-07, D-10/D-11): set only when the request originates from
    // PresetInputSheet. nil on every freeform composer submission — CodingKeys below omit
    // nil fields from the encoded JSON, so this is fully additive and does not change the
    // shape of existing freeform requests. Default `= nil` + `var` (not `let`) here is
    // required for Swift's synthesized memberwise initializer to keep these two parameters
    // optional-with-default rather than dropping them from the initializer entirely (a `let`
    // with a default value is excluded from the memberwise init's parameter list altogether) —
    // this keeps every existing GenerationRequestBody(...) call site (GenerateView's composer)
    // compiling unchanged while still letting PresetInputSheet pass explicit values.
    var presetId: String? = nil
    // 09.1-11/12 (Clothes Swap): index-aligned to the preset's input_schema.slots — nil entries
    // are JSON-encoded as `null`, the server's placeholder for a skipped OPTIONAL slot (never
    // compact this array; a shorter array would misalign every slot after the first gap).
    var presetInputUploadIds: [String?]? = nil
    // Real picked-media duration for per-second presets (Motion Transfer, AI Influencer — D-18,
    // D-23). Distinct from `duration` above (that field is video-mode-only and unrelated to
    // presets). The server reads this exact wire key as a starting point only — it always
    // clamps to the preset's own `max_seconds` before billing (D-16), so this value is never
    // trusted beyond suggesting where to start. nil on every non-per-second submission.
    var estimatedDurationSeconds: Double? = nil
    // Magic Editor (09.2-10, SC4): the uploaded alpha-mask PNG's reference_uploads id. Set only
    // on preset_id="magic-editor" submissions — nil for every other request (image/video
    // freeform, every other preset). The backend's presetResolver/prepareCost reads this
    // alongside preset_input_upload_ids[0] (the source image) to dispatch the inline OpenAI
    // gpt-image-2 mask-edit path (09.2-08).
    var maskUploadId: String? = nil
    // AI Influencer Pro tier only (D-25): "pro" routes the backend's presetResolver to the
    // character_replace_quality flag instead of the direct Wan 2.2 dispatch. nil (Standard tier,
    // or every other preset) omits this key entirely — the server only ever reads it when
    // preset_id is "ai-influencer" (presetResolver.ts scopes it there explicitly).
    var quality: String? = nil

    enum CodingKeys: String, CodingKey {
        case prompt, model
        case mediaType = "media_type"
        case duration, resolution
        case estimatedDurationSeconds = "estimated_duration_seconds"
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
        case presetId = "preset_id"
        case presetInputUploadIds = "preset_input_upload_ids"
        case maskUploadId = "mask_upload_id"
        case quality
    }
}
