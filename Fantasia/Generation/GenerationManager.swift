// GenerationManager.swift
// Fantasia
// Central state manager for the generation lifecycle.
// Pattern: mirrors CreditManager — @Observable @MainActor final class.
// D-03: polls GET /api/generations every 3 seconds while any job is pending/processing.
// D-03: push notification triggers an immediate refresh via refreshOnNotification().

import Foundation

// CLAUDE.md: all new iOS managers use @Observable @MainActor final class pattern
@Observable
@MainActor
final class GenerationManager {
    // Published state — read by FeedView and LibraryView
    var generations: [GenerationItem] = []
    var isLoading: Bool = false
    var nextCursor: String? = nil

    // Remix state: set before switching to Generate tab (D-35)
    var pendingRemix: GenerationItem? = nil

    private var pollingTask: Task<Void, Never>?

    // CLAUDE.md: Swift Concurrency polling — no Timer
    // D-03: poll every 3 seconds while any job is pending/processing
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let self, self.hasActiveJobs else { break }
                try? await Task.sleep(for: .seconds(3))
            }
            await MainActor.run { self?.pollingTask = nil }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // Called by push notification delegate (D-03: immediate refresh on notification)
    func refreshOnNotification() {
        Task { await refresh() }
        if hasActiveJobs { startPolling() }
    }

    // Load first page (or reload all)
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // NOTE: APIClient.fetchGenerations is added in Plan 06 (07-06-PLAN.md)
            // Calling pattern follows CreditManager.fetchBalance()
            let response: GenerationsResponse = try await APIClient.shared.authorizedRequest(path: "api/generations")
            generations = response.items
            nextCursor = response.nextCursor
        } catch {
            print("[GenerationManager] refresh error: \(error)")
        }
    }

    // Load next page (pagination, cursor-based)
    func loadNextPage() async {
        guard !isLoading, let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = "api/generations?cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)"
            let response: GenerationsResponse = try await APIClient.shared.authorizedRequest(path: path)
            generations.append(contentsOf: response.items)
            nextCursor = response.nextCursor
        } catch {
            print("[GenerationManager] loadNextPage error: \(error)")
        }
    }

    // Remove deleted generation from local state (called after DELETE /api/generations/:id)
    func removeGeneration(id: String) {
        generations.removeAll { $0.id == id }
    }

    private var hasActiveJobs: Bool {
        generations.contains { $0.status == .pending || $0.status == .processing }
    }
}
