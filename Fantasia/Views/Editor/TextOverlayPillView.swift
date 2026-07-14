// TextOverlayPillView.swift
// Fantasia
// Phase 13, Plan 13: one Text overlay's amber timeline pill (SC3) — body-drag to move (retime),
// edge-handle drag to trim the play window independently, mirroring ClipPillView's gesture
// layering exactly (`.contentShape(Rectangle()).onTapGesture{onSelect()}.highPriorityGesture
// (bodyDragGesture)` + `.highPriorityGesture` on 12pt-wide invisible edge-handle overlays).
// Selecting a pill sets `state.selection = .text(id)`, which also selects the same overlay
// on-canvas (TextOverlayCanvasView, Task 1).
//
// 26-30pt pill height / 12pt edge handles are HIG-exempt continuous-drag hit targets per
// 13-UI-SPEC.md (same exemption ClipPillView's edge handles rely on) — do not enlarge to 44pt.

import SwiftUI

struct TextOverlayPillView: View {
    let overlay: TextOverlay
    let pxPerSecond: Double
    let isSelected: Bool
    let onSelect: () -> Void
    /// Fires once, on drag release (body move OR edge-handle retime), with the final
    /// (startSeconds, endSeconds) — the CALLER (TextOverlayTrackRow) PATCHes via
    /// `ProjectManager.updateTextOverlay`.
    let onRetime: (Double, Double) -> Void
    /// Instant delete (no confirmation, per 13-UI-SPEC's Copywriting Contract) — the caller
    /// performs the mutation + toast.
    let onDelete: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStartTime: Double? = nil
    @State private var rightDragStartTime: Double? = nil

    private let amber = Color(red: 0.851, green: 0.478, blue: 0.169)      // #D97A2B
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)  // #FF5470
    private let pillHeight: CGFloat = 28

    private var width: Double { max((overlay.endSeconds - overlay.startSeconds) * pxPerSecond, 30) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(amber)
            Text(overlay.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .frame(width: width, height: pillHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white : .clear, lineWidth: 2)
        )
        .offset(x: dragTranslation)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .highPriorityGesture(bodyDragGesture)
        .overlay(alignment: .leading) {
            if isSelected { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected { handle.highPriorityGesture(rightHandleGesture) }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected { deleteButton }
        }
    }

    private var handle: some View {
        ZStack {
            Color.white.opacity(0.001) // invisible but hit-testable — widens the drag target
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: 2, height: 14)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(destructive, in: Circle())
        }
        .offset(x: 4, y: -6)
        .accessibilityLabel("Delete text overlay")
    }

    // MARK: - Body drag (move — retimes the whole [start, end] window together)

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                dragTranslation = 0
                let duration = overlay.endSeconds - overlay.startSeconds
                let newStart = max(0, overlay.startSeconds + deltaSeconds)
                onRetime(newStart, newStart + duration)
            }
    }

    // MARK: - Edge-handle retime (start/end independently)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStartTime == nil { leftDragStartTime = overlay.startSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                var newStart = (leftDragStartTime ?? overlay.startSeconds) + deltaSeconds
                newStart = max(0, min(newStart, overlay.endSeconds - 0.3))
                onRetime(newStart, overlay.endSeconds)
            }
            .onEnded { _ in leftDragStartTime = nil }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if rightDragStartTime == nil { rightDragStartTime = overlay.endSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                let newEnd = max(overlay.startSeconds + 0.3, (rightDragStartTime ?? overlay.endSeconds) + deltaSeconds)
                onRetime(overlay.startSeconds, newEnd)
            }
            .onEnded { _ in rightDragStartTime = nil }
    }
}
