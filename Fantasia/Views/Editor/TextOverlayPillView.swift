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
    /// 13-22 i14: the row's LIVE contentOffset (recomputed every render from state.currentTime) —
    /// needed to compensate this pill's own local offset while an edge-auto-scroll loop is
    /// advancing currentTime mid-drag (see `edgeScrollCompensationX`'s doc comment).
    let contentOffset: CGFloat
    /// Fires the finger's x (in the "timeline" named coordinate space) on every BODY-drag
    /// onChanged — the caller (TextOverlayTrackRow) starts/retargets/stops an edge auto-scroll
    /// loop. Never called during a handle drag.
    var onBodyDragLocationChanged: (CGFloat) -> Void = { _ in }
    /// Fires once on body-drag release — the caller stops any running auto-scroll loop.
    var onBodyDragEnded: () -> Void = {}

    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStartTime: Double? = nil
    @State private var rightDragStartTime: Double? = nil
    // 13-22 i14: captured on the FIRST body-drag onChanged, cleared on release.
    @State private var dragStartContentOffset: CGFloat? = nil
    // 13-22 i4: commit-on-release — onChanged only updates these LOCAL preview values (pill
    // width/offset render from them); onRetime fires ONCE in .onEnded with the final values.
    // Previously onRetime fired on every onChanged (a network PATCH + full re-sync per finger
    // movement). nil = idle, render from `overlay`'s committed values.
    @State private var previewStart: Double? = nil
    @State private var previewEnd: Double? = nil

    private let amber = Color(red: 0.851, green: 0.478, blue: 0.169)      // #D97A2B
    private let pillHeight: CGFloat = 28

    private var effectiveStart: Double { previewStart ?? overlay.startSeconds }
    private var effectiveEnd: Double { previewEnd ?? overlay.endSeconds }
    private var width: Double { max((effectiveEnd - effectiveStart) * pxPerSecond, 30) }
    // The parent row positions this pill via `.offset(x: overlay.startSeconds * pxPerSecond)`
    // using the COMMITTED startSeconds (unchanged until onRetime fires at release) — this local
    // offset compensates during a left-handle drag so the leading edge tracks the finger while the
    // trailing edge stays visually fixed, matching every trim-handle UX convention. Zero during a
    // right-handle or body drag (effectiveStart stays at its committed value in both cases).
    private var trimHandleOffsetX: CGFloat { CGFloat(effectiveStart - overlay.startSeconds) * pxPerSecond }
    // 13-22 i14: while an edge auto-scroll loop is advancing state.currentTime mid-body-drag, the
    // row's contentOffset shifts underneath this pill every frame even though the finger itself
    // hasn't moved — without compensation the pill would appear to slide away from the finger
    // instead of staying under it. This term exactly cancels that shift: captured once at drag
    // start (dragStartContentOffset), it tracks (start − now) so the pill's TOTAL on-screen
    // position stays anchored to wherever the finger last actually was, regardless of how much
    // content has scrolled since. Zero when not dragging (dragStartContentOffset is nil).
    private var edgeScrollCompensationX: CGFloat {
        (dragStartContentOffset ?? contentOffset) - contentOffset
    }

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
        // 13-26 M3: strokeBorder — see AudioPillView's identical fix comment (a centered stroke
        // rendered 1pt past the pill frame on every side).
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .highPriorityGesture(bodyDragGesture)
        .overlay(alignment: .leading) {
            if isSelected { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected { handle.highPriorityGesture(rightHandleGesture) }
        }
        // F2: offset LAST — see ClipPillView's identical fix for the full explanation.
        .offset(x: dragTranslation + trimHandleOffsetX + edgeScrollCompensationX)
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

    // MARK: - Body drag (move — retimes the whole [start, end] window together)

    private var bodyDragGesture: some Gesture {
        // 13-22 i14: named coordinate space so `value.location` (fed to onBodyDragLocationChanged)
        // is screen-fixed relative to the whole timeline block, independent of contentOffset.
        DragGesture(minimumDistance: 3, coordinateSpace: .named("timeline"))
            .onChanged { value in
                onSelect()
                if dragStartContentOffset == nil { dragStartContentOffset = contentOffset }
                dragTranslation = value.translation.width
                onBodyDragLocationChanged(value.location.x)
            }
            .onEnded { value in
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                dragTranslation = 0
                dragStartContentOffset = nil
                onBodyDragEnded()
                let duration = overlay.endSeconds - overlay.startSeconds
                let newStart = max(0, overlay.startSeconds + deltaSeconds)
                onRetime(newStart, newStart + duration)
            }
    }

    // MARK: - Edge-handle retime (start/end independently)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if leftDragStartTime == nil { leftDragStartTime = overlay.startSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                var newStart = (leftDragStartTime ?? overlay.startSeconds) + deltaSeconds
                let endBound = previewEnd ?? overlay.endSeconds
                newStart = max(0, min(newStart, endBound - 0.3))
                previewStart = newStart
            }
            .onEnded { _ in
                let finalStart = previewStart ?? overlay.startSeconds
                let finalEnd = previewEnd ?? overlay.endSeconds
                leftDragStartTime = nil
                onRetime(finalStart, finalEnd)
                previewStart = nil
                previewEnd = nil
            }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if rightDragStartTime == nil { rightDragStartTime = overlay.endSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                let startBound = previewStart ?? overlay.startSeconds
                let newEnd = max(startBound + 0.3, (rightDragStartTime ?? overlay.endSeconds) + deltaSeconds)
                previewEnd = newEnd
            }
            .onEnded { _ in
                let finalStart = previewStart ?? overlay.startSeconds
                let finalEnd = previewEnd ?? overlay.endSeconds
                rightDragStartTime = nil
                onRetime(finalStart, finalEnd)
                previewStart = nil
                previewEnd = nil
            }
    }
}
