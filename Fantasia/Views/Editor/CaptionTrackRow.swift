// CaptionTrackRow.swift
// Fantasia
// Phase 13, Plan 12: STABLE stub mount point on TimelineTrackView's track stack (bottom rail, blue
// #2B8FD9 per 13-UI-SPEC.md Delta 3). A later plan rewrites this in place with the real Captions
// cue-pill rail (word-level tap-to-edit, "Delete All Captions" per D-13) — TimelineTrackView.swift
// and EditorView.swift never need to change again once that happens; this plan's job is only to
// make TimelineTrackView compile standalone.

import SwiftUI

struct CaptionTrackRow: View {
    let state: EditorState
    let pxPerSecond: Double

    var body: some View {
        EmptyView()
    }
}
