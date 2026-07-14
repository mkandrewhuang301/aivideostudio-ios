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
// The "+" tile is pinned at local x = `state.currentTime * pxPerSecond`: because this row lives
// inside TimelineTrackView's content stack, which the parent translates by
// `viewportWidth/2 - currentTime*pxPerSecond`, a tile at that local x always resolves to
// `viewportWidth/2` on screen — i.e. it rides along at the fixed-center playhead position exactly
// like the clip row's inline add-tile, without this plan needing to touch TimelineTrackView.swift.

import SwiftUI

struct TextOverlayTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double

    private let rowHeight: CGFloat = 30
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0) // #8C59FF

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.project.textOverlays) { overlay in
                TextOverlayPillView(
                    overlay: overlay,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .text(overlay.id),
                    onSelect: { state.select(.text(overlay.id)) },
                    onRetime: { start, end in
                        Task { await retime(id: overlay.id, start: start, end: end) }
                    },
                    onDelete: {
                        Task { await delete(id: overlay.id) }
                    }
                )
                .offset(x: overlay.startSeconds * pxPerSecond)
            }

            addTextTile
                .offset(x: state.currentTime * pxPerSecond - 11)
        }
        .frame(height: rowHeight)
    }

    // MARK: - Row-level "+" — appends a new default overlay at the playhead (D-09-style inline add)

    private var addTextTile: some View {
        Button {
            Task { await addDefaultOverlay() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(accent.opacity(0.7), lineWidth: 1)
                )
        }
        .accessibilityLabel("Add text overlay")
    }

    private func addDefaultOverlay() async {
        do {
            try await projectManager.addTextOverlay(
                text: "Tap to edit",
                xNorm: 0.5,
                yNorm: 0.5,
                startSeconds: state.currentTime,
                endSeconds: state.currentTime + 3
            )
        } catch {
            print("[TextOverlayTrackRow] addTextOverlay error: \(error)")
        }
    }

    // MARK: - Mutations

    private func retime(id: String, start: Double, end: Double) async {
        do {
            try await projectManager.updateTextOverlay(textId: id, startSeconds: start, endSeconds: end)
        } catch {
            print("[TextOverlayTrackRow] retime error: \(error)")
        }
    }

    private func delete(id: String) async {
        do {
            try await projectManager.deleteTextOverlay(textId: id)
            if state.selection == .text(id) { state.select(.none) }
        } catch {
            print("[TextOverlayTrackRow] delete error: \(error)")
        }
    }
}
