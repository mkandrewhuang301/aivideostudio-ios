// GenerationManager.swift
// Fantasia
// Central state manager for the generation lifecycle.
// Pattern: mirrors CreditManager — @Observable @MainActor final class.
// D-03: polls GET /api/generations every 3 seconds while any job is pending/processing.
// D-03: push notification triggers an immediate refresh via refreshOnNotification().

import Foundation
import FirebaseAuth
import Network

// CLAUDE.md: all new iOS managers use @Observable @MainActor final class pattern
@Observable
@MainActor
final class GenerationManager {
    private static let snapshotName = "generationsSnapshot"

    // Drives the "Waiting for connection…" card message in place of the elapsed-time tier
    // messages (Issue 2) — cosmetic only, does not pause the progress curve.
    var isOnline: Bool = true
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "GenerationManager.pathMonitor")

    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    deinit {
        pathMonitor.cancel()
    }
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

    /// True while Feed/Library report an active touch anywhere in their list. While true,
    /// newly-discovered items from mergeLatest() are buffered instead of being prepended
    /// immediately — prepending mid-touch shifts every card down by a row and can route a
    /// button's touch-up onto whatever card slides into that screen position. Flushed via
    /// flushPendingInserts() the moment the touch lifts.
    ///
    /// Gesture threshold: every call site that attaches this buffering gesture DIRECTLY TO THE
    /// SCROLLVIEW ITSELF uses DragGesture(minimumDistance: 20), NOT 0. A 0-distance DragGesture
    /// attached to a ScrollView (even via .simultaneousGesture) engages on touch-down and wins
    /// UIKit gesture arbitration on a quick flick FROM REST, so the scroll view never claims the
    /// flick and the list doesn't move — while a flick mid-deceleration works because content
    /// touches aren't delayed then. Raising the threshold to 20pt (the stable value for a
    /// ScrollView-attached gesture; <=15 is flaky) lets the scroll view claim scroll-intent
    /// movement first. Tradeoff: this now engages only on a genuine scroll drag (>=20pt), not on
    /// a stationary tap. That's intentional — buffering during an active scroll is the case that
    /// matters, and it also eliminates the old stuck-flag class of bug (a tap that opened a sheet
    /// mid-touch cancelled the 0-distance recognizer so .onEnded never fired, wedging this flag
    /// true forever and silently poisoning merges app-wide until some unrelated drag flushed it).
    ///
    /// This 20pt figure is NOT a universal safe threshold — it's specific to gestures attached to
    /// the ScrollView itself, which only observe touches and never compete for them. A SwiftUI
    /// DragGesture attached to CONTENT INSIDE a ScrollView genuinely competes with the
    /// ScrollView's own pan recognizer, and on iOS 18 NO minimumDistance makes it safe: 30 was
    /// tried for GenerateView's SwipeToDeleteRow and fast flicks from rest were still eaten
    /// (bisect-confirmed on device 2026-07-06). Content-attached swipes must instead use a UIKit
    /// UIPanGestureRecognizer direction-gated in gestureRecognizerShouldBegin (see
    /// HorizontalSwipeToDeletePan in GenerateView.swift and
    /// .planning/notes/2026-07-06-generate-fast-swipe-investigation.md).
    ///
    /// The watchdog below still self-heals a stuck flag without weakening the real protection:
    /// every onChanged tick (fired continuously through a genuine drag) refreshes the deadline,
    /// so only a truly abandoned/cancelled gesture — one that stops emitting updates — times out.
    var isInteracting = false {
        didSet {
            if isInteracting {
                interactionWatchdogToken &+= 1
                let token = interactionWatchdogToken
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.interactionWatchdogToken == token, self.isInteracting else { return }
                    self.isInteracting = false
                }
            } else if oldValue == true {
                flushPendingInserts()
            }
        }
    }
    private var interactionWatchdogToken = 0
    private var pendingNewItems: [GenerationItem] = []

    // Remix state: set before switching to Generate tab (D-35)
    var pendingRemix: GenerationItem? = nil

    // Reference state: set before switching to Generate tab — attaches this
    // generation's own output as a reference input for a new generation.
    var pendingReference: GenerationItem? = nil

    // "Name as reference" state (Issue 9): set from any media surface (Library tile, detail
    // sheet, fullscreen viewer) before switching to Generate tab, which owns the naming sheet.
    var pendingNameAsReference: GenerationItem? = nil

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
        if forceRefresh {
            // Fire an immediate one-off refresh regardless of the existing polling loop, so a
            // just-submitted item enters the feed without waiting for the next 3s tick (Bug B).
            // refresh() itself guards `!isLoading`, so this is a no-op if a fetch is already
            // in flight — no double-fetch risk.
            Task { [weak self] in await self?.refresh() }
        }

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

    /// Loads the last-persisted list for the current user so Generate/Library render instantly
    /// on cold start instead of showing a spinner until GET /api/generations responds. Call once
    /// after auth restores (ContentView, alongside creditManager.hydrateFromCache()) — this only
    /// fills the gap; lastRefreshDate stays nil so the next startPolling()/refreshIfStale() still
    /// fetches and silently reconciles via mergeLatest.
    func hydrateFromSnapshot() {
        guard generations.isEmpty, let uid = Auth.auth().currentUser?.uid,
              let snapshot = ListSnapshotStore.load([GenerationItem].self, name: Self.snapshotName, uid: uid),
              !snapshot.items.isEmpty else { return }
        // Belt-and-braces: dedupe in case a bad snapshot (pre-dedupe-fix pagination) was
        // already written to disk before this fix shipped.
        var seen = Set<String>()
        generations = snapshot.items.filter { seen.insert($0.id).inserted }
        hasLoadedOnce = true
    }

    /// Clears in-memory state and the persisted snapshot for a signed-out user, so their history
    /// never flashes for the next account that signs in. Pass the uid of the user who just
    /// signed out (Auth.auth().currentUser is already nil by the time this fires).
    func clearSnapshot(uid: String) {
        ListSnapshotStore.clear(name: Self.snapshotName, uid: uid)
        generations = []
        hasLoadedOnce = false
        lastRefreshDate = nil
    }

    private func persistSnapshot() {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        // Cap so a long paginated session doesn't grow the on-disk snapshot unbounded.
        ListSnapshotStore.save(Array(generations.prefix(100)), name: Self.snapshotName, uid: uid)
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
            mergeLatest(response.items, reconcileDeletions: true)
            nextCursor = response.nextCursor
            lastRefreshDate = Date() // only on success — a failed fetch shouldn't count as "fresh"
            persistSnapshot()
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
    // reconcileDeletions: true only for a cursor-less first-page refresh() — prunes items that
    // fall within the freshly-fetched page's createdAt window but are no longer present in the
    // server's response (deleted/quarantined server-side), so they don't resurrect via
    // persistSnapshot() on relaunch (Bug A). Paginated loadNextPage() merges must never prune,
    // since older items simply not present in a given page are NOT deletions.
    private func mergeLatest(_ freshItems: [GenerationItem], reconcileDeletions: Bool = false) {
        if reconcileDeletions, let oldestFresh = freshItems.map({ $0.createdAt }).min() {
            let freshIDs = Set(freshItems.map { $0.id })
            generations.removeAll { item in
                !item.isLocalPlaceholder && !freshIDs.contains(item.id) && item.createdAt >= oldestFresh
            }
        }

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
            // The cold-start snapshot can already contain page-2+ items (it persists the whole
            // in-memory list), so a plain append would introduce duplicate ids into the array.
            // Duplicate ids break ForEach's identity system: cards render blank, disappear, or
            // land at phantom offsets instead of just being redundant.
            let existingIds = Set(generations.map(\.id))
            let newItems = response.items.filter { !existingIds.contains($0.id) }
            generations.append(contentsOf: newItems)
            nextCursor = response.nextCursor
        } catch {
            print("[GenerationManager] loadNextPage error: \(error)")
        }
    }

    // Remove deleted generation from local state (called after DELETE /api/generations/:id)
    func removeGeneration(id: String) {
        generations.removeAll { $0.id == id }
    }

    // Optimistic favorite toggle (FAV-01): flip local state now, revert if the PATCH fails.
    func setFavorite(id: String, isFavorite: Bool) async {
        guard let index = generations.firstIndex(where: { $0.id == id }) else { return }
        let previous = generations[index].isFavorite
        generations[index].isFavorite = isFavorite
        do {
            try await APIClient.shared.setFavorite(id: id, isFavorite: isFavorite)
        } catch {
            print("[GenerationManager] setFavorite error: \(error)")
            if let i = generations.firstIndex(where: { $0.id == id }) {
                generations[i].isFavorite = previous
            }
        }
    }

    // Optimistic-submit support (Issue 5) — see GenerateView.dispatchGeneration().
    func insertLocalPlaceholder(_ item: GenerationItem) {
        generations.insert(item, at: 0)
    }

    func removeLocalPlaceholder(id: String) {
        generations.removeAll { $0.id == id }
    }

    private var hasActiveJobs: Bool {
        generations.contains { $0.status == .pending || $0.status == .processing }
    }
}
