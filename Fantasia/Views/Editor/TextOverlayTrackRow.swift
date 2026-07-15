// TextOverlayTrackRow.swift
// Fantasia
// Phase 13, Plan 13: the real Text overlay track rail (SC3) — replaces plan 12's placeholder stub.
// Renders one TextOverlayPillView per `state.project.textOverlays`, freeform-positioned at
// `xOffset = startSeconds * pxPerSecond` within the row (same content-scrolls-under-fixed-playhead
// model as TimelineTrackView's ruler/clip row), plus a row-level "+" affordance that appends a new
// default overlay at the current playhead.
//
// SAME struct name/signature as plan 12's stub (`TextOverlayTrackRow(state:, pxPerSecond:)`) —
// TimelineTrackView.swift (already compiled/wired) needs no changes.
//
// 13-20 i2: each text overlay now gets its OWN row (a `VStack` of one-row-per-item), matching the
// locked sketch's per-item stacking (index.html:389 — `p.style.top=(idx*30)+'px'`) instead of a
// single shared ZStack rail where two overlays active at the same time would visually overlap.
// TimelineTrackView hosts this inside its vertically-scrollable tracks viewport and gives the
// WHOLE stack (this row + AudioTrackRow + CaptionTrackRow) its shared `contentWidth`/
// `contentOffset` — this view only needs to lay out one `pxPerSecond`-scaled pill per row.

import SwiftUI

struct TextOverlayTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double
    var rowHeight: CGFloat = 28
    /// 13-22 i14: the timeline's own viewport width + LIVE contentOffset — needed to detect a
    /// body-drag's finger nearing either edge and to compensate this row's pills' local offset
    /// while an edge-auto-scroll loop is running (see AudioTrackRow's identical param doc, and
    /// EdgeAutoScroll.swift).
    let viewportWidth: CGFloat
    let contentOffset: CGFloat
    /// 13-23 J1: surfaces "Couldn't save change" when an optimistic retime's PATCH fails and the
    /// local value has been reverted — see TimelineTrackView's identical param doc comment.
    var onError: (String) -> Void = { _ in }

    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var edgeScrollRate: Double?

    var body: some View {
        // Pure pill rail (13-19 Task E) — adds now come exclusively from EditorBottomBar's
        // Text action (which makes this exact same addTextOverlay call at the playhead); no
        // per-row "+" tile lives here anymore.
        // F12 (Plan 13-21): the empty-state placeholder row + T rail tile are rendered by
        // TimelineTrackView itself, in its viewport-pinned overlay layer (see AudioTrackRow's
        // identical comment) — this view only reserves the matching `rowHeight`.
        VStack(alignment: .leading, spacing: 0) {
            if state.project.textOverlays.isEmpty {
                Color.clear.frame(height: rowHeight)
            } else {
                ForEach(state.project.textOverlays) { overlay in
                    ZStack(alignment: .topLeading) {
                        TextOverlayPillView(
                            overlay: overlay,
                            pxPerSecond: pxPerSecond,
                            isSelected: state.selection == .text(overlay.id),
                            onSelect: {
                                // F10 (Plan 13-21): animated snap to this pill's own window before selecting.
                                state.snapPlayhead(toWindow: overlay.startSeconds, overlay.endSeconds)
                                state.select(.text(overlay.id))
                            },
                            onRetime: { start, end in
                                retime(id: overlay.id, start: start, end: end)
                            },
                            contentOffset: contentOffset,
                            onBodyDragLocationChanged: { fingerX in
                                updateEdgeScroll(fingerX: fingerX)
                            },
                            onBodyDragEnded: {
                                stopEdgeScroll()
                            }
                        )
                        .offset(x: overlay.startSeconds * pxPerSecond)
                    }
                    .frame(height: rowHeight, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Mutations

    // EditProject is a VALUE type — each success path must reconcile the MANAGER's mutated copy
    // back onto state.project or the pill snaps back / lingers after delete (13-20 i1 sweep).

    // F8 (Plan 13-21): same debounce treatment as AudioTrackRow/TimelineTrackView.updateClipTrim —
    // `onRetime` fires continuously during an edge-handle drag, once at release for a body-move.
    @State private var retimeBeforeByOverlay: [String: (start: Double, end: Double)] = [:]
    @State private var retimeDebounceTasks: [String: Task<Void, Never>] = [:]

    // 13-23 J1: optimistic commit — see TimelineTrackView.updateClipTrim's identical doc comment.
    // Synchronous entry point invoked directly from TextOverlayPillView.onRetime's `.onEnded`, in
    // the SAME call frame that resets `dragTranslation`/preview vars, so the pill's next render
    // reflects the FINAL committed position immediately — no stale-then-jump repaint.
    private func retime(id: String, start: Double, end: Double) {
        guard let idx = state.project.textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let committedStart = state.project.textOverlays[idx].startSeconds
        let committedEnd = state.project.textOverlays[idx].endSeconds
        if retimeBeforeByOverlay[id] == nil {
            retimeBeforeByOverlay[id] = (committedStart, committedEnd)
        }
        state.project.textOverlays[idx].startSeconds = start
        state.project.textOverlays[idx].endSeconds = end

        Task {
            do {
                try await projectManager.updateTextOverlay(textId: id, startSeconds: start, endSeconds: end)
                syncProjectFromManager()
            } catch {
                print("[TextOverlayTrackRow] retime error: \(error)")
                if let revertIdx = state.project.textOverlays.firstIndex(where: { $0.id == id }) {
                    state.project.textOverlays[revertIdx].startSeconds = committedStart
                    state.project.textOverlays[revertIdx].endSeconds = committedEnd
                }
                onError("Couldn't save change")
            }
            scheduleRetimeUndoCommit(id: id, after: (start, end))
        }
    }

    private func scheduleRetimeUndoCommit(id: String, after: (start: Double, end: Double)) {
        retimeDebounceTasks[id]?.cancel()
        retimeDebounceTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let before = retimeBeforeByOverlay[id] else { return }
            retimeBeforeByOverlay[id] = nil
            retimeDebounceTasks[id] = nil
            state.history.record(UndoableAction(
                label: "Retime text",
                undo: { try await projectManager.updateTextOverlay(textId: id, startSeconds: before.start, endSeconds: before.end) },
                redo: { try await projectManager.updateTextOverlay(textId: id, startSeconds: after.start, endSeconds: after.end) }
            ))
        }
    }

    /// Mirrors AudioTrackRow/CaptionTrackRow's identical helper.
    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }

    // MARK: - 13-22 i14: edge auto-scroll while dragging a pill's body. Mirrors AudioTrackRow/
    // CaptionTrackRow's identical implementation (kept per-row rather than shared/refactored into
    // one place — each row owns its own independent Task handle, matching how tracksScrollY/other
    // per-row @State already works in this file family).

    private func updateEdgeScroll(fingerX: CGFloat) {
        let newRate = EdgeAutoScroll.rate(fingerX: fingerX, viewportWidth: viewportWidth, pxPerSecond: pxPerSecond)
        guard newRate != edgeScrollRate else { return }
        edgeScrollRate = newRate
        edgeScrollTask?.cancel()
        guard let rate = newRate else {
            edgeScrollTask = nil
            return
        }
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
    }
}
