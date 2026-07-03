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
    /// True once the first refresh() has completed (success or failure). Lets callers
    /// distinguish "still loading initial history" from "confirmed no history yet".
    var hasLoadedOnce: Bool = false
    /// Timestamp of the last successful refresh() completion — drives the staleness guard in
    /// startPolling() so repeated tab switches within the window reuse the cached list instead
    /// of re-fetching GET /api/generations every time.
    private(set) var lastRefreshDate: Date?

    private static let staleAfter: TimeInterval = 60

    private var isStale: Bool {
        lastRefreshDate.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
    }

    /// True while FeedView reports an active touch anywhere in the list. While true,
    /// newly-discovered items from mergeLatest() are buffered instead of being prepended
    /// immediately — prepending mid-touch shifts every card down by a row and can route a
    /// button's touch-up onto whatever card slides into that screen position. Flushed via
    /// flushPendingInserts() the moment the touch lifts.
    var isInteracting = false {
        didSet {
            if oldValue == true, isInteracting == false {
                flushPendingInserts()
            }
        }
    }
    private var pendingNewItems: [GenerationItem] = []

    // Remix state: set before switching to Generate tab (D-35)
    var pendingRemix: GenerationItem? = nil

    // Reference state: set before switching to Generate tab — attaches this
    // generation's own output as a reference input for a new generation.
    var pendingReference: GenerationItem? = nil

    private var pollingTask: Task<Void, Never>?

    // CLAUDE.md: Swift Concurrency polling — no Timer
    // D-03: poll every 3 seconds while any job is pending/processing
    //
    // Perf: view .onAppear calls used to always trigger a full GET /api/generations before
    // this even checked hasActiveJobs — every tab switch re-fetched the whole list. Now, if
    // we already have a fresh (< staleAfter) list from a prior load and nothing is in flight,
    // this is a no-op: the cached `generations` array renders immediately. Pass
    // forceRefresh: true right after a submit, where the just-created item genuinely isn't
    // in the cached array yet and a fetch is required regardless of staleness.
    func startPolling(forceRefresh: Bool = false) {
        guard pollingTask == nil else { return }

        guard forceRefresh || !hasLoadedOnce || isStale || hasActiveJobs else {
            return // cached list is fresh and nothing is in flight — skip the network round trip
        }

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

    /// Perf: the 3s polling loop wasn't stopped on backgrounding (onDisappear doesn't fire
    /// then), so it kept ticking and hitting the network while the app was backgrounded. Call
    /// stopPolling() on scenePhase == .background and this on .active — resumes only if a job
    /// is actually still active, and force-refreshes first since background time may have let
    /// a job finish server-side without the local array reflecting it.
    func resumePollingIfNeeded() {
        guard hasActiveJobs else { return }
        startPolling(forceRefresh: true)
    }

    /// Refreshes only if the cached list is stale (or hasn't loaded yet) — for views that show
    /// the list without continuous polling (e.g. Library) but still want the 24h-TTL presigned
    /// URLs kept fresh over a long session, without re-fetching on every single appearance.
    func refreshIfStale() async {
        guard !hasLoadedOnce || isStale else { return }
        await refresh()
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
            // fetchGenerations() handles iso8601 date decoding for createdAt/completedAt
            let response = try await APIClient.shared.fetchGenerations()
            mergeLatest(response.items)
            nextCursor = response.nextCursor
            lastRefreshDate = Date() // only on success — a failed fetch shouldn't count as "fresh"
        } catch {
            print("[GenerationManager] refresh error: \(error)")
        }
        hasLoadedOnce = true
    }

    // Merges freshly-polled items into `generations` in place — updates existing
    // rows by id and prepends new ones, without reassigning the whole array.
    // Polling runs every 3s while a job is active; replacing `generations`
    // outright reorders the feed whenever the server's sort shifts (e.g. an
    // active item's updatedAt bumps it), which reflows card positions mid-tap
    // and can route a tap to the wrong card's button. It also silently dropped
    // pages appended by loadNextPage(). Preserving existing indices avoids both.
    private func mergeLatest(_ freshItems: [GenerationItem]) {
        var indexByID: [String: Int] = [:]
        for (index, item) in generations.enumerated() {
            indexByID[item.id] = index
        }

        var newItems: [GenerationItem] = []
        for item in freshItems {
            if let index = indexByID[item.id] {
                generations[index] = item
            } else {
                newItems.append(item)
            }
        }
        guard !newItems.isEmpty else { return }
        if isInteracting {
            // Buffer instead of prepending now — see isInteracting doc comment above.
            pendingNewItems.append(contentsOf: newItems)
        } else {
            generations.insert(contentsOf: newItems, at: 0)
        }
    }

    // Prepends items buffered by mergeLatest() while isInteracting was true.
    // Called the moment the touch lifts (isInteracting didSet above).
    private func flushPendingInserts() {
        guard !pendingNewItems.isEmpty else { return }
        generations.insert(contentsOf: pendingNewItems, at: 0)
        pendingNewItems.removeAll()
    }

    // Load next page (pagination, cursor-based)
    func loadNextPage() async {
        guard !isLoading, let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await APIClient.shared.fetchGenerations(cursor: cursor)
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
