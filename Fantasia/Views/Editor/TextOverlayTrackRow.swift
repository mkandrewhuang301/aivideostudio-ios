// TextOverlayTrackRow.swift
// Fantasia
// Phase 13, Plan 12: STABLE stub mount point on TimelineTrackView's track stack (top rail, amber
// #D97A2B per 13-UI-SPEC.md). A later plan rewrites this in place with the real Text-overlay pill
// rail — TimelineTrackView.swift and EditorView.swift never need to change again once that
// happens; this plan's job is only to make TimelineTrackView compile standalone.

import SwiftUI

struct TextOverlayTrackRow: View {
    let state: EditorState
    let pxPerSecond: Double

    var body: some View {
        EmptyView()
    }
}
