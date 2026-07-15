// EditorState.swift
// Fantasia
// Phase 13, Plan 11: the ONE shared playback/selection clock for the Editor. `EditorView` builds
// exactly one of these per editor session; the timeline (plan 12), the Captions overlay
// (plan 13), and the player (plan 14) all read/write the SAME instance via `currentTime` — no
// separate clocks anywhere in the editor.
//
// Pattern: @Observable @MainActor final class (CLAUDE.md — all new iOS managers use this).

import SwiftUI

/// What's currently selected on the timeline. Drives the contextual bottom bar (UI-SPEC Editor
/// section) — `.none` shows the default Edit/Text/Audio/Captions bar, any other case swaps in
/// that element's Split/Edit/Delete/Done bar.
enum EditorSelection: Equatable {
    case none
    case clip(String)
    case text(String)
    case audio(String)
    case caption(String)
}

@Observable
@MainActor
final class EditorState {
    /// The full editable project (clips/text/audio/captions). Mutations flow through
    /// `ProjectManager` (the persistence layer) and get reflected back here by the caller —
    /// this class owns playback/selection state, not persistence.
    var project: EditProject

    /// Shared playback clock, in seconds from project start. The timeline's playhead, the
    /// Captions overlay's active-word highlight, and the preview/fullscreen player all read this
    /// single value.
    var currentTime: Double = 0
    var isPlaying = false

    /// Mirrors `project.aspectRatio` for immediate local preview feedback when the user cycles
    /// the 9:16/4:5/1:1/16:9 toggle, before the persisted PATCH round-trip resolves (or reverts
    /// this back on failure — see EditorView's aspect-toggle handler).
    var aspectRatio: String

    /// 13-22 i3: the ACTUAL AVComposition's real duration in seconds, set by EditorView right after
    /// building the player (`composition.duration.seconds`). `totalDuration` below is the
    /// project's LOGICAL duration (sum of trimmed clip durations) — the two can drift apart by a
    /// few fractional seconds' rounding, and clip-row `HStack` spacing/pixel math has its own
    /// approximation error. `clampTime(_:)` is the single source of truth every scrub/seek path
    /// uses so the playhead can never reach a time the composition has no frame for (the "black
    /// frame at the end" bug). Defaults to `.infinity` so clamping is a no-op (falls back to
    /// `totalDuration` alone) before the first composition ever finishes building.
    var playableDuration: Double = .infinity

    var selection: EditorSelection = .none

    /// Transient "please enter edit mode" signals from the contextual bottom bar's Edit action
    /// (13-19 Task A) — the owning pill view (TextOverlayItemView / CaptionTrackRow) observes its
    /// own id against this, flips its local editing @State, then clears the signal back to nil.
    /// Not part of persisted project state.
    var editRequestedTextId: String?
    var editRequestedCaptionId: String?

    /// Plan 13-21 F5: the timeline's shared px-per-second zoom level — moved here from
    /// TimelineTrackView's local constant so the pinch gesture (TimelineTrackView) and every pill/
    /// row/ruler consumer read the SAME live value. Clamped to [12, 120] by the pinch gesture
    /// itself; 44 (the original hard-coded constant) stays the default so nothing else changes at
    /// rest.
    var pxPerSecond: Double = 44

    /// Plan 13-21 F5: true for the duration of an active pinch gesture — ClipPillView uses this to
    /// avoid recomputing its filmstrip cell count (and re-triggering AVAssetImageGenerator loads)
    /// on every live magnification delta; existing frames just stretch until the pinch ends.
    var isZooming = false

    /// Plan 13-21 F8: the Editor's undo/redo engine. Held here (not threaded as a separate param)
    /// so every view that already receives `state: EditorState` gets it for free — mirrors
    /// pxPerSecond/isZooming above.
    let history = EditorHistory()

    init(project: EditProject) {
        self.project = project
        self.aspectRatio = project.aspectRatio
    }

    /// Sum of every clip's trimmed duration: `(trimEnd ?? originalDuration) - trimStart`. This is
    /// the project's total playable length — the timeline ruler, playhead clamp, and player all
    /// derive their bounds from this.
    var totalDuration: Double {
        project.clips.reduce(0.0) { partial, clip in
            let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
            return partial + max(0, end - clip.trimStartSeconds)
        }
    }

    func play() {
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func seek(to time: Double) {
        currentTime = clampTime(time)
    }

    /// 13-22 i3: shared clamp helper — EVERY scrub/seek/snap path in the Editor routes through
    /// this (scrubGesture, tracksGesture, snapPlayhead, the periodic playback observer, the
    /// fullscreen scrubber) instead of clamping against `totalDuration` alone. Playing/scrubbing to
    /// the end now settles at `playableDuration - 0.03` and HOLDS that last real frame, rather than
    /// seeking to/past the composition's exact end (which AVFoundation renders as a black frame).
    func clampTime(_ time: Double) -> Double {
        let upperBound = max(0, min(totalDuration, playableDuration - 0.03))
        return min(max(time, 0), upperBound)
    }

    // 13-22 i5: selection must NEVER animate — trim handles/stroke must appear INSTANTLY on the
    // selected pill. Every pill's onSelect path calls this in the SAME update as
    // `snapPlayhead(toWindow:_:)` (which DOES animate `currentTime`, gliding the timeline into
    // view) — without an explicit no-animation transaction here, SwiftUI was observed sweeping
    // this mutation into that ambient animated transaction too, so the newly-selected pill's
    // handles visibly slid in from the old selection's position instead of appearing immediately.
    // Wrapping in `disablesAnimations` makes selection instant regardless of what animated
    // transaction (if any) is active when a caller invokes this.
    func select(_ selection: EditorSelection) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            self.selection = selection
        }
    }

    /// Plan 13-21 F10: shared animated snap helper — if the playhead is currently OUTSIDE
    /// `[start, end)`, glides it to whichever boundary is nearer (before → `start`, at/after `end`
    /// → `end`); a no-op if it's already inside. Every selectable timeline item (clip/text/audio/
    /// caption) calls this with its own window right before selecting itself, so tapping ANY pill
    /// outside the current play position animates the timeline into view instead of jumping.
    /// `contentOffset` (TimelineTrackView) derives from `currentTime`, so wrapping the assignment
    /// in `withAnimation` is sufficient — the whole timeline glides, no separate animation plumbing
    /// needed in the timeline view itself.
    func snapPlayhead(toWindow start: Double, _ end: Double) {
        guard !(currentTime >= start && currentTime < end) else { return }
        let target = currentTime < start ? start : end
        withAnimation(.easeInOut(duration: 0.25)) {
            currentTime = clampTime(target)
        }
    }
}
