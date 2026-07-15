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
                                Task { await retime(id: overlay.id, start: start, end: end) }
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

    private func retime(id: String, start: Double, end: Double) async {
        if retimeBeforeByOverlay[id] == nil, let overlay = state.project.textOverlays.first(where: { $0.id == id }) {
            retimeBeforeByOverlay[id] = (overlay.startSeconds, overlay.endSeconds)
        }
        do {
            try await projectManager.updateTextOverlay(textId: id, startSeconds: start, endSeconds: end)
            syncProjectFromManager()
        } catch {
            print("[TextOverlayTrackRow] retime error: \(error)")
        }
        scheduleRetimeUndoCommit(id: id, after: (start, end))
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
}
