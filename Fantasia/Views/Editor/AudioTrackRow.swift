// AudioTrackRow.swift
// Fantasia
// Phase 13, Plan 14: the real Audio track rail (SC4) — replaces plan 12's placeholder stub.
// Renders one AudioPillView per `state.project.audioClips`, freeform-positioned at
// `xOffset = startOffsetSeconds * pxPerSecond` within the row (same content-scrolls-under-fixed-
// playhead model as TimelineTrackView's ruler/clip row and TextOverlayTrackRow), plus a row-level
// "+" affordance that opens AddAudioSheet (upload file or pick preset music).
//
// SAME struct name/signature as plan 12's stub (`AudioTrackRow(state:, pxPerSecond:)`) —
// TimelineTrackView.swift (already compiled/wired) needs no changes.
//
// MULTI-CLIP (UI-SPEC Resolved Q1, LOCKED): the Audio track supports multiple independent, freely
// overlapping audio clips — unlike the sequential, non-overlapping clip row, clips here are NOT
// forced into non-overlapping positions. If two clips' time ranges collide they simply render on
// top of each other in z-order; this is an accepted v1 tradeoff (matches the locked sketch's
// "multiple addAudio() calls produce multiple stacked green rows" note), not a blocker.
//
// 13-20 i2: each audio clip now gets its OWN row (a `VStack` of one-row-per-item), matching the
// locked sketch's per-item stacking (index.html:402 — audio pills stack below the text rows, each
// on its own row) instead of a single shared ZStack rail where overlapping clips would visually
// collide. TimelineTrackView hosts this inside its vertically-scrollable tracks viewport and gives
// the WHOLE stack (TextOverlayTrackRow + this row + CaptionTrackRow) its shared
// `contentWidth`/`contentOffset` — this view only needs to lay out one `pxPerSecond`-scaled pill
// per row.

import SwiftUI

struct AudioTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double
    var rowHeight: CGFloat = 28

    var body: some View {
        // Pure pill rail (13-19 Task E) — adds now come exclusively from EditorBottomBar's
        // Audio action (owns AddAudioSheet); no per-row "+" tile lives here anymore.
        // F12 (Plan 13-21): the empty-state "+ Add audio" placeholder + ♪ rail tile are rendered
        // by TimelineTrackView itself, in its viewport-pinned overlay layer (they must NOT scrub
        // horizontally with contentOffset the way real pills do) — this view only reserves the
        // matching `rowHeight` of vertical space so TextOverlayTrackRow below it still starts at
        // the right y, keeping this a pure (horizontally-scrolling) pill rail either way.
        VStack(alignment: .leading, spacing: 0) {
            if state.project.audioClips.isEmpty {
                Color.clear.frame(height: rowHeight)
            } else {
                ForEach(state.project.audioClips) { clip in
                    ZStack(alignment: .topLeading) {
                        AudioPillView(
                            clip: clip,
                            pxPerSecond: pxPerSecond,
                            isSelected: state.selection == .audio(clip.id),
                            onSelect: {
                                // F10 (Plan 13-21): animated snap to this pill's own window BEFORE
                                // selecting, mirroring TimelineTrackView.selectClip's snap.
                                let start = clip.startOffsetSeconds
                                let end = start + max(0, (clip.trimEndSeconds ?? clip.trimStartSeconds) - clip.trimStartSeconds)
                                state.snapPlayhead(toWindow: start, end)
                                state.select(.audio(clip.id))
                            },
                            onRetime: { offset, trimStart, trimEnd in
                                Task { await retime(id: clip.id, offset: offset, trimStart: trimStart, trimEnd: trimEnd) }
                            }
                        )
                        .offset(x: clip.startOffsetSeconds * pxPerSecond)
                    }
                    .frame(height: rowHeight, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Mutations

    private func retime(id: String, offset: Double, trimStart: Double, trimEnd: Double) async {
        do {
            try await projectManager.updateAudioClip(
                audioId: id, startOffsetSeconds: offset, trimStartSeconds: trimStart, trimEndSeconds: trimEnd
            )
            syncProjectFromManager()
        } catch {
            print("[AudioTrackRow] retime error: \(error)")
        }
    }

    /// Reflects ProjectManager's persisted result back onto the shared EditorState clock — mirrors
    /// TimelineTrackView's `syncProjectFromManager()` (EditorState "owns playback/selection state,
    /// not persistence" per its own doc comment).
    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }
}
