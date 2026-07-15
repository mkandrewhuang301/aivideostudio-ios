// CaptionTrackRow.swift
// Fantasia
// Phase 13, Plan 15: the real Captions track rail (SC5) — replaces plan 12's `EmptyView` stub.
// Renders one CaptionPillView per `state.project.captionCues`, freeform-positioned at
// `xOffset = startSeconds * pxPerSecond` within the row (same content-scrolls-under-fixed-
// playhead model as TimelineTrackView's ruler/clip row and TextOverlayTrackRow/AudioTrackRow),
// plus the empty-state auto-generate prompt and the bulk "Delete All Captions" long-press action
// (D-13).
//
// SAME struct name/signature as plan 12's stub (`CaptionTrackRow(state:, pxPerSecond:)`) —
// TimelineTrackView.swift (already compiled/wired, stack order Text -> Audio -> Captions) needs no
// changes.
//
// The live karaoke rendering (fullscreen/preview player overlay) and the Caption Style sheet are
// deliberately deferred to Plan 16 (a distinct subsystem: preview/fullscreen rendering vs. this
// plan's timeline editing) — see 13-15-PLAN.md's objective.

import SwiftUI

struct CaptionTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double
    /// 13-22 i14: the timeline's own viewport width + LIVE contentOffset — see AudioTrackRow's
    /// identical param doc comment.
    let viewportWidth: CGFloat
    let contentOffset: CGFloat

    private let rowHeight: CGFloat = 30

    @State private var editingCueId: String?
    @State private var showDeleteAllConfirm = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var edgeScrollRate: Double?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Long-press ANYWHERE on the track row background (only meaningful once >=1 cue
            // exists) reveals the bulk "Delete All Captions" confirmation (D-13) — the one
            // Captions action that gets a confirmation dialog, unlike every per-cue mutation
            // below which is instant + toast.
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    guard !state.project.captionCues.isEmpty else { return }
                    showDeleteAllConfirm = true
                }

            // Pure pill rail (13-19 Task E) — the "No captions yet / Auto-generate…" hint used to
            // render HERE, inside the scrolling content, so the parent's contentOffset shoved it
            // off-screen (the bug the ideal-vs-current diff caught). Auto-generate now lives
            // exclusively on EditorBottomBar's Captions action (disabled until there's captionable
            // media); an empty Captions track is simply blank, matching the Text/Audio rails.
            ForEach(state.project.captionCues) { cue in
                CaptionPillView(
                    cue: cue,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .caption(cue.id),
                    isEditing: editingCueId == cue.id,
                    onSelect: {
                        // F10 (Plan 13-21): animated snap to this cue's own window before selecting.
                        state.snapPlayhead(toWindow: cue.startSeconds, cue.endSeconds)
                        state.select(.caption(cue.id))
                    },
                    onRetime: { start, end in
                        retime(id: cue.id, start: start, end: end)
                    },
                    onWordsCommit: { words in
                        Task { await commitWords(id: cue.id, words: words) }
                    },
                    onEditToggle: {
                        editingCueId = (editingCueId == cue.id) ? nil : cue.id
                    },
                    contentOffset: contentOffset,
                    onBodyDragLocationChanged: { fingerX in
                        updateEdgeScroll(fingerX: fingerX)
                    },
                    onBodyDragEnded: {
                        stopEdgeScroll()
                    }
                )
                .offset(x: cue.startSeconds * pxPerSecond)
            }
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            "Delete all captions?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task { await deleteAllCaptions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every caption in this project. This cannot be undone.")
        }
        // Contextual bar's caption "Edit" action (13-19 Task A) signals here rather than owning
        // its own editing-mode entry point — mirrors TextOverlayItemView's editRequestedTextId
        // trigger below.
        .onChange(of: state.editRequestedCaptionId) { _, requestedId in
            guard let requestedId, state.project.captionCues.contains(where: { $0.id == requestedId }) else { return }
            editingCueId = requestedId
            state.editRequestedCaptionId = nil
        }
    }

    // MARK: - Mutations

    // F8 (Plan 13-21): same debounce treatment as the other pill rows' retime — `onRetime` fires
    // continuously during an edge-handle drag, once at release for a body-move.
    @State private var retimeBeforeByCue: [String: (start: Double, end: Double)] = [:]
    @State private var retimeDebounceTasks: [String: Task<Void, Never>] = [:]

    // 13-23 J1: optimistic commit — see TimelineTrackView.updateClipTrim's identical doc comment.
    // Synchronous entry point invoked directly from CaptionPillView.onRetime's `.onEnded`, in the
    // SAME call frame that resets `dragTranslation`/preview vars.
    private func retime(id: String, start: Double, end: Double) {
        guard let idx = state.project.captionCues.firstIndex(where: { $0.id == id }) else { return }
        let committedStart = state.project.captionCues[idx].startSeconds
        let committedEnd = state.project.captionCues[idx].endSeconds
        if retimeBeforeByCue[id] == nil {
            retimeBeforeByCue[id] = (committedStart, committedEnd)
        }
        state.project.captionCues[idx].startSeconds = start
        state.project.captionCues[idx].endSeconds = end

        Task {
            do {
                try await projectManager.updateCaptionCue(cueId: id, startSeconds: start, endSeconds: end)
                syncProjectFromManager()
            } catch {
                print("[CaptionTrackRow] retime error: \(error)")
                if let revertIdx = state.project.captionCues.firstIndex(where: { $0.id == id }) {
                    state.project.captionCues[revertIdx].startSeconds = committedStart
                    state.project.captionCues[revertIdx].endSeconds = committedEnd
                }
                showToast("Couldn't save change")
            }
            retimeDebounceTasks[id]?.cancel()
            retimeDebounceTasks[id] = Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                guard let before = retimeBeforeByCue[id] else { return }
                retimeBeforeByCue[id] = nil
                retimeDebounceTasks[id] = nil
                state.history.record(UndoableAction(
                    label: "Retime caption",
                    undo: { try await projectManager.updateCaptionCue(cueId: id, startSeconds: before.start, endSeconds: before.end) },
                    redo: { try await projectManager.updateCaptionCue(cueId: id, startSeconds: start, endSeconds: end) }
                ))
            }
        }
    }

    // F8: caption word edits (tap-to-edit TextField commit) fire once per commit — single record.
    private func commitWords(id: String, words: [CaptionWord]) async {
        let before = state.project.captionCues.first(where: { $0.id == id })?.words
        do {
            try await projectManager.updateCaptionCue(cueId: id, words: words)
            syncProjectFromManager()
            if let before {
                state.history.record(UndoableAction(
                    label: "Edit caption words",
                    undo: { try await projectManager.updateCaptionCue(cueId: id, words: before) },
                    redo: { try await projectManager.updateCaptionCue(cueId: id, words: words) }
                ))
            }
        } catch {
            print("[CaptionTrackRow] words commit error: \(error)")
        }
    }

    /// Bulk "Delete All Captions" (D-13) — clears the entire track at once, distinct from the
    /// per-cue instant delete above.
    private func deleteAllCaptions() async {
        do {
            try await projectManager.deleteAllCaptions()
            if case .caption = state.selection { state.select(.none) }
            editingCueId = nil
            syncProjectFromManager()
            showToast("All captions removed")
        } catch {
            print("[CaptionTrackRow] deleteAllCaptions error: \(error)")
        }
    }

    /// Reflects ProjectManager's persisted result back onto the shared EditorState clock — mirrors
    /// AudioTrackRow/TimelineTrackView's `syncProjectFromManager()` (EditorState "owns
    /// playback/selection state, not persistence" per its own doc comment).
    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }

    // MARK: - 13-22 i14: edge auto-scroll while dragging a pill's body — see
    // TextOverlayTrackRow's identical implementation for the full doc comment.

    private func updateEdgeScroll(fingerX: CGFloat) {
        let newRate = EdgeAutoScroll.rate(fingerX: fingerX, viewportWidth: viewportWidth, pxPerSecond: pxPerSecond)
        guard newRate != edgeScrollRate else { return }
        edgeScrollRate = newRate
        edgeScrollTask?.cancel()
        guard let rate = newRate else {
            edgeScrollTask = nil
            state.isScrubbing = false
            return
        }
        state.isScrubbing = true
        edgeScrollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16)) // ~60Hz
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    state.currentTime = state.clampTime(state.currentTime + rate / 60.0)
                }
            }
        }
    }

    private func stopEdgeScroll() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        edgeScrollRate = nil
        state.isScrubbing = false
    }
}
