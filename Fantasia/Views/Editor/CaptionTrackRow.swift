// CaptionTrackRow.swift
// Fantasia
// Phase 13, Plan 15: the real Captions track rail (SC5) — replaces plan 12's `EmptyView` stub.
// Renders one CaptionPillView per `state.project.captionCues`, freeform-positioned at
// `xOffset = startSeconds * pxPerSecond` within the row (same content-scrolls-under-fixed-
// playhead model as TimelineTrackView's ruler/clip row and TextOverlayTrackRow/AudioTrackRow),
// plus the empty-state auto-generate prompt and the bulk "Delete All Captions" long-press action
// (D-13).
//
// SAME struct name/signature as plan 12's stub (`CaptionTrackRow(state:, pxPerSecond:)`) —
// TimelineTrackView.swift (already compiled/wired, stack order Text -> Audio -> Captions) needs no
// changes.
//
// The live karaoke rendering (fullscreen/preview player overlay) and the Caption Style sheet are
// deliberately deferred to Plan 16 (a distinct subsystem: preview/fullscreen rendering vs. this
// plan's timeline editing) — see 13-15-PLAN.md's objective.

import SwiftUI

struct CaptionTrackRow: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    let pxPerSecond: Double

    private let rowHeight: CGFloat = 30
    private let blue = Color(red: 0.169, green: 0.561, blue: 0.851) // #2B8FD9

    @State private var isTranscribing = false
    @State private var editingCueId: String?
    @State private var showDeleteAllConfirm = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Long-press ANYWHERE on the track row background (only meaningful once >=1 cue
            // exists) reveals the bulk "Delete All Captions" confirmation (D-13) — the one
            // Captions action that gets a confirmation dialog, unlike every per-cue mutation
            // below which is instant + toast.
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.5) {
                    guard !state.project.captionCues.isEmpty else { return }
                    showDeleteAllConfirm = true
                }

            if state.project.captionCues.isEmpty {
                emptyStateRow
            } else {
                ForEach(state.project.captionCues) { cue in
                    CaptionPillView(
                        cue: cue,
                        pxPerSecond: pxPerSecond,
                        isSelected: state.selection == .caption(cue.id),
                        isEditing: editingCueId == cue.id,
                        onSelect: { state.select(.caption(cue.id)) },
                        onRetime: { start, end in
                            Task { await retime(id: cue.id, start: start, end: end) }
                        },
                        onWordsCommit: { words in
                            Task { await commitWords(id: cue.id, words: words) }
                        },
                        onDelete: {
                            Task { await deleteCue(id: cue.id) }
                        },
                        onEditToggle: {
                            editingCueId = (editingCueId == cue.id) ? nil : cue.id
                        }
                    )
                    .offset(x: cue.startSeconds * pxPerSecond)
                }
            }
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
        .confirmationDialog(
            "Delete all captions?",
            isPresented: $showDeleteAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                Task { await deleteAllCaptions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every caption in this project. This cannot be undone.")
        }
    }

    // MARK: - Empty state (Copywriting Contract): "No captions yet" / "Auto-generate from this
    // clip's audio" primary inline button, INSIDE the track row (not a full empty-state block).

    private var emptyStateRow: some View {
        HStack(spacing: 8) {
            Text("No captions yet")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))

            if isTranscribing {
                HStack(spacing: 4) {
                    ProgressView()
                        .tint(blue)
                        .scaleEffect(0.6)
                    Text("Transcribing…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else {
                Button {
                    autoGenerate()
                } label: {
                    Text("Auto-generate from this clip's audio")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(blue)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Auto-generate (non-blocking — `isTranscribing` is local @State scoped to this row
    // only; nothing disables the rest of the editor, satisfying the Copywriting Contract's
    // "rest of the editor stays fully interactive" requirement without any extra plumbing).

    private func autoGenerate() {
        guard let clipId = clipIdUnderPlayhead() else { return }
        isTranscribing = true
        Task {
            do {
                try await projectManager.autoGenerateCaptions(clipId: clipId)
                syncProjectFromManager()
            } catch {
                print("[CaptionTrackRow] autoGenerateCaptions error: \(error)")
            }
            isTranscribing = false
        }
    }

    /// Resolves which clip is under the current playhead by walking `state.project.clips` in
    /// `sortOrder`, accumulating each clip's trimmed duration — same cumulative-offset math as
    /// `TimelineTrackView.handleReorder`'s `starts` array, kept local here since this is a
    /// read-only lookup (not a mutation) and doesn't warrant a new cross-file shared helper.
    private func clipIdUnderPlayhead() -> String? {
        let clips = state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
        var acc = 0.0
        for clip in clips {
            let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
            let dur = max(0, end - clip.trimStartSeconds)
            if state.currentTime < acc + dur { return clip.id }
            acc += dur
        }
        return clips.last?.id
    }

    // MARK: - Mutations

    private func retime(id: String, start: Double, end: Double) async {
        do {
            try await projectManager.updateCaptionCue(cueId: id, startSeconds: start, endSeconds: end)
            syncProjectFromManager()
        } catch {
            print("[CaptionTrackRow] retime error: \(error)")
        }
    }

    private func commitWords(id: String, words: [CaptionWord]) async {
        do {
            try await projectManager.updateCaptionCue(cueId: id, words: words)
            syncProjectFromManager()
        } catch {
            print("[CaptionTrackRow] words commit error: \(error)")
        }
    }

    private func deleteCue(id: String) async {
        do {
            try await projectManager.deleteCaptionCue(cueId: id)
            if state.selection == .caption(id) { state.select(.none) }
            if editingCueId == id { editingCueId = nil }
            syncProjectFromManager()
            showToast("Caption removed")
        } catch {
            print("[CaptionTrackRow] delete error: \(error)")
        }
    }

    /// Bulk "Delete All Captions" (D-13) — clears the entire track at once, distinct from the
    /// per-cue instant delete above.
    private func deleteAllCaptions() async {
        do {
            try await projectManager.deleteAllCaptions()
            if case .caption = state.selection { state.select(.none) }
            editingCueId = nil
            syncProjectFromManager()
            showToast("All captions removed")
        } catch {
            print("[CaptionTrackRow] deleteAllCaptions error: \(error)")
        }
    }

    /// Reflects ProjectManager's persisted result back onto the shared EditorState clock — mirrors
    /// AudioTrackRow/TimelineTrackView's `syncProjectFromManager()` (EditorState "owns
    /// playback/selection state, not persistence" per its own doc comment).
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
