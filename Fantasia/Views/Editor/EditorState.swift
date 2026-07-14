// EditorState.swift
// Fantasia
// Phase 13, Plan 11: the ONE shared playback/selection clock for the Editor. `EditorView` builds
// exactly one of these per editor session; the timeline (plan 12), the Captions overlay
// (plan 13), and the player (plan 14) all read/write the SAME instance via `currentTime` — no
// separate clocks anywhere in the editor.
//
// Pattern: @Observable @MainActor final class (CLAUDE.md — all new iOS managers use this).

import Foundation

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
}
