// ProjectManager.swift
// Fantasia
// Observable store for Phase 13 (Edit Studio): the project hub list (D-06) + the currently
// open/loaded project's full editable state (D-01). Pattern mirrors GenerationManager /
// MediaLibraryManager — @Observable @MainActor final class, cache-first list load, Swift
// Concurrency only (CLAUDE.md: no Timer).

import Foundation
import FirebaseAuth

@Observable
@MainActor
final class ProjectManager {
    private static let snapshotName = "projectsSnapshot"
    private static let staleAfter: TimeInterval = 60

    // Published state — read by the Studio hub grid and the editor screen (plans 09-18).
    var projects: [ProjectSummary] = []
    var loadedProject: EditProject?
    var isLoading = false
    var loadError: String?
    var nextCursor: String?
    private(set) var hasLoadedOnce = false
    private var lastLoadDate: Date?

    private var isStale: Bool {
        lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    // MARK: - Snapshot (cache-first cold start, mirrors MediaLibraryManager.hydrateFromSnapshot)

    func hydrateFromSnapshot() {
        guard projects.isEmpty, let uid = Auth.auth().currentUser?.uid,
              let snapshot = ListSnapshotStore.load([ProjectSummary].self, name: Self.snapshotName, uid: uid),
              !snapshot.items.isEmpty else { return }
        projects = snapshot.items
        hasLoadedOnce = true
    }

    /// Clears in-memory state and the persisted snapshot for a signed-out user, so their
    /// project hub never flashes for the next account that signs in.
    func clearSnapshot(uid: String) {
        ListSnapshotStore.clear(name: Self.snapshotName, uid: uid)
        projects = []
        loadedProject = nil
        hasLoadedOnce = false
        lastLoadDate = nil
    }

    private func persistSnapshot() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        ListSnapshotStore.save(projects, name: Self.snapshotName, uid: uid)
    }

    // MARK: - Project hub list (D-06 — the Studio grid: "+" tile + existing project tiles)

    /// Cache-first load: renders the cached grid instantly, only refetches if stale/never loaded.
    func loadProjects() async {
        guard !hasLoadedOnce || isStale else { return }
        await refreshProjects()
    }

    func refreshProjects() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.listProjects()
            projects = result.items
            nextCursor = result.nextCursor
            hasLoadedOnce = true
            lastLoadDate = Date()
            persistSnapshot()
        } catch {
            print("[ProjectManager] refreshProjects error: \(error)")
            loadError = "Couldn't load your projects."
        }
    }

    func loadNextPage() async {
        guard !isLoading, let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.listProjects(cursor: cursor)
            let existingIds = Set(projects.map(\.id))
            projects.append(contentsOf: result.items.filter { !existingIds.contains($0.id) })
            nextCursor = result.nextCursor
        } catch {
            print("[ProjectManager] loadNextPage error: \(error)")
        }
    }

    // MARK: - Project creation (D-01/D-02, D-08's dual source: generation OR fresh upload)

    /// Creates a new project and imports its first clip, then re-fetches the full project state
    /// before returning/loading it. POST /api/projects and POST /:id/clips both return
    /// slim/url-less rows (see EditProject's and ProjectClip's doc comments in EditProject.swift)
    /// — the create response itself is never trusted for display, only the follow-up GET /:id is.
    @discardableResult
    func createProject(
        title: String? = nil,
        aspectRatio: String? = nil,
        firstClipGenerationId: String? = nil,
        firstClipUploadURL: URL? = nil,
        firstClipMediaType: String = "video"
    ) async throws -> EditProject {
        let created = try await APIClient.shared.createProject(title: title, aspectRatio: aspectRatio)
        if let firstClipGenerationId {
            _ = try await APIClient.shared.importClipFromGeneration(projectId: created.id, generationId: firstClipGenerationId)
        } else if let firstClipUploadURL {
            _ = try await APIClient.shared.uploadClip(projectId: created.id, fileURL: firstClipUploadURL, mediaType: firstClipMediaType)
        }
        let full = try await APIClient.shared.getProject(id: created.id)
        loadedProject = full
        projects.insert(
            ProjectSummary(id: full.id, title: full.title, thumbnailUrl: full.thumbnailUrl, updatedAt: full.updatedAt),
            at: 0
        )
        persistSnapshot()
        return full
    }

    // MARK: - Opening / reloading a project (D-01)

    func openProject(id: String) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            loadedProject = try await APIClient.shared.getProject(id: id)
        } catch {
            print("[ProjectManager] openProject error: \(error)")
            loadError = "Couldn't open this project."
        }
    }

    /// Re-fetches the loaded project's full state — the general reconciliation step after any
    /// clip/audio mutation (their POST/PATCH responses are partial/url-less by design, see
    /// EditProject.swift's doc comments), and the mitigation for T-13-22/Pitfall 3 (a presigned
    /// url 403ing mid-session because the editor has been open longer than the 1h TTL).
    func refreshLoadedProjectURLs() async {
        guard let id = loadedProject?.id else { return }
        do {
            loadedProject = try await APIClient.shared.getProject(id: id)
        } catch {
            print("[ProjectManager] refreshLoadedProjectURLs error: \(error)")
        }
    }

    // MARK: - Delete (D-04 — reuses the existing swipe/long-press confirm-dialog pattern, no new UI)

    func deleteProject(id: String) async throws {
        try await APIClient.shared.deleteProject(id: id)
        projects.removeAll { $0.id == id }
        if loadedProject?.id == id { loadedProject = nil }
        persistSnapshot()
    }

    // MARK: - Project-level field updates (Plan 11: title rename/aspect toggle; Plan 16: Caption
    // Style sheet) — all three merge ONLY the one changed field into `loadedProject` in place;
    // they never replace the whole object with the PATCH response, since that response omits the
    // clips/textOverlays/audioClips/captionCues arrays (see EditProject.swift's doc comment).

    func updateProjectTitle(_ title: String) async throws {
        guard let id = loadedProject?.id else { return }
        let updated = try await APIClient.shared.updateProject(id: id, title: title)
        loadedProject?.title = updated.title
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].title = updated.title
        }
    }

    func updateAspectRatio(_ aspectRatio: String) async throws {
        guard let id = loadedProject?.id else { return }
        let updated = try await APIClient.shared.updateProject(id: id, aspectRatio: aspectRatio)
        loadedProject?.aspectRatio = updated.aspectRatio
    }

    func updateCaptionStyle(_ style: CaptionStyle) async throws {
        guard let id = loadedProject?.id else { return }
        let updated = try await APIClient.shared.updateProject(id: id, captionStyle: style)
        loadedProject?.captionStyle = updated.captionStyle
    }

    // MARK: - Clip mutations (SC2) — reconcile via a full re-fetch afterward (mutation responses
    // are url-less by design, see refreshLoadedProjectURLs's doc comment above).

    func importClip(generationId: String) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.importClipFromGeneration(projectId: id, generationId: generationId)
        await refreshLoadedProjectURLs()
    }

    func uploadClip(fileURL: URL, mediaType: String) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.uploadClip(projectId: id, fileURL: fileURL, mediaType: mediaType)
        await refreshLoadedProjectURLs()
    }

    func updateClip(clipId: String, sortOrder: Int? = nil, trimStart: Double? = nil, trimEnd: Double? = nil) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.updateClip(
            projectId: id, clipId: clipId, sortOrder: sortOrder, trimStart: trimStart, trimEnd: trimEnd
        )
        await refreshLoadedProjectURLs()
    }

    func deleteClip(clipId: String) async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteClip(projectId: id, clipId: clipId)
        loadedProject?.clips.removeAll { $0.id == clipId }
    }

    // MARK: - Text overlay mutations (SC3) — optimistic in-place update; no url concern.

    func addTextOverlay(
        text: String,
        xNorm: Double,
        yNorm: Double,
        widthNorm: Double? = nil,
        startSeconds: Double,
        endSeconds: Double
    ) async throws {
        guard let id = loadedProject?.id else { return }
        let overlay = try await APIClient.shared.addTextOverlay(
            projectId: id, text: text, xNorm: xNorm, yNorm: yNorm,
            widthNorm: widthNorm, startSeconds: startSeconds, endSeconds: endSeconds
        )
        loadedProject?.textOverlays.append(overlay)
    }

    func updateTextOverlay(
        textId: String,
        text: String? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        widthNorm: Double? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        let overlay = try await APIClient.shared.updateTextOverlay(
            projectId: id, textId: textId, text: text, xNorm: xNorm, yNorm: yNorm,
            widthNorm: widthNorm, startSeconds: startSeconds, endSeconds: endSeconds
        )
        if let index = loadedProject?.textOverlays.firstIndex(where: { $0.id == textId }) {
            loadedProject?.textOverlays[index] = overlay
        }
    }

    func deleteTextOverlay(textId: String) async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteTextOverlay(projectId: id, textId: textId)
        loadedProject?.textOverlays.removeAll { $0.id == textId }
    }

    // MARK: - Audio clip mutations (SC4) — reconcile via re-fetch (url-less mutation responses).

    func addAudioClip(
        fileURL: URL,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.addAudioClip(
            projectId: id, fileURL: fileURL, startOffsetSeconds: startOffsetSeconds,
            trimStartSeconds: trimStartSeconds, trimEndSeconds: trimEndSeconds
        )
        await refreshLoadedProjectURLs()
    }

    func addPresetAudio(
        presetMusicId: String,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.addPresetAudio(
            projectId: id, presetMusicId: presetMusicId, startOffsetSeconds: startOffsetSeconds,
            trimStartSeconds: trimStartSeconds, trimEndSeconds: trimEndSeconds
        )
        await refreshLoadedProjectURLs()
    }

    func updateAudioClip(
        audioId: String,
        startOffsetSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        sortOrder: Int? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        _ = try await APIClient.shared.updateAudioClip(
            projectId: id, audioId: audioId, startOffsetSeconds: startOffsetSeconds,
            trimStartSeconds: trimStartSeconds, trimEndSeconds: trimEndSeconds, sortOrder: sortOrder
        )
        await refreshLoadedProjectURLs()
    }

    func deleteAudioClip(audioId: String) async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteAudioClip(projectId: id, audioId: audioId)
        loadedProject?.audioClips.removeAll { $0.id == audioId }
    }

    // MARK: - Caption cue mutations (SC5, D-13) — optimistic in-place update; no url concern.

    func addCaptionCue(startSeconds: Double, endSeconds: Double, words: [CaptionWord]? = nil) async throws {
        guard let id = loadedProject?.id else { return }
        let cue = try await APIClient.shared.addCaptionCue(
            projectId: id, startSeconds: startSeconds, endSeconds: endSeconds, words: words
        )
        loadedProject?.captionCues.append(cue)
    }

    func updateCaptionCue(
        cueId: String,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        words: [CaptionWord]? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        let cue = try await APIClient.shared.updateCaptionCue(
            projectId: id, cueId: cueId, startSeconds: startSeconds, endSeconds: endSeconds, words: words
        )
        if let index = loadedProject?.captionCues.firstIndex(where: { $0.id == cueId }) {
            loadedProject?.captionCues[index] = cue
        }
    }

    func deleteCaptionCue(cueId: String) async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteCaptionCue(projectId: id, cueId: cueId)
        loadedProject?.captionCues.removeAll { $0.id == cueId }
    }

    /// Bulk "Delete All Captions" (D-13) — clears the entire Captions track at once, distinct
    /// from per-cue delete above.
    func deleteAllCaptions() async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteAllCaptions(projectId: id)
        loadedProject?.captionCues.removeAll()
    }

    func autoGenerateCaptions(clipId: String) async throws {
        guard let id = loadedProject?.id else { return }
        let cues = try await APIClient.shared.autoGenerateCaptions(projectId: id, clipId: clipId)
        loadedProject?.captionCues.append(contentsOf: cues)
    }

    // MARK: - Export (D-07/D-10/D-12/SC7)

    /// Returns the new generation_id — the CALLER hands this to the existing GenerationManager
    /// poll loop (GET /api/generations/:id); no bespoke export-status polling here (RESEARCH
    /// Don't-Hand-Roll). The project itself is never mutated by exporting (D-12).
    func exportProject(id: String) async throws -> String {
        try await APIClient.shared.exportProject(id: id)
    }
}
