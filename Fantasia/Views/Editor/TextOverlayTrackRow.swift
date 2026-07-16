// TextOverlayTrackRow.swift
// Fantasia
// Phase 13, Plan 13: the real Text overlay track rail (SC3) — replaces plan 12's placeholder stub.
// Renders one TextOverlayPillView per `state.project.textOverlays`, freeform-positioned at
// `x = startSeconds * pxPerSecond` (same content-scrolls-under-fixed-playhead model as
// TimelineTrackView's ruler/clip row).
//
// Plan 13-26 M8: CapCut-style text ROWS replace 13-20 i2's one-row-per-overlay stacking. Multiple
// texts share one 28pt row as long as their time ranges don't overlap; overlapping-time texts
// stack into separate rows. Each overlay renders at `y = effectiveRow × 28`. Row membership:
// an overlay's persisted `rowIndex` wins; overlays without one (legacy data) get a DETERMINISTIC
// greedy assignment (`effectiveRows(for:)` below — sorted by startSeconds, ties by id, each takes
// the lowest row whose already-placed occupants it doesn't overlap; no writes for legacy data).
// Long-press (0.4s) lifts a pill and moves it across time (horizontal) AND rows (vertical, finger
// crossing a 28pt band; one row below the last = create a new row); dropping onto an overlap
// bumps down to the first free row. TimelineTrackView hosts this inside its vertically-scrollable tracks
// viewport; its textSectionHeight math mirrors `effectiveRows` so section height =
// (maxOccupiedRow + 1) × 28, minimum one row.

import SwiftUI
import UIKit

struct TextOverlayTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double
    var rowHeight: CGFloat = 28
    /// 13-22 i14: the timeline's own viewport width + LIVE contentOffset — needed to detect a
    /// lifted drag's finger nearing either edge and to compensate this row's pills' local offset
    /// while an edge-auto-scroll loop is running (see AudioTrackRow's identical param doc, and
    /// EdgeAutoScroll.swift).
    let viewportWidth: CGFloat
    let contentOffset: CGFloat
    /// 13-23 J1: surfaces "Couldn't save change" when an optimistic retime's PATCH fails and the
    /// local value has been reverted — see TimelineTrackView's identical param doc comment.
    var onError: (String) -> Void = { _ in }
    /// 13-26 M7: adds the default "Text" overlay at the playhead — the SAME call EditorBottomBar's
    /// Text action makes, threaded EditorView → TimelineTrackView → here. See AudioTrackRow's
    /// onAddAudio doc comment for why the placeholder moved INSIDE the row (single source of
    /// geometry — no parallel overlay layer whose y-bands could drift from the real rows').
    var onAddDefaultText: () -> Void = {}

    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var edgeScrollRate: Double?

    // 13-26 M8: lift state — which overlay is lifted, its live target row band, and the drag's
    // content-space x delta (location − startLocation in the "textSection" space, which captures
    // BOTH finger movement and content scrolled underneath by an edge auto-scroll loop).
    @State private var liftedOverlayId: String? = nil
    @State private var liftTargetRow: Int? = nil
    @State private var liftDeltaX: CGFloat = 0

    // MARK: - 13-26 M8.1: deterministic row assignment

    /// Effective row per overlay id: a persisted `rowIndex` wins outright; every nil-row overlay
    /// then gets a GREEDY assignment — processed in (startSeconds, id) order, each takes the
    /// LOWEST row where its [start, end] doesn't overlap any already-placed overlay (persisted or
    /// previously computed) in that row. Deterministic; performs no writes for legacy data.
    /// Touching endpoints (end == other.start) do NOT count as overlap, so back-to-back texts
    /// share a row.
    static func effectiveRows(for overlays: [TextOverlay]) -> [String: Int] {
        var result: [String: Int] = [:]
        var rowIntervals: [Int: [(start: Double, end: Double)]] = [:]

        for overlay in overlays {
            if let row = overlay.rowIndex.map({ max(0, $0) }) {
                result[overlay.id] = row
                rowIntervals[row, default: []].append((overlay.startSeconds, overlay.endSeconds))
            }
        }

        let unplaced = overlays
            .filter { $0.rowIndex == nil }
            .sorted { ($0.startSeconds, $0.id) < ($1.startSeconds, $1.id) }
        for overlay in unplaced {
            var row = 0
            while (rowIntervals[row] ?? []).contains(where: {
                overlay.startSeconds < $0.end && overlay.endSeconds > $0.start
            }) {
                row += 1
            }
            result[overlay.id] = row
            rowIntervals[row, default: []].append((overlay.startSeconds, overlay.endSeconds))
        }
        return result
    }

    /// Occupied row count (max effective row + 1), minimum 1 — TimelineTrackView's
    /// textSectionHeight reads this same helper so section height and pill layout can't drift.
    static func rowCount(for overlays: [TextOverlay]) -> Int {
        max(1, (effectiveRows(for: overlays).values.max() ?? 0) + 1)
    }

    var body: some View {
        let rowsById = Self.effectiveRows(for: state.project.textOverlays)
        let baseRowCount = Self.rowCount(for: state.project.textOverlays)
        // While lifted, targeting one row BELOW the last is allowed (= create a new row): grow
        // the section live so the highlighted band is actually visible.
        let rowCount = max(baseRowCount, liftedOverlayId != nil ? (liftTargetRow ?? 0) + 1 : 0)

        ZStack(alignment: .topLeading) {
            if state.project.textOverlays.isEmpty {
                textPlaceholderRow
                    .frame(height: rowHeight, alignment: .leading)
            } else {
                ForEach(state.project.textOverlays) { overlay in
                    TextOverlayPillView(
                        overlay: overlay,
                        pxPerSecond: pxPerSecond,
                        isSelected: state.selection == .text(overlay.id),
                        isZooming: state.isZooming,
                        onSelect: {
                            // F10 (Plan 13-21): animated snap to this pill's own window before selecting.
                            state.snapPlayhead(toWindow: overlay.startSeconds, overlay.endSeconds)
                            state.select(.text(overlay.id))
                        },
                        onRetime: { start, end in
                            retime(id: overlay.id, start: start, end: end)
                        },
                        contentOffset: contentOffset,
                        onLift: { beginLift(overlay: overlay, currentRow: rowsById[overlay.id] ?? 0) },
                        onLiftDragChanged: { _, location, startLocation in
                            liftDragChanged(overlay: overlay, location: location, startLocation: startLocation)
                        },
                        liftedRowOffsetY: CGFloat(
                            liftedOverlayId == overlay.id
                                ? (liftTargetRow ?? (rowsById[overlay.id] ?? 0)) - (rowsById[overlay.id] ?? 0)
                                : 0
                        ) * rowHeight,
                        onLiftEnded: { commitLift(overlay: overlay, currentRow: rowsById[overlay.id] ?? 0) },
                        onLiftCancelled: { cancelLift(overlayId: overlay.id) }
                    )
                    .offset(
                        x: overlay.startSeconds * pxPerSecond,
                        y: CGFloat(rowsById[overlay.id] ?? 0) * rowHeight
                    )
                    .zIndex(liftedOverlayId == overlay.id ? 10 : 0)
                }
            }
        }
        .frame(height: CGFloat(rowCount) * rowHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // M8: the lift drag's coordinate space — section-local, so `location.y / rowHeight` IS the
        // target row band, and location.x is content-space (stable across edge auto-scroll).
        .coordinateSpace(name: "textSection")
    }

    // MARK: - 13-26 M7: empty-state placeholder (moved back in from TimelineTrackView.railOverlay)

    // NO Button wrapper — drawn shape + explicit .contentShape + .onTapGesture, matching
    // AudioTrackRow.audioPlaceholderPill's structure (see its comment).
    private var textPlaceholderRow: some View {
        Color.white.opacity(0.06)
            .frame(width: max(state.visualStripEndPx(pxPerSecond: pxPerSecond), 60), height: rowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                #if DEBUG
                print("[hit] add-text placeholder tapped")
                #endif
                onAddDefaultText()
            }
            .accessibilityLabel("Add text")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - 13-26 M8: lift & move (long-press drag across time + rows)

    private func beginLift(overlay: TextOverlay, currentRow: Int) {
        guard !state.isZooming else { return }
        liftedOverlayId = overlay.id
        liftTargetRow = currentRow
        liftDeltaX = 0
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        state.select(.text(overlay.id))
    }

    private func liftDragChanged(overlay: TextOverlay, location: CGPoint, startLocation: CGPoint) {
        guard !state.isZooming, liftedOverlayId == overlay.id else { return }
        liftDeltaX = location.x - startLocation.x

        // Vertical: the finger's y within the text section picks the target row band; one row
        // BELOW the last existing row is allowed (create a new row).
        let maxRow = (Self.effectiveRows(for: state.project.textOverlays).values.max() ?? 0)
        let target = min(max(Int(floor(location.y / rowHeight)), 0), maxRow + 1)
        if target != liftTargetRow {
            liftTargetRow = target
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // Edge auto-scroll expects a viewport-space finger x: section content x + contentOffset.
        updateEdgeScroll(fingerX: location.x + contentOffset)
    }

    private func commitLift(overlay: TextOverlay, currentRow: Int) {
        guard liftedOverlayId == overlay.id else { return }
        stopEdgeScroll()
        let deltaSeconds = Double(liftDeltaX) / pxPerSecond
        let targetRow = liftTargetRow ?? currentRow
        liftedOverlayId = nil
        liftTargetRow = nil
        liftDeltaX = 0

        let duration = overlay.endSeconds - overlay.startSeconds
        let newStart = max(0, overlay.startSeconds + deltaSeconds)
        let newEnd = newStart + duration
        guard abs(newStart - overlay.startSeconds) > 0.0001 || targetRow != currentRow else { return }

        // Drop rule: walk downward from the hovered row until the moved interval is free. The walk
        // is unbounded by the current max row, so maxRow + 1 naturally creates a new row.
        let rowsById = Self.effectiveRows(for: state.project.textOverlays)
        var resolvedRow = targetRow
        while state.project.textOverlays.contains(where: { other in
            other.id != overlay.id
                && (rowsById[other.id] ?? 0) == resolvedRow
                && newStart < other.endSeconds
                && newEnd > other.startSeconds
        }) {
            resolvedRow += 1
        }

        // Optimistic commit + undo (before-values captured from the pre-mutation `overlay`).
        guard let idx = state.project.textOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        let before = (start: overlay.startSeconds, end: overlay.endSeconds, row: currentRow)
        state.project.textOverlays[idx].startSeconds = newStart
        state.project.textOverlays[idx].endSeconds = newEnd
        state.project.textOverlays[idx].rowIndex = resolvedRow

        let id = overlay.id
        Task {
            do {
                try await projectManager.updateTextOverlay(
                    textId: id, rowIndex: resolvedRow, startSeconds: newStart, endSeconds: newEnd
                )
                syncProjectFromManager()
                state.history.record(UndoableAction(
                    label: "Move text",
                    undo: {
                        try await projectManager.updateTextOverlay(
                            textId: id, rowIndex: before.row, startSeconds: before.start, endSeconds: before.end
                        )
                    },
                    redo: {
                        try await projectManager.updateTextOverlay(
                            textId: id, rowIndex: resolvedRow, startSeconds: newStart, endSeconds: newEnd
                        )
                    }
                ))
            } catch {
                print("[TextOverlayTrackRow] move error: \(error)")
                if let revertIdx = state.project.textOverlays.firstIndex(where: { $0.id == id }) {
                    state.project.textOverlays[revertIdx].startSeconds = before.start
                    state.project.textOverlays[revertIdx].endSeconds = before.end
                    state.project.textOverlays[revertIdx].rowIndex = overlay.rowIndex
                }
                onError("Couldn't save change")
            }
        }
    }

    private func cancelLift(overlayId: String) {
        guard liftedOverlayId == overlayId else { return }
        stopEdgeScroll()
        liftedOverlayId = nil
        liftTargetRow = nil
        liftDeltaX = 0
    }

    // MARK: - Mutations

    // EditProject is a VALUE type — each success path must reconcile the MANAGER's mutated copy
    // back onto state.project or the pill snaps back / lingers after delete (13-20 i1 sweep).

    // F8 (Plan 13-21): same debounce treatment as AudioTrackRow/TimelineTrackView.updateClipTrim —
    // `onRetime` fires continuously during an edge-handle drag.
    @State private var retimeBeforeByOverlay: [String: (start: Double, end: Double)] = [:]
    @State private var retimeDebounceTasks: [String: Task<Void, Never>] = [:]

    // 13-23 J1: optimistic commit — see TimelineTrackView.updateClipTrim's identical doc comment.
    // Synchronous entry point invoked directly from TextOverlayPillView.onRetime's `.onEnded`, in
    // the SAME call frame that resets the preview vars, so the pill's next render reflects the
    // FINAL committed position immediately — no stale-then-jump repaint.
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

    // MARK: - 13-22 i14: edge auto-scroll while dragging a lifted pill. Mirrors AudioTrackRow/
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
