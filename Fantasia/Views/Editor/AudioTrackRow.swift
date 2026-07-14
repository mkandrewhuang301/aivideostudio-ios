// AudioTrackRow.swift
// Fantasia
// Phase 13, Plan 12: STABLE stub mount point on TimelineTrackView's track stack (middle rail,
// green #2F9E6B per 13-UI-SPEC.md). A later plan rewrites this in place with the real Audio pill
// rail (multi-clip, per RESEARCH's resolved Open Question 1) — TimelineTrackView.swift and
// EditorView.swift never need to change again once that happens; this plan's job is only to make
// TimelineTrackView compile standalone.

import SwiftUI

struct AudioTrackRow: View {
    let state: EditorState
    let pxPerSecond: Double

    var body: some View {
        EmptyView()
    }
}
