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

    private static func editProjectSnapshotName(id: String) -> String {
        "editProject-\(id)"
    }

    // Published state — read by the Studio hub grid and the editor screen (plans 09-18).
    var projects: [ProjectSummary] = []
    var loadedProject: EditProject?
    var isLoading = false
    var loadError: String?
    var nextCursor: String?
    private(set) var hasLoadedOnce = false
    private var lastLoadDate: Date?
    private var activeClipMutationCount = 0
    var isMutatingClips: Bool { activeClipMutationCount > 0 }

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
        lastLoadDate = snapshot.fetchedAt
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

    private func persistEditProjectSnapshot(_ project: EditProject) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        ListSnapshotStore.save([project], name: Self.editProjectSnapshotName(id: project.id), uid: uid)
    }

    private func loadEditProjectSnapshot(id: String) -> EditProject? {
        guard let uid = Auth.auth().currentUser?.uid,
              let snapshot = ListSnapshotStore.load([EditProject].self, name: Self.editProjectSnapshotName(id: id), uid: uid),
              let project = snapshot.items.first else { return nil }
        return project
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
            let uploaded = try await APIClient.shared.uploadClip(
                projectId: created.id,
                fileURL: firstClipUploadURL,
                mediaType: firstClipMediaType
            )
            // The picker file is already the exact source we just uploaded. Seed it under the
            // server clip id before the editor can ask for the R2 URL, avoiding an immediate
            // upload-then-download round trip on every newly created upload project.
            await ClipFileCache.shared.seed(clipId: uploaded.id, sourceURL: firstClipUploadURL)
        }
        let full = try await APIClient.shared.getProject(id: created.id)
        loadedProject = full
        persistEditProjectSnapshot(full)
        projects.insert(
            ProjectSummary(
                id: full.id,
                title: full.title,
                thumbnailUrl: full.thumbnailUrl,
                aspectRatio: full.aspectRatio,
                lastExport: full.lastExport,
                updatedAt: full.updatedAt
            ),
            at: 0
        )
        persistSnapshot()
        return full
    }

    // MARK: - Opening / reloading a project (D-01)

    /// Cache-first open (Plan 13-25 L7): when a per-project snapshot exists, hydrates
    /// `loadedProject` synchronously and kicks a background URL refresh. Returns `true` on
    /// cache hit so the caller can navigate immediately without awaiting the network.
    func openProjectFromCache(id: String) -> Bool {
        guard let cached = loadEditProjectSnapshot(id: id) else { return false }
        loadedProject = cached
        Task { await refreshLoadedProjectURLs() }
        return true
    }

    @discardableResult
    func openProject(id: String) async -> Bool {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            var project = try await APIClient.shared.getProject(id: id)
            if project.lastExport == nil {
                project.lastExport = projects.first(where: { $0.id == id })?.lastExport
            }
            loadedProject = project
            persistEditProjectSnapshot(project)
            mergeProjectThumbnailIntoSummary(project)
            return true
        } catch {
            print("[ProjectManager] openProject error: \(error)")
            loadError = "Couldn't open this project."
            return false
        }
    }

    /// Re-fetches the loaded project's full state — the general reconciliation step after any
    /// clip/audio mutation (their POST/PATCH responses are partial/url-less by design, see
    /// EditProject.swift's doc comments), and the mitigation for T-13-22/Pitfall 3 (a presigned
    /// url 403ing mid-session because the editor has been open longer than the 1h TTL).
    func refreshLoadedProjectURLs() async {
        guard let id = loadedProject?.id else { return }
        do {
            var project = try await APIClient.shared.getProject(id: id)
            // A cache refresh for a previously-open project can finish after the user has moved
            // to another one. Never let that stale response replace the new editor's state.
            guard loadedProject?.id == id else { return }
            if project.lastExport == nil {
                project.lastExport = loadedProject?.lastExport
                    ?? projects.first(where: { $0.id == id })?.lastExport
            }
            loadedProject = project
            persistEditProjectSnapshot(project)
            mergeProjectThumbnailIntoSummary(project)
        } catch {
            print("[ProjectManager] refreshLoadedProjectURLs error: \(error)")
        }
    }

    /// A full project GET may contain a newly-created/default cover that an older cached list
    /// row did not. Reconcile it immediately so closing the editor paints the real poster rather
    /// than waiting for the Studio list's 60-second refresh window.
    private func mergeProjectThumbnailIntoSummary(_ project: EditProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }),
              projects[index].thumbnailUrl != project.thumbnailUrl else { return }
        projects[index].thumbnailUrl = project.thumbnailUrl
        persistSnapshot()
    }

    // MARK: - Delete (D-04 — reuses the existing swipe/long-press confirm-dialog pattern, no new UI)

    func deleteProject(id: String) async throws {
        // Plan 13-26 M1: capture clip ids BEFORE the API call so the local ClipFileCache disk
        // entries can be evicted alongside the server-side delete — only resolvable when this
        // project happens to be the currently-loaded one (the hub grid has no clip list to draw
        // from otherwise); those orphaned files still get reclaimed eventually by the cache's own
        // 500MB LRU cap.
        let clipIdsToEvict = loadedProject?.id == id ? (loadedProject?.clips.map(\.id) ?? []) : []
        try await APIClient.shared.deleteProject(id: id)
        projects.removeAll { $0.id == id }
        if loadedProject?.id == id { loadedProject = nil }
        if let uid = Auth.auth().currentUser?.uid {
            ListSnapshotStore.clear(name: Self.editProjectSnapshotName(id: id), uid: uid)
        }
        persistSnapshot()
        if !clipIdsToEvict.isEmpty {
            Task { await ClipFileCache.shared.remove(clipIds: clipIdsToEvict) }
        }
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

    /// Plan 13-21 B3/F16-F17: sets a custom project cover from a scrubbed frame — `clipId`/
    /// `atSeconds` are the picked global timeline position ALREADY resolved to a local
    /// (clipId, seconds-within-that-clip) pair by the caller (CoverPickerSheet). Merges just the
    /// new `thumbnailUrl` into `loadedProject` in place, same convention as updateProjectTitle/
    /// updateAspectRatio/updateCaptionStyle above.
    // unused since 13-24 K6, kept for API parity
    func setCover(clipId: String, atSeconds: Double) async throws {
        guard let id = loadedProject?.id else { return }
        let thumbnailUrl = try await APIClient.shared.setProjectCover(id: id, clipId: clipId, atSeconds: atSeconds)
        loadedProject?.thumbnailUrl = thumbnailUrl
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].thumbnailUrl = thumbnailUrl
        }
        if let loadedProject { persistEditProjectSnapshot(loadedProject) }
        persistSnapshot()
    }

    /// Plan 13-24 K6: upload a client-composited cover JPEG (multipart K-B1 branch).
    func setCoverImage(data: Data) async throws {
        guard let id = loadedProject?.id else { return }
        let thumbnailUrl = try await APIClient.shared.setProjectCoverImage(id: id, imageData: data)
        loadedProject?.thumbnailUrl = thumbnailUrl
        if let index = projects.firstIndex(where: { $0.id == id }) {
            projects[index].thumbnailUrl = thumbnailUrl
        }
        if let loadedProject { persistEditProjectSnapshot(loadedProject) }
        persistSnapshot()
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
        let uploaded = try await APIClient.shared.uploadClip(
            projectId: id,
            fileURL: fileURL,
            mediaType: mediaType
        )
        await ClipFileCache.shared.seed(clipId: uploaded.id, sourceURL: fileURL)
        await refreshLoadedProjectURLs()
    }

    func updateClip(
        clipId: String,
        sortOrder: Int? = nil,
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        volume: Double? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        activeClipMutationCount += 1
        defer { activeClipMutationCount = max(0, activeClipMutationCount - 1) }
        _ = try await APIClient.shared.updateClip(
            projectId: id,
            clipId: clipId,
            sortOrder: sortOrder,
            trimStart: trimStart,
            trimEnd: trimEnd,
            volume: volume
        )
        await refreshLoadedProjectURLs()
    }

    func deleteClip(clipId: String) async throws {
        guard let id = loadedProject?.id else { return }
        try await APIClient.shared.deleteClip(projectId: id, clipId: clipId)
        loadedProject?.clips.removeAll { $0.id == clipId }
    }

    /// Plan 13-21 F8: undoes a clip soft-delete (B1.3's restore endpoint). Maps a 404 (row
    /// missing, never deleted, or purged past the 24h window) to `PurgedRestoreError` so
    /// EditorHistory can show its dedicated "Can't undo — file was removed" toast instead of a
    /// generic error.
    func restoreClip(clipId: String) async throws {
        guard let id = loadedProject?.id else { return }
        do {
            _ = try await APIClient.shared.restoreClip(projectId: id, clipId: clipId)
            await refreshLoadedProjectURLs()
        } catch APIError.unexpectedResponse(let statusCode, _) where statusCode == 404 {
            throw PurgedRestoreError()
        }
    }

    /// Splits the clip at `atLocalSeconds` (in the clip's own trim-seconds space; 13-19 Task
    /// F/G1). Uses `ClipPillView.splitPoint` for the exact same bounds math the inline trim
    /// handles rely on — a nil result (split point not strictly inside the clip's trim range) is a
    /// safe no-op, returns false. `new_trim_end` must be a concrete number server-side (the
    /// backend column has no "play to source end" sentinel), so a nil `newClipTrimEnd` (no explicit
    /// trim on the original) resolves to the clip's `originalDurationSeconds`.
    @discardableResult
    func splitClip(clipId: String, atLocalSeconds: Double) async throws -> Bool {
        guard let id = loadedProject?.id,
              let clip = loadedProject?.clips.first(where: { $0.id == clipId }),
              let split = ClipPillView.splitPoint(clip: clip, at: atLocalSeconds)
        else { return false }

        let newTrimEnd = split.newClipTrimEnd ?? clip.originalDurationSeconds ?? split.newClipTrimStart
        _ = try await APIClient.shared.splitClip(
            projectId: id,
            clipId: clipId,
            originalTrimEnd: split.originalTrimEnd,
            newTrimStart: split.newClipTrimStart,
            newTrimEnd: newTrimEnd,
            newSortOrder: split.newClipSortOrder
        )
        await refreshLoadedProjectURLs()
        return true
    }

    // MARK: - Text overlay mutations (SC3) — optimistic in-place update; no url concern.

    func addTextOverlay(
        text: String,
        xNorm: Double,
        yNorm: Double,
        widthNorm: Double? = nil,
        rotation: Double? = nil,
        rowIndex: Int? = nil,
        startSeconds: Double,
        endSeconds: Double
    ) async throws {
        guard let id = loadedProject?.id else { return }
        let overlay = try await APIClient.shared.addTextOverlay(
            projectId: id, text: text, xNorm: xNorm, yNorm: yNorm,
            widthNorm: widthNorm, rotation: rotation, rowIndex: rowIndex,
            startSeconds: startSeconds, endSeconds: endSeconds
        )
        loadedProject?.textOverlays.append(overlay)
    }

    func updateTextOverlay(
        textId: String,
        text: String? = nil,
        xNorm: Double? = nil,
        yNorm: Double? = nil,
        widthNorm: Double? = nil,
        rotation: Double? = nil,
        rowIndex: Int? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) async throws {
        guard let id = loadedProject?.id else { return }
        let overlay = try await APIClient.shared.updateTextOverlay(
            projectId: id, textId: textId, text: text, xNorm: xNorm, yNorm: yNorm,
            widthNorm: widthNorm, rotation: rotation, rowIndex: rowIndex,
            startSeconds: startSeconds, endSeconds: endSeconds
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

    /// Splits the text overlay at `atLocalSeconds` (must fall strictly inside its own
    /// [startSeconds, endSeconds]) — client-side only, no backend change (13-19 Task F): shrinks
    /// the original's endSeconds and adds a second overlay carrying the same text/position/scale/
    /// rotation for the remainder. No-op (returns false) if the split point isn't strictly inside.
    @discardableResult
    func splitTextOverlay(textId: String, atLocalSeconds: Double) async throws -> Bool {
        guard let overlay = loadedProject?.textOverlays.first(where: { $0.id == textId }) else { return false }
        guard atLocalSeconds > overlay.startSeconds + 0.05, atLocalSeconds < overlay.endSeconds - 0.05 else {
            return false
        }
        let originalEnd = overlay.endSeconds
        try await updateTextOverlay(textId: textId, endSeconds: atLocalSeconds)
        try await addTextOverlay(
            text: overlay.text,
            xNorm: overlay.xNorm,
            yNorm: overlay.yNorm,
            widthNorm: overlay.widthNorm,
            rotation: overlay.rotation,
            // 13-26 M8: the split-off second half stays on the SAME row — its [split, end] range
            // can't overlap the shrunk original's [start, split], so the row invariant holds.
            rowIndex: overlay.rowIndex,
            startSeconds: atLocalSeconds,
            endSeconds: originalEnd
        )
        return true
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

    /// Plan 13-21 F8: undoes an audio clip soft-delete — same 404-means-purged contract as
    /// restoreClip above.
    func restoreAudioClip(audioId: String) async throws {
        guard let id = loadedProject?.id else { return }
        do {
            _ = try await APIClient.shared.restoreAudioClip(projectId: id, audioId: audioId)
            await refreshLoadedProjectURLs()
        } catch APIError.unexpectedResponse(let statusCode, _) where statusCode == 404 {
            throw PurgedRestoreError()
        }
    }

    /// Splits the audio clip at `atLocalSeconds` (in the clip's own trim-seconds space; 13-19 Task
    /// F/G2). A split point not strictly inside the clip's current trim range is a safe no-op
    /// (returns false). The second piece starts playing on the timeline exactly where the first
    /// piece now ends: `newStartOffset = original.startOffsetSeconds + (atLocalSeconds - original.trimStartSeconds)`.
    @discardableResult
    func splitAudioClip(audioId: String, atLocalSeconds: Double) async throws -> Bool {
        guard let id = loadedProject?.id,
              let clip = loadedProject?.audioClips.first(where: { $0.id == audioId }),
              // F9.1 (Plan 13-21): falls back to originalDurationSeconds (B2's new probed field)
              // when the clip has never been explicitly trimmed — previously `trimEndSeconds` was
              // the ONLY source, always nil for untrimmed audio, so split silently no-op'd for
              // every audio clip a user hadn't first dragged a trim handle on. Mirrors
              // ClipPillView.splitPoint's identical clip.trimEndSeconds ?? clip.originalDurationSeconds fallback.
              let currentTrimEnd = clip.trimEndSeconds ?? clip.originalDurationSeconds
        else { return false }
        guard atLocalSeconds > clip.trimStartSeconds + 0.05, atLocalSeconds < currentTrimEnd - 0.05 else {
            return false
        }

        let newStartOffset = clip.startOffsetSeconds + (atLocalSeconds - clip.trimStartSeconds)
        _ = try await APIClient.shared.splitAudioClip(
            projectId: id,
            audioId: audioId,
            originalTrimEnd: atLocalSeconds,
            newTrimStart: atLocalSeconds,
            newTrimEnd: currentTrimEnd,
            newStartOffsetSeconds: newStartOffset
        )
        await refreshLoadedProjectURLs()
        return true
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
        // A reorder PATCH resequences every clip server-side. Wait for that authoritative refresh
        // so a fast reorder → Captions tap cannot ask the backend to offset against the old order.
        while isMutatingClips {
            try await Task.sleep(for: .milliseconds(25))
        }
        let cues = try await APIClient.shared.autoGenerateCaptions(projectId: id, clipId: clipId)
        loadedProject?.captionCues.append(contentsOf: cues)
    }

    // MARK: - Export (D-07/D-10/D-12/SC7)

    /// Returns the new generation_id and immediately marks the owning project as rendering.
    /// GenerationManager keeps using its existing poll loop for the authoritative row status.
    func exportProject(id: String) async throws -> String {
        let generationId = try await APIClient.shared.exportProject(id: id)
        applyStudioExport(
            ProjectExportSummary(
                generationId: generationId,
                status: .processing,
                mediaUrl: nil,
                completedAt: nil
            ),
            toProjectId: id
        )
        return generationId
    }

    /// Reconciles the by-id generation responses fetched by GenerationManager back into Studio.
    /// Pending client placeholders are displayed as Rendering so the hub never flashes Draft.
    func reconcileStudioExports(_ generations: [GenerationItem]) {
        for generation in generations where generation.isStudioCompose {
            guard let projectId = generation.params.exportOfProjectId else { continue }
            let currentGenerationId = projects.first(where: { $0.id == projectId })?.lastExport?.generationId
                ?? (loadedProject?.id == projectId ? loadedProject?.lastExport?.generationId : nil)
            guard currentGenerationId == generation.id else { continue }
            let status: GenerationStatus = generation.status == .pending ? .processing : generation.status
            applyStudioExport(
                ProjectExportSummary(
                    generationId: generation.id,
                    status: status,
                    mediaUrl: generation.completedMediaUrl,
                    completedAt: generation.completedAt
                ),
                toProjectId: projectId
            )
        }
    }

    private func applyStudioExport(_ export: ProjectExportSummary, toProjectId projectId: String) {
        var changed = false
        if let index = projects.firstIndex(where: { $0.id == projectId }),
           projects[index].lastExport != export {
            projects[index].lastExport = export
            changed = true
        }
        if loadedProject?.id == projectId, loadedProject?.lastExport != export {
            loadedProject?.lastExport = export
            if let loadedProject { persistEditProjectSnapshot(loadedProject) }
            changed = true
        }
        if changed { persistSnapshot() }
    }
}
