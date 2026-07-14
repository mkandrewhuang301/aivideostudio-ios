// TimelineTrackView.swift
// Fantasia
// Phase 13, Plan 12: the REAL filmstrip timeline — ruler, fixed-center playhead, background-scrub
// gesture, the clip row (ClipPillView per clip + inline "+" add-clip tile), and the stacked
// Text/Audio/Caption track-row mount points that plans 13-15 fill in. Replaces plan 11's
// TimelineMountView(state:) placeholder in EditorView.swift.
//
// Gesture mechanics reproduce Spike 001 verbatim (.planning/spikes/001-caption-timing-drag/
// Sources/TimelineView.swift, VALIDATED on-device): content is translated under a FIXED center
// playhead via `.offset()`, never a native scrolling container. Background `DragGesture(minimumDistance: 2)`
// scrubs `state.currentTime`; `ClipPillView`'s `.highPriorityGesture`s (body-move / edge-handle
// trim) win over this background gesture per SwiftUI's topmost-view-at-touch-point hit-testing —
// no manual gesture-priority arbitration needed beyond that, exactly as the spike proved.
//
// Clips are laid out SEQUENTIALLY (adjacent, back-to-back playback) via a plain HStack — unlike
// the freeform-position Text/Audio/Caption pills (plans 13-15), a clip's timeline position is
// always the sum of every earlier clip's trimmed duration, never an independent x/y. Dragging a
// clip's body previews a live visual offset and, on release, PATCHes its `sort_order` to the
// dropped-on neighbor's position — the server is trusted to resequence the rest (same contract
// ProjectManager.updateAudioClip's `sortOrder` param already relies on for audio pill reordering).

import SwiftUI

struct TimelineTrackView: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState

    let pxPerSecond: Double = 44
    private let clipRowHeight: CGFloat = 58
    private let trackBackground = Color(red: 0.078, green: 0.078, blue: 0.098) // #141419
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)              // #8C59FF

    @State private var scrubDragStartTime: Double? = nil
    @State private var showAddMediaSheet = false
    @State private var isAddingClip = false
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let viewportWidth = geo.size.width
            let contentOffset = viewportWidth / 2 - state.currentTime * pxPerSecond
            let contentWidth = max(state.totalDuration * pxPerSecond, viewportWidth)

            ZStack(alignment: .topLeading) {
                trackBackground

                Color.white.opacity(0.04)
                    .contentShape(Rectangle())
                    .gesture(scrubGesture)

                VStack(alignment: .leading, spacing: 6) {
                    ruler(contentWidth: contentWidth)
                    clipRow
                    TextOverlayTrackRow(state: state, pxPerSecond: pxPerSecond)
                    AudioTrackRow(state: state, pxPerSecond: pxPerSecond)
                    CaptionTrackRow(state: state, pxPerSecond: pxPerSecond)
                }
                .frame(width: contentWidth, alignment: .leading)
                .offset(x: contentOffset, y: 10)
            }
            .clipped()
            .overlay(alignment: .top) {
                // Fixed-center playhead — content (ruler + clip row + track rows) translates
                // under this via .offset() above; the playhead itself never moves.
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 120)
                    .shadow(color: .white.opacity(0.5), radius: 4)
                    .position(x: viewportWidth / 2, y: 60)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .trailing) {
                addClipTile
                    .padding(.trailing, 8)
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 6)
                        .transition(.opacity)
                }
            }
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAddMediaSheet) {
            MediaPickerSheet(onAdd: handlePickedMedia)
        }
    }

    // MARK: - Background scrub (Spike 001 verbatim)

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if scrubDragStartTime == nil { scrubDragStartTime = state.currentTime }
                guard let startTime = scrubDragStartTime else { return }
                let deltaTime = -value.translation.width / pxPerSecond
                state.currentTime = min(max(startTime + deltaTime, 0), state.totalDuration)
            }
            .onEnded { _ in scrubDragStartTime = nil }
    }

    // MARK: - Ruler: 1s tick marks, .monospacedDigit() labels every 5s

    private func ruler(contentWidth: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...max(Int(state.totalDuration.rounded(.up)), 1), id: \.self) { sec in
                VStack(spacing: 2) {
                    if sec % 5 == 0 {
                        Text("\(sec)s")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 1, height: sec % 5 == 0 ? 8 : 4)
                }
                .offset(x: Double(sec) * pxPerSecond, y: sec % 5 == 0 ? 0 : 11)
            }
        }
        .frame(width: contentWidth, height: 24, alignment: .topLeading)
    }

    // MARK: - Clip row: sequential, adjacent ClipPillViews (SC1/SC2)

    private var sortedClips: [ProjectClip] {
        state.project.clips.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var clipRow: some View {
        HStack(spacing: 3) {
            ForEach(sortedClips) { clip in
                ClipPillView(
                    clip: clip,
                    pxPerSecond: pxPerSecond,
                    isSelected: state.selection == .clip(clip.id),
                    onSelect: { state.select(.clip(clip.id)) },
                    onReorder: { translation in handleReorder(clip: clip, translation: translation) },
                    onTrimChange: { newStart, newEnd in
                        Task { await updateClipTrim(clipId: clip.id, start: newStart, end: newEnd) }
                    },
                    onDelete: { Task { await deleteClip(clipId: clip.id) } }
                )
            }
        }
        .frame(height: clipRowHeight, alignment: .leading)
    }

    // MARK: - Inline "+" add-clip tile (D-08/D-09) — fixed at the trailing edge, clips scroll
    // under it per the locked sketch ("+ : fixed square in frame on the right, always visible").

    private var addClipTile: some View {
        Button {
            showAddMediaSheet = true
        } label: {
            ZStack {
                if isAddingClip {
                    ProgressView().tint(accent)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 46, height: 46)
            .background(Color(red: 0.11, green: 0.11, blue: 0.137), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(accent.opacity(0.7), lineWidth: 1)
            )
            .shadow(color: accent.opacity(0.35), radius: 8)
        }
        .disabled(isAddingClip)
        .accessibilityLabel("Add clip")
    }

    // MARK: - Clip mutations — reconcile `state.project` from the reloaded `projectManager
    // .loadedProject` after every mutation (EditorState "owns playback/selection state, not
    // persistence" per its own doc comment — this view is the caller responsible for reflecting
    // ProjectManager's persisted result back onto the shared clock).

    private func handlePickedMedia(_ items: [PickedMedia]) {
        guard !items.isEmpty else { return }
        isAddingClip = true
        Task {
            for item in items {
                do {
                    switch item {
                    case .generation(let id, _):
                        try await projectManager.importClip(generationId: id)
                    case .upload(let url, let mediaType):
                        try await projectManager.uploadClip(fileURL: url, mediaType: mediaType)
                    }
                } catch {
                    print("[TimelineTrackView] add clip error: \(error)")
                }
            }
            syncProjectFromManager()
            isAddingClip = false
        }
    }

    private func updateClipTrim(clipId: String, start: Double, end: Double) async {
        do {
            try await projectManager.updateClip(clipId: clipId, trimStart: start, trimEnd: end)
            syncProjectFromManager()
        } catch {
            print("[TimelineTrackView] updateClipTrim error: \(error)")
        }
    }

    private func deleteClip(clipId: String) async {
        do {
            try await projectManager.deleteClip(clipId: clipId)
            if state.selection == .clip(clipId) { state.select(.none) }
            syncProjectFromManager()
            showToast("Clip deleted")
        } catch {
            print("[TimelineTrackView] deleteClip error: \(error)")
        }
    }

    /// Live-preview drag ends here: `translation` is the final horizontal drag distance (points).
    /// Converts it to a target index by comparing the dragged clip's projected new center against
    /// every clip's timeline position, then PATCHes the dragged clip's `sort_order` to the target
    /// neighbor's current value — the backend is trusted to resequence the rest, mirroring the
    /// same `sortOrder` reorder contract `ProjectManager.updateAudioClip` already exposes.
    private func handleReorder(clip: ProjectClip, translation: CGFloat) {
        let clips = sortedClips
        guard let currentIndex = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        guard translation != 0 else { return }

        var starts: [Double] = []
        var acc = 0.0
        for c in clips {
            starts.append(acc)
            acc += duration(of: c)
        }

        let deltaSeconds = Double(translation) / pxPerSecond
        let newCenter = starts[currentIndex] + duration(of: clip) / 2 + deltaSeconds

        var targetIndex = clips.count - 1
        for (index, c) in clips.enumerated() {
            if newCenter < starts[index] + duration(of: c) / 2 {
                targetIndex = index
                break
            }
        }
        guard targetIndex != currentIndex, clips.indices.contains(targetIndex) else { return }

        let targetSortOrder = clips[targetIndex].sortOrder
        Task {
            do {
                try await projectManager.updateClip(clipId: clip.id, sortOrder: targetSortOrder)
                syncProjectFromManager()
            } catch {
                print("[TimelineTrackView] reorderClip error: \(error)")
            }
        }
    }

    private func duration(of clip: ProjectClip) -> Double {
        let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
        return max(0, end - clip.trimStartSeconds)
    }

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
