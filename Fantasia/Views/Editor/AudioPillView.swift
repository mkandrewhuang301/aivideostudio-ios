// AudioPillView.swift
// Fantasia
// Phase 13, Plan 14: one Audio clip's green timeline pill (SC4) — body-drag to reposition on the
// timeline (`start_offset_seconds`), edge-handle drag to retrim the underlying source's played
// window (`trim_start_seconds`/`trim_end_seconds`), mirroring ClipPillView/TextOverlayPillView's
// gesture layering exactly (`.contentShape(Rectangle()).onTapGesture{onSelect()}
// .highPriorityGesture(bodyDragGesture)` + `.highPriorityGesture` on invisible edge-handle
// overlays). Selecting a pill sets `state.selection = .audio(clip.id)` (caller's job, via onSelect).
//
// Timeline math (distinct from ClipPillView's simpler single-offset model): an audio clip's
// visible LEFT edge is `start_offset_seconds` (position on the shared project timeline); its
// visible RIGHT edge is `start_offset_seconds + (trim_end_seconds - trim_start_seconds)` (i.e. how
// long the trimmed portion of the source file plays for once it starts). That means:
//   - Body drag (move): shifts `start_offset_seconds` only — trim window stays the same, the same
//     slice of the source audio just starts playing at a different point on the timeline.
//   - Left edge-handle: shifts `trim_start_seconds` AND `start_offset_seconds` by the SAME delta,
//     which keeps the pill's right edge fixed on the timeline while eating into (or extending)
//     the source's start point — the standard "trim from the left" behavior.
//   - Right edge-handle: shifts `trim_end_seconds` only — extends/shrinks how much of the source
//     plays, keeping the timeline start position fixed.
//
// 26-30pt pill height / 12pt edge handles are HIG-exempt continuous-drag hit targets per
// 13-UI-SPEC.md (same exemption ClipPillView/TextOverlayPillView's edge handles rely on) — do not
// enlarge to 44pt.
//
// T-13-34 (threat model): `AudioClip` has no client-visible "source file duration" field (unlike
// `ProjectClip.originalDurationSeconds`) — POST/PATCH /api/projects/:id/audio never return one
// (see EditProject.swift's doc comment on AudioClip). The right-handle drag below therefore has
// no client-side upper bound beyond "don't invert past trimStart" — server-side validation
// (plan 04) is the authoritative backstop for out-of-bounds trim values, exactly as the threat
// register specifies.

import SwiftUI

struct AudioPillView: View {
    let clip: AudioClip
    let pxPerSecond: Double
    let isSelected: Bool
    /// 13-23 J5 / 13-24 K3: visual strip end in seconds (accounts for clip 30pt min-width floors).
    /// An audio clip can never render or drag past this bound.
    let totalDuration: Double
    let onSelect: () -> Void
    /// Fires once, on drag release (body move OR either edge-handle retrim), with the final
    /// (startOffsetSeconds, trimStartSeconds, trimEndSeconds) — the CALLER (AudioTrackRow) PATCHes
    /// via `ProjectManager.updateAudioClip`.
    let onRetime: (Double, Double, Double) -> Void
    /// 13-22 i14: the row's LIVE contentOffset — see TextOverlayPillView's identical param doc
    /// comment.
    let contentOffset: CGFloat
    /// Fires the finger's x (in the "timeline" named coordinate space) on every BODY-drag
    /// onChanged — never during a handle drag.
    var onBodyDragLocationChanged: (CGFloat) -> Void = { _ in }
    /// Fires once on body-drag release.
    var onBodyDragEnded: () -> Void = {}

    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStart: (offset: Double, trimStart: Double)? = nil
    @State private var rightDragStartTrimEnd: Double? = nil
    @State private var dragStartContentOffset: CGFloat? = nil
    // 13-22 i4: commit-on-release — onChanged only updates these LOCAL preview values (pill
    // width/offset render from them); onRetime fires ONCE in .onEnded with the final values.
    // Previously onRetime fired on every onChanged (a network PATCH + full re-sync per finger
    // movement). nil = idle, render from `clip`'s committed values.
    @State private var previewOffset: Double? = nil
    @State private var previewTrimStart: Double? = nil
    @State private var previewTrimEnd: Double? = nil

    private let green = Color(red: 0.184, green: 0.620, blue: 0.420)          // #2F9E6B
    private let pillHeight: CGFloat = 28

    private var trimStart: Double { previewTrimStart ?? clip.trimStartSeconds }
    private var trimEnd: Double { previewTrimEnd ?? (clip.trimEndSeconds ?? clip.trimStartSeconds) }
    private var duration: Double { max(0, trimEnd - trimStart) }
    private var offsetSeconds: Double { previewOffset ?? clip.startOffsetSeconds }
    // 13-23 J5 / 13-24 K3: clamp rendered duration to remaining visual-strip room; width never
    // exceeds the strip end (the 30pt floor yields when remaining room is smaller).
    private var clampedDuration: Double { max(0, min(duration, totalDuration - offsetSeconds)) }
    private var width: Double {
        let maxPx = max(0, (totalDuration - offsetSeconds) * pxPerSecond)
        let natural = clampedDuration * pxPerSecond
        return min(max(natural, min(EditorState.clipPillMinWidthPt, maxPx)), maxPx)
    }
    // The parent row positions this pill via `.offset(x: clip.startOffsetSeconds * pxPerSecond)`
    // using the COMMITTED offset (unchanged until onRetime fires at release) — this local offset
    // compensates during a left-handle drag (which shifts BOTH startOffsetSeconds and trimStart by
    // the same delta) so the leading edge tracks the finger while the trailing edge stays visually
    // fixed. Zero during a right-handle or body drag.
    private var trimHandleOffsetX: CGFloat { CGFloat(offsetSeconds - clip.startOffsetSeconds) * pxPerSecond }
    // 13-22 i14: cancels the row's contentOffset shift during an edge-auto-scroll-driven body
    // drag — see TextOverlayPillView.edgeScrollCompensationX's doc comment for the full
    // derivation. Zero when not dragging.
    private var edgeScrollCompensationX: CGFloat {
        (dragStartContentOffset ?? contentOffset) - contentOffset
    }

    private var icon: String {
        switch clip.sourceType {
        case "preset": return "music.note"
        case "narration": return "waveform"
        default: return "doc.fill" // "upload"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(green)
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: width, height: pillHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white : .clear, lineWidth: 2)
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

    // MARK: - Body drag (move — shifts start_offset_seconds only, trim window unchanged)

    private var bodyDragGesture: some Gesture {
        // 13-22 i14: named coordinate space — see TextOverlayPillView's identical gesture doc.
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
                var newOffset = max(0, clip.startOffsetSeconds + deltaSeconds)
                // 13-23 J5: can't push the clip's start past the video's own end.
                newOffset = min(newOffset, max(0, totalDuration - 0.3))
                onRetime(newOffset, trimStart, trimEnd)
            }
    }

    // MARK: - Edge-handle retrim

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStart == nil {
                    leftDragStart = (clip.startOffsetSeconds, clip.trimStartSeconds)
                }
                guard let start = leftDragStart else { return }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                var newTrimStart = start.trimStart + deltaSeconds
                let endBound = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.trimStartSeconds)
                newTrimStart = max(0, min(newTrimStart, endBound - 0.3))
                let appliedDelta = newTrimStart - start.trimStart
                let newOffset = max(0, start.offset + appliedDelta)
                previewOffset = newOffset
                previewTrimStart = newTrimStart
            }
            .onEnded { _ in
                let finalOffset = previewOffset ?? clip.startOffsetSeconds
                let finalTrimStart = previewTrimStart ?? clip.trimStartSeconds
                let finalTrimEnd = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.trimStartSeconds)
                leftDragStart = nil
                onRetime(finalOffset, finalTrimStart, finalTrimEnd)
                previewOffset = nil
                previewTrimStart = nil
                previewTrimEnd = nil
            }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if rightDragStartTrimEnd == nil {
                    rightDragStartTrimEnd = clip.trimEndSeconds ?? clip.trimStartSeconds
                }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                // No client-known upper bound on the SOURCE file's own duration (T-13-34) — server
                // validates against that; only guard against inverting past trimStart here.
                let startBound = previewTrimStart ?? clip.trimStartSeconds
                var newEnd = max(startBound + 0.3, (rightDragStartTrimEnd ?? (clip.trimEndSeconds ?? clip.trimStartSeconds)) + deltaSeconds)
                // 13-23 J5: independent client-known bound — the clip can never extend past the
                // VIDEO's own end regardless of how much of the source file is left.
                let maxEnd = startBound + max(0.3, totalDuration - offsetSeconds)
                newEnd = min(newEnd, maxEnd)
                previewTrimEnd = newEnd
            }
            .onEnded { _ in
                let finalOffset = previewOffset ?? clip.startOffsetSeconds
                let finalTrimStart = previewTrimStart ?? clip.trimStartSeconds
                let finalTrimEnd = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.trimStartSeconds)
                rightDragStartTrimEnd = nil
                onRetime(finalOffset, finalTrimStart, finalTrimEnd)
                previewOffset = nil
                previewTrimStart = nil
                previewTrimEnd = nil
            }
    }
}
