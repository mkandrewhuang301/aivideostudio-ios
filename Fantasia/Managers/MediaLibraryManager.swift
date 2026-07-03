// MediaLibraryManager.swift
// Fantasia
// Holds the user's reference-upload library (@-mention picker in GenerateView).
// Pattern: mirrors GenerationManager — @Observable @MainActor final class.
// Extracted from GenerateView's view-local @State so the list can be hydrated from a
// persisted snapshot on cold start instead of showing "Loading…" until GET /api/uploads
// responds.

import Foundation
import SwiftUI
import FirebaseAuth

@Observable
@MainActor
final class MediaLibraryManager {
    private static let snapshotName = "uploadsSnapshot"
    private static let staleAfter: TimeInterval = 300

    /// Emitted after a successful `saveGenerationAsReference` so callers that had already
    /// attached the source generation's raw output as a draft chip (uploadId == nil) can
    /// backfill that chip with the newly-created reference_uploads id.
    struct SavedReference: Equatable {
        let generationId: String
        let uploadId: String
        let displayName: String?
    }

    var items: [ReferenceUploadItem] = []
    var isLoading = false
    var loadFailed = false
    private(set) var lastSavedReference: SavedReference?
    // Perf: reopening the @-mention popup used to refetch GET /api/uploads from scratch every
    // single time (each open/close cycle reset showMentionSuggestions, re-arming the fetch
    // guard below). New/renamed/deleted items are already applied to `items` in place elsewhere
    // (attach, rename, delete), so a real refetch is only needed once per session or after a
    // longer idle gap — not on every reopen.
    private(set) var hasLoadedOnce = false
    private var lastLoadDate: Date?

    private var isStale: Bool {
        lastLoadDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    /// Loads the last-persisted upload list for the current user so the @-mention popup opens
    /// with entries instantly on cold start. Leaves lastLoadDate nil so the next load() still
    /// refetches in the background and silently replaces the list.
    func hydrateFromSnapshot() {
        guard items.isEmpty, let uid = Auth.auth().currentUser?.uid,
              let snapshot = ListSnapshotStore.load([ReferenceUploadItem].self, name: Self.snapshotName, uid: uid),
              !snapshot.items.isEmpty else { return }
        items = snapshot.items
        hasLoadedOnce = true
    }

    /// Clears in-memory state and the persisted snapshot for a signed-out user, so their upload
    /// library never flashes for the next account that signs in. Pass the uid of the user who
    /// just signed out (Auth.auth().currentUser is already nil by the time this fires).
    func clearSnapshot(uid: String) {
        ListSnapshotStore.clear(name: Self.snapshotName, uid: uid)
        items = []
        hasLoadedOnce = false
        lastLoadDate = nil
    }

    private func persistSnapshot() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        ListSnapshotStore.save(items, name: Self.snapshotName, uid: uid)
    }

    func load() async {
        // Cache hit: show the existing list instantly, no network call, no spinner.
        guard !hasLoadedOnce || isStale else { return }
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            items = try await APIClient.shared.fetchMyUploads()
            hasLoadedOnce = true
            lastLoadDate = Date()
            persistSnapshot()
        } catch {
            print("[MediaLibraryManager] fetchMyUploads failed: \(error)")
            loadFailed = true
        }
    }

    func insert(_ item: ReferenceUploadItem) {
        items.insert(item, at: 0)
        persistSnapshot()
    }

    func rename(id: String, to displayName: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].displayName = displayName
        persistSnapshot()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        persistSnapshot()
    }

    // Promotes a completed generation's output into the permanent reference library (server
    // copies the R2 object so it's independently owned and never expires). Returns false on
    // failure so the caller can surface an error.
    @discardableResult
    func saveGenerationAsReference(item: GenerationItem, name: String) async -> Bool {
        guard let response = try? await APIClient.shared.createReferenceFromGeneration(
            generationId: item.id, displayName: name
        ), let id = response.id else { return false }
        let resolvedName = response.displayName ?? (name.isEmpty ? nil : name)
        withAnimation(.spring(response: 0.3)) {
            insert(ReferenceUploadItem(
                id: id,
                url: response.url,
                mimeType: response.mimeType ?? (item.isImage ? "image/jpeg" : "video/mp4"),
                displayName: resolvedName
            ))
        }
        lastSavedReference = SavedReference(generationId: item.id, uploadId: id, displayName: resolvedName)
        return true
    }
}
