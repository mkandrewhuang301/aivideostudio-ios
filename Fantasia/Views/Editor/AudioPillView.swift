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
    let onSelect: () -> Void
    /// Fires once, on drag release (body move OR either edge-handle retrim), with the final
    /// (startOffsetSeconds, trimStartSeconds, trimEndSeconds) — the CALLER (AudioTrackRow) PATCHes
    /// via `ProjectManager.updateAudioClip`.
    let onRetime: (Double, Double, Double) -> Void
    /// Instant delete (no confirmation, per 13-UI-SPEC's Copywriting Contract) — the caller
    /// performs the mutation + toast.
    let onDelete: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStart: (offset: Double, trimStart: Double)? = nil
    @State private var rightDragStartTrimEnd: Double? = nil

    private let green = Color(red: 0.184, green: 0.620, blue: 0.420)          // #2F9E6B
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)      // #FF5470
    private let pillHeight: CGFloat = 28

    private var trimStart: Double { clip.trimStartSeconds }
    private var trimEnd: Double { clip.trimEndSeconds ?? clip.trimStartSeconds }
    private var duration: Double { max(0, trimEnd - trimStart) }
    private var width: Double { max(duration * pxPerSecond, 30) }

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
        .accessibilityLabel("Delete audio clip")
    }

    // MARK: - Body drag (move — shifts start_offset_seconds only, trim window unchanged)

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                dragTranslation = 0
                let newOffset = max(0, clip.startOffsetSeconds + deltaSeconds)
                onRetime(newOffset, trimStart, trimEnd)
            }
    }

    // MARK: - Edge-handle retrim

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStart == nil {
                    leftDragStart = (clip.startOffsetSeconds, trimStart)
                }
                guard let start = leftDragStart else { return }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                var newTrimStart = start.trimStart + deltaSeconds
                newTrimStart = max(0, min(newTrimStart, trimEnd - 0.3))
                let appliedDelta = newTrimStart - start.trimStart
                let newOffset = max(0, start.offset + appliedDelta)
                onRetime(newOffset, newTrimStart, trimEnd)
            }
            .onEnded { _ in leftDragStart = nil }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if rightDragStartTrimEnd == nil { rightDragStartTrimEnd = trimEnd }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                // No client-known upper bound (T-13-34) — server validates against the real
                // source duration; only guard against inverting past trimStart here.
                let newEnd = max(trimStart + 0.3, (rightDragStartTrimEnd ?? trimEnd) + deltaSeconds)
                onRetime(clip.startOffsetSeconds, trimStart, newEnd)
            }
            .onEnded { _ in rightDragStartTrimEnd = nil }
    }
}
