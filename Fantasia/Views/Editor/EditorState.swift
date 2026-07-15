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
        currentTime = min(max(time, 0), totalDuration)
    }

    func select(_ selection: EditorSelection) {
        self.selection = selection
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
            currentTime = min(max(target, 0), totalDuration)
        }
    }
}
