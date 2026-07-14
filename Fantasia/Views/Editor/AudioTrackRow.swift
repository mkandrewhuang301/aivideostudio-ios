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
// The "+" tile is pinned at local x = `state.currentTime * pxPerSecond`, exactly like
// TextOverlayTrackRow's add-tile: because this row lives inside TimelineTrackView's content stack
// (translated by `viewportWidth/2 - currentTime*pxPerSecond`), a tile at that local x always
// resolves to `viewportWidth/2` on screen — i.e. it rides along at the fixed-center playhead
// position without this plan needing to touch TimelineTrackView.swift.

import SwiftUI

struct AudioTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double

    private let rowHeight: CGFloat = 30
    private let green = Color(red: 0.184, green: 0.620, blue: 0.420) // #2F9E6B

    @State private var showAddAudioSheet = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.project.audioClips) { clip in
                AudioPillView(
                    clip: clip,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .audio(clip.id),
                    onSelect: { state.select(.audio(clip.id)) },
                    onRetime: { offset, trimStart, trimEnd in
                        Task { await retime(id: clip.id, offset: offset, trimStart: trimStart, trimEnd: trimEnd) }
                    },
                    onDelete: {
                        Task { await delete(id: clip.id) }
                    }
                )
                .offset(x: clip.startOffsetSeconds * pxPerSecond)
            }

            addAudioTile
                .offset(x: state.currentTime * pxPerSecond - 11)
        }
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showAddAudioSheet) {
            AddAudioSheet(currentTime: state.currentTime, onAdded: { syncProjectFromManager() })
        }
    }

    // MARK: - Row-level "+" — opens AddAudioSheet (upload or preset music)

    private var addAudioTile: some View {
        Button {
            showAddAudioSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(green)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(green.opacity(0.7), lineWidth: 1)
                )
        }
        .accessibilityLabel("Add audio")
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

    private func delete(id: String) async {
        do {
            try await projectManager.deleteAudioClip(audioId: id)
            if state.selection == .audio(id) { state.select(.none) }
            syncProjectFromManager()
            showToast("Audio removed")
        } catch {
            print("[AudioTrackRow] delete error: \(error)")
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

    private func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toastMessage = nil
        }
    }
}
