// TextOverlayPillView.swift
// Fantasia
// Phase 13, Plan 13: one Text overlay's amber timeline pill (SC3) — tap to select, edge-handle
// drag to trim the play window, mirroring ClipPillView's gesture layering exactly
// (`.contentShape(Rectangle()).onTapGesture{onSelect()}` + `.highPriorityGesture` on 12pt-wide
// invisible edge-handle overlays). Selecting a pill sets `state.selection = .text(id)`, which
// also selects the same overlay on-canvas (TextOverlayCanvasView, Task 1).
//
// Plan 13-26 M8: the immediate body-move DragGesture is GONE — a plain (un-held) drag on a text
// pill now falls through to the background timeline scrub, exactly like ClipPillView (CapCut
// behavior: dragging a pill scrubs). Moving a text pill requires a LONG-PRESS (0.4s) lift, then
// dragging moves it BOTH horizontally (retime) and vertically (across text rows) — the caller
// (TextOverlayTrackRow) owns all row math/commit; this view only reports lift/drag/end events and
// renders its own lifted treatment (scale/shadow + finger-following offset).
//
// 26-30pt pill height / 12pt edge handles are HIG-exempt continuous-drag hit targets per
// 13-UI-SPEC.md (same exemption ClipPillView's edge handles rely on) — do not enlarge to 44pt.

import SwiftUI
import UIKit

struct TextOverlayPillView: View {
    let overlay: TextOverlay
    let pxPerSecond: Double
    let isSelected: Bool
    let onSelect: () -> Void
    /// Fires once, on edge-handle drag release, with the final (startSeconds, endSeconds) — the
    /// CALLER (TextOverlayTrackRow) PATCHes via `ProjectManager.updateTextOverlay`.
    let onRetime: (Double, Double) -> Void
    /// 13-22 i14: the row's LIVE contentOffset (recomputed every render from state.currentTime) —
    /// needed to compensate this pill's own local offset while an edge-auto-scroll loop is
    /// advancing currentTime mid-drag (see `edgeScrollCompensationX`'s doc comment).
    let contentOffset: CGFloat
    /// 13-26 M8: fires once when the 0.4s long-press succeeds (lift). The caller gives the medium
    /// haptic, selects this pill, and enters its row-targeting mode.
    var onLift: () -> Void = {}
    /// 13-26 M8: fires on every lifted-drag change with the drag's (translation, location,
    /// startLocation) in the "textSection" named coordinate space (the text section's own content
    /// coordinates — location minus startLocation therefore captures BOTH finger movement and any
    /// content scrolled underneath by an edge auto-scroll loop).
    var onLiftDragChanged: (CGSize, CGPoint, CGPoint) -> Void = { _, _, _ in }
    /// Parent-computed row-band offset. It changes only when the finger crosses a row boundary,
    /// so the lifted pill snaps between rows instead of drifting continuously between them.
    var liftedRowOffsetY: CGFloat = 0
    /// 13-26 M8: fires exactly once per lift on ANY termination path (release, cancel,
    /// interruption) — GestureState-backed, so the lift can never stick.
    var onLiftEnded: () -> Void = {}

    @State private var leftDragStartTime: Double? = nil
    @State private var rightDragStartTime: Double? = nil
    // 13-26 M8: captured at lift, cleared on lift end.
    @State private var dragStartContentOffset: CGFloat? = nil
    // 13-22 i4: commit-on-release — onChanged only updates these LOCAL preview values (pill
    // width/offset render from them); onRetime fires ONCE in .onEnded with the final values.
    // nil = idle, render from `overlay`'s committed values.
    @State private var previewStart: Double? = nil
    @State private var previewEnd: Double? = nil

    // 13-26 M8: lift state — mirrors ClipPillView.reorderGesture's guaranteed-exit pattern:
    // `liftGestureActive` (GestureState) resets on EVERY termination path; the onChange below
    // tears the lift down when it does, so a missed .onEnded can never leave the pill floating.
    @GestureState private var liftGestureActive = false
    @State private var isLifted = false
    @State private var liftTranslation: CGSize = .zero

    private let amber = Color(red: 0.851, green: 0.478, blue: 0.169)      // #D97A2B
    private let pillHeight: CGFloat = 28

    private var effectiveStart: Double { previewStart ?? overlay.startSeconds }
    private var effectiveEnd: Double { previewEnd ?? overlay.endSeconds }
    private var width: Double { max((effectiveEnd - effectiveStart) * pxPerSecond, 30) }
    // The parent row positions this pill via `.offset(x: overlay.startSeconds * pxPerSecond)`
    // using the COMMITTED startSeconds (unchanged until onRetime fires at release) — this local
    // offset compensates during a left-handle drag so the leading edge tracks the finger while the
    // trailing edge stays visually fixed, matching every trim-handle UX convention. Zero during a
    // right-handle drag or lift (effectiveStart stays at its committed value in both cases).
    private var trimHandleOffsetX: CGFloat { CGFloat(effectiveStart - overlay.startSeconds) * pxPerSecond }
    // 13-22 i14: while an edge auto-scroll loop is advancing state.currentTime mid-lift, the
    // row's contentOffset shifts underneath this pill every frame even though the finger itself
    // hasn't moved — without compensation the pill would appear to slide away from the finger.
    // This term exactly cancels that shift. Zero when not lifted (dragStartContentOffset is nil).
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
        // 13-26 M8: lifted treatment — floats above siblings while the finger holds it.
        .scaleEffect(isLifted ? 1.05 : 1.0)
        .shadow(color: .black.opacity(isLifted ? 0.4 : 0), radius: isLifted ? 8 : 0, y: isLifted ? 3 : 0)
        .zIndex(isLifted ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .highPriorityGesture(liftGesture)
        .overlay(alignment: .leading) {
            if isSelected && !isLifted { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected && !isLifted { handle.highPriorityGesture(rightHandleGesture) }
        }
        // F2: offset LAST — see ClipPillView's identical fix for the full explanation.
        .offset(
            x: liftTranslation.width + trimHandleOffsetX + edgeScrollCompensationX,
            y: isLifted ? liftedRowOffsetY : 0
        )
        // 13-26 M8: when GestureState resets (any exit path), always tear the lift down.
        .onChange(of: liftGestureActive) { _, active in
            if !active { finishLift() }
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

    // MARK: - 13-26 M8: long-press lift & move. Hold threshold 0.4s so a tap never lifts; a plain
    // (non-held) drag FAILS the long-press and falls through to the background scrub — mirrors
    // ClipPillView.reorderGesture exactly, including the GestureState guaranteed-exit.

    private var liftGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("textSection")))
            .updating($liftGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                switch value {
                case .first(true):
                    guard !isLifted else { break }
                    isLifted = true
                    if dragStartContentOffset == nil { dragStartContentOffset = contentOffset }
                    onLift()
                case .second(true, let drag):
                    if let drag {
                        liftTranslation = drag.translation
                        onLiftDragChanged(drag.translation, drag.location, drag.startLocation)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                finishLift() // idempotent duplicate of the GestureState exit
            }
    }

    private func finishLift() {
        guard isLifted else { return }
        isLifted = false
        liftTranslation = .zero
        dragStartContentOffset = nil
        onLiftEnded()
    }

    // MARK: - Edge-handle retime (start/end independently) — unchanged by M8.

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
