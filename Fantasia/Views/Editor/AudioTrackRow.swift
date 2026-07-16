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
    /// 13-22 i14: the timeline's own viewport width + LIVE contentOffset (recomputed every render
    /// from state.currentTime) — needed to detect a pill body-drag's finger nearing either edge
    /// and to feed each pill a live compensation value while an auto-scroll loop runs. See
    /// EdgeAutoScroll.swift.
    let viewportWidth: CGFloat
    let contentOffset: CGFloat
    /// 13-23 J1: surfaces "Couldn't save change" when an optimistic retime's PATCH fails and the
    /// local value has been reverted — see TimelineTrackView's identical param doc comment.
    var onError: (String) -> Void = { _ in }
    /// 13-26 M7: opens the SAME AddAudioSheet EditorBottomBar's Audio action owns — threaded
    /// EditorView → TimelineTrackView → here. The empty-state placeholder now renders INSIDE this
    /// row (single source of geometry: the row that owns the action draws its own tap target),
    /// structurally killing the "tapping the empty TEXT row opened the ADD-AUDIO sheet" bug — a
    /// parallel overlay layer can no longer drift out of sync with the real rows' y-bands.
    var onAddAudio: () -> Void = {}

    @State private var edgeScrollTask: Task<Void, Never>?
    @State private var edgeScrollRate: Double?

    var body: some View {
        // Pure pill rail (13-19 Task E) — adds also come from EditorBottomBar's Audio action
        // (owns AddAudioSheet); no per-row "+" tile lives here.
        // 13-26 M7: the empty-state "＋ Add audio" placeholder is rendered by THIS row again (was
        // TimelineTrackView.railOverlay's parallel content-coordinate layer) — drawn bounds, hit
        // bounds, and the action now all live in the one row that owns them.
        VStack(alignment: .leading, spacing: 0) {
            if state.project.audioClips.isEmpty {
                audioPlaceholderPill
                    .frame(height: rowHeight, alignment: .leading)
            } else {
                ForEach(state.project.audioClips) { clip in
                    ZStack(alignment: .topLeading) {
                        AudioPillView(
                            clip: clip,
                            pxPerSecond: pxPerSecond,
                            isSelected: state.selection == .audio(clip.id),
                            isZooming: state.isZooming,
                            totalDuration: state.visualStripEndSeconds(pxPerSecond: pxPerSecond),
                            onSelect: {
                                // F10 (Plan 13-21): animated snap to this pill's own window BEFORE
                                // selecting, mirroring TimelineTrackView.selectClip's snap.
                                let start = clip.startOffsetSeconds
                                let end = start + max(0, (clip.trimEndSeconds ?? clip.trimStartSeconds) - clip.trimStartSeconds)
                                state.snapPlayhead(toWindow: start, end)
                                state.select(.audio(clip.id))
                            },
                            onRetime: { offset, trimStart, trimEnd in
                                retime(id: clip.id, offset: offset, trimStart: trimStart, trimEnd: trimEnd)
                            },
                            contentOffset: contentOffset,
                            onBodyDragLocationChanged: { fingerX in
                                updateEdgeScroll(fingerX: fingerX)
                            },
                            onBodyDragEnded: {
                                stopEdgeScroll()
                            }
                        )
                        .offset(x: clip.startOffsetSeconds * pxPerSecond)
                    }
                    .frame(height: rowHeight, alignment: .leading)
                }
            }
        }
    }

    // MARK: - 13-26 M7: empty-state placeholder (moved back in from TimelineTrackView.railOverlay)

    // Deliberately NO Button wrapper (a Button carries its own hit-region semantics that fought
    // the drawn shape in past regressions — 13-22 i11.3): the drawn shape + an explicit
    // .contentShape define the ONE tappable region, then .onTapGesture invokes the action.
    private var audioPlaceholderPill: some View {
        Text("＋ Add audio")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: max(state.visualStripEndPx(pxPerSecond: pxPerSecond), 60), height: rowHeight, alignment: .leading)
            .padding(.leading, 10)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture {
                #if DEBUG
                print("[hit] add-audio placeholder tapped")
                #endif
                onAddAudio()
            }
            .accessibilityLabel("Add audio")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Mutations

    // F8 (Plan 13-21): `onRetime` fires ONCE at release for a body-move, but CONTINUOUSLY
    // (every `.onChanged`) for an edge-handle trim drag — same debounce treatment as
    // TimelineTrackView.updateClipTrim so a handle drag doesn't flood the history with dozens of
    // near-duplicate entries (a single-shot body-move just resolves its debounce ~500ms later,
    // harmless).
    @State private var retimeBeforeByClip: [String: (offset: Double, trimStart: Double, trimEnd: Double)] = [:]
    @State private var retimeDebounceTasks: [String: Task<Void, Never>] = [:]

    // 13-23 J1: optimistic commit — see TimelineTrackView.updateClipTrim's identical doc comment.
    // Synchronous entry point invoked directly from AudioPillView.onRetime's `.onEnded`, in the
    // SAME call frame that resets `dragTranslation`/preview vars.
    private func retime(id: String, offset: Double, trimStart: Double, trimEnd: Double) {
        guard let idx = state.project.audioClips.firstIndex(where: { $0.id == id }) else { return }
        let committedOffset = state.project.audioClips[idx].startOffsetSeconds
        let committedTrimStart = state.project.audioClips[idx].trimStartSeconds
        let committedTrimEnd = state.project.audioClips[idx].trimEndSeconds ?? committedTrimStart
        if retimeBeforeByClip[id] == nil {
            retimeBeforeByClip[id] = (committedOffset, committedTrimStart, committedTrimEnd)
        }
        state.project.audioClips[idx].startOffsetSeconds = offset
        state.project.audioClips[idx].trimStartSeconds = trimStart
        state.project.audioClips[idx].trimEndSeconds = trimEnd

        Task {
            do {
                try await projectManager.updateAudioClip(
                    audioId: id, startOffsetSeconds: offset, trimStartSeconds: trimStart, trimEndSeconds: trimEnd
                )
                syncProjectFromManager()
            } catch {
                print("[AudioTrackRow] retime error: \(error)")
                if let revertIdx = state.project.audioClips.firstIndex(where: { $0.id == id }) {
                    state.project.audioClips[revertIdx].startOffsetSeconds = committedOffset
                    state.project.audioClips[revertIdx].trimStartSeconds = committedTrimStart
                    state.project.audioClips[revertIdx].trimEndSeconds = committedTrimEnd
                }
                onError("Couldn't save change")
            }
            scheduleRetimeUndoCommit(id: id, after: (offset, trimStart, trimEnd))
        }
    }

    private func scheduleRetimeUndoCommit(id: String, after: (offset: Double, trimStart: Double, trimEnd: Double)) {
        retimeDebounceTasks[id]?.cancel()
        retimeDebounceTasks[id] = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let before = retimeBeforeByClip[id] else { return }
            retimeBeforeByClip[id] = nil
            retimeDebounceTasks[id] = nil
            state.history.record(UndoableAction(
                label: "Retime audio",
                undo: {
                    try await projectManager.updateAudioClip(
                        audioId: id, startOffsetSeconds: before.offset, trimStartSeconds: before.trimStart, trimEndSeconds: before.trimEnd
                    )
                },
                redo: {
                    try await projectManager.updateAudioClip(
                        audioId: id, startOffsetSeconds: after.offset, trimStartSeconds: after.trimStart, trimEndSeconds: after.trimEnd
                    )
                }
            ))
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

    // MARK: - 13-22 i14: edge auto-scroll while dragging a pill's body — see
    // TextOverlayTrackRow's identical implementation for the full doc comment.

    private func updateEdgeScroll(fingerX: CGFloat) {
        let newRate = EdgeAutoScroll.rate(fingerX: fingerX, viewportWidth: viewportWidth, pxPerSecond: pxPerSecond)
        guard newRate != edgeScrollRate else { return }
        edgeScrollRate = newRate
        edgeScrollTask?.cancel()
        guard let rate = newRate else {
            edgeScrollTask = nil
            state.isScrubbing = false
            return
        }
        state.isScrubbing = true
        edgeScrollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16)) // ~60Hz
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    state.currentTime = state.clampTime(state.currentTime + rate / 60.0)
                }
            }
        }
    }

    private func stopEdgeScroll() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        edgeScrollRate = nil
        state.isScrubbing = false
    }
}
