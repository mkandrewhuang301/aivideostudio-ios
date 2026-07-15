// TextOverlayCanvasView.swift
// Fantasia
// Phase 13, Plan 13: the on-video Text overlay rendering surface (SC3) — draggable/resizable
// overlays with CapCut-style corner controls (✕ delete / ✎ edit / ⧉ duplicate / ⤡ resize), mounted
// as an overlay on top of EditorView's AVPlayer preview stage (Task 3). Reproduces the locked
// sketch's `.otext`/`.otext-btn` markup (.planning/sketches/001-video-editor-v0/index.html) and
// 13-UI-SPEC.md's Editor Delta 5 (fixed single style — only position + uniform 0.5x-3x scale are
// user controls, no font/color picker).
//
// `TextOverlay.widthNorm` doubles as the font-scale multiplier here (not a literal normalized
// width) — this mirrors the sketch's `t.scale` field and the plan's "PATCH width_norm on drag end"
// contract for the resize handle.
//
// Corner delete/edit/duplicate buttons are DISCRETE taps and therefore get a 44pt tap target
// (13-UI-SPEC.md's 44pt exception list explicitly names "corner controls on Text overlays") even
// though the visual glyph stays small (26pt circle, matching the sketch). The resize handle is a
// CONTINUOUS-drag control and is exempt from the 44pt rule (same exemption ClipPillView's edge
// handles already rely on) — kept visually small per the sketch.

import SwiftUI

struct TextOverlayCanvasView: View {
    @Environment(ProjectManager.self) private var projectManager

    let state: EditorState
    /// 13-22 i6.2: `false` in the fullscreen preview (a preview-only surface, never editing) —
    /// renders plain text on video regardless of `state.selection`, no selectionFrame/corner
    /// buttons/rotation handle. Defaults to `true` (the inline editor's existing behavior).
    var showsControls: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(visibleOverlays) { overlay in
                    TextOverlayItemView(
                        overlay: overlay,
                        canvasSize: geo.size,
                        isSelected: state.selection == .text(overlay.id),
                        showsControls: showsControls,
                        startEditing: state.editRequestedTextId == overlay.id,
                        onSelect: { state.select(.text(overlay.id)) },
                        onMove: { xNorm, yNorm in
                            Task { await persistMove(id: overlay.id, xNorm: xNorm, yNorm: yNorm) }
                        },
                        onResize: { scale in
                            Task { await persistResize(id: overlay.id, scale: scale) }
                        },
                        onRotate: { rotation in
                            Task { await persistRotation(id: overlay.id, rotation: rotation) }
                        },
                        onEditCommit: { newText in
                            Task { await persistTextEdit(id: overlay.id, text: newText) }
                        },
                        onEditTriggerConsumed: {
                            if state.editRequestedTextId == overlay.id { state.editRequestedTextId = nil }
                        },
                        onDelete: {
                            Task { await deleteOverlay(id: overlay.id) }
                        },
                        onDuplicate: {
                            Task { await duplicateOverlay(overlay) }
                        }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(true)
    }

    /// Only overlays whose [startSeconds, endSeconds] window contains the current playhead render
    /// on the video canvas — matches how these overlays would actually appear burned into playback.
    private var visibleOverlays: [TextOverlay] {
        state.project.textOverlays.filter {
            $0.startSeconds <= state.currentTime && state.currentTime <= $0.endSeconds
        }
    }

    // MARK: - Persistence (SC3: position/size/timing persist to the backend)
    //
    // EditProject is a VALUE type: every ProjectManager mutation updates the MANAGER's copy
    // (`loadedProject`), never `state.project` — each success path below must reconcile via
    // syncProjectFromManager() or the canvas snaps back to the stale value on next render
    // (13-20 i1 sweep, same bug class as EditorView's bottom-bar actions).

    // F8 (Plan 13-21): move/resize/rotate/edit all fire ONCE per gesture (at release, or on
    // TextField commit) — see resizeDragGesture/rotationDragGesture/moveDragGesture's `.onEnded`-
    // only wiring in TextOverlayItemView below — so these record directly, no debounce needed
    // (unlike the timeline pills' continuous edge-handle retime).

    private func persistMove(id: String, xNorm: Double, yNorm: Double) async {
        let before = state.project.textOverlays.first(where: { $0.id == id })
        do {
            try await projectManager.updateTextOverlay(textId: id, xNorm: xNorm, yNorm: yNorm)
            syncProjectFromManager()
            if let before {
                state.history.record(UndoableAction(
                    label: "Move text",
                    undo: { try await projectManager.updateTextOverlay(textId: id, xNorm: before.xNorm, yNorm: before.yNorm) },
                    redo: { try await projectManager.updateTextOverlay(textId: id, xNorm: xNorm, yNorm: yNorm) }
                ))
            }
        } catch {
            print("[TextOverlayCanvasView] move error: \(error)")
        }
    }

    private func persistResize(id: String, scale: Double) async {
        let beforeScale = state.project.textOverlays.first(where: { $0.id == id })?.widthNorm
        do {
            try await projectManager.updateTextOverlay(textId: id, widthNorm: scale)
            syncProjectFromManager()
            if let beforeScale {
                state.history.record(UndoableAction(
                    label: "Resize text",
                    undo: { try await projectManager.updateTextOverlay(textId: id, widthNorm: beforeScale) },
                    redo: { try await projectManager.updateTextOverlay(textId: id, widthNorm: scale) }
                ))
            }
        } catch {
            print("[TextOverlayCanvasView] resize error: \(error)")
        }
    }

    private func persistRotation(id: String, rotation: Double) async {
        let beforeRotation = state.project.textOverlays.first(where: { $0.id == id })?.rotation
        do {
            try await projectManager.updateTextOverlay(textId: id, rotation: rotation)
            syncProjectFromManager()
            if let beforeRotation {
                state.history.record(UndoableAction(
                    label: "Rotate text",
                    undo: { try await projectManager.updateTextOverlay(textId: id, rotation: beforeRotation) },
                    redo: { try await projectManager.updateTextOverlay(textId: id, rotation: rotation) }
                ))
            }
        } catch {
            print("[TextOverlayCanvasView] rotate error: \(error)")
        }
    }

    private func persistTextEdit(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let beforeText = state.project.textOverlays.first(where: { $0.id == id })?.text
        do {
            try await projectManager.updateTextOverlay(textId: id, text: trimmed)
            syncProjectFromManager()
            if let beforeText {
                state.history.record(UndoableAction(
                    label: "Edit text",
                    undo: { try await projectManager.updateTextOverlay(textId: id, text: beforeText) },
                    redo: { try await projectManager.updateTextOverlay(textId: id, text: trimmed) }
                ))
            }
        } catch {
            print("[TextOverlayCanvasView] edit error: \(error)")
        }
    }

    private func deleteOverlay(id: String) async {
        guard let overlay = state.project.textOverlays.first(where: { $0.id == id }) else { return }
        do {
            try await projectManager.deleteTextOverlay(textId: id)
            if state.selection == .text(id) { state.select(.none) }
            syncProjectFromManager()
            var currentId = id
            state.history.record(UndoableAction(
                label: "Delete text",
                undo: {
                    try await projectManager.addTextOverlay(
                        text: overlay.text, xNorm: overlay.xNorm, yNorm: overlay.yNorm,
                        widthNorm: overlay.widthNorm, rotation: overlay.rotation,
                        startSeconds: overlay.startSeconds, endSeconds: overlay.endSeconds
                    )
                    if let recreated = projectManager.loadedProject?.textOverlays.last { currentId = recreated.id }
                },
                redo: { try await projectManager.deleteTextOverlay(textId: currentId) }
            ))
        } catch {
            print("[TextOverlayCanvasView] delete error: \(error)")
        }
    }

    private func duplicateOverlay(_ overlay: TextOverlay) async {
        let newXNorm = min(0.94, overlay.xNorm + 0.04)
        let newYNorm = min(0.94, overlay.yNorm + 0.04)
        let idsBefore = Set(state.project.textOverlays.map(\.id))
        do {
            try await projectManager.addTextOverlay(
                text: overlay.text,
                xNorm: newXNorm,
                yNorm: newYNorm,
                widthNorm: overlay.widthNorm,
                rotation: overlay.rotation,
                startSeconds: overlay.startSeconds,
                endSeconds: overlay.endSeconds
            )
            syncProjectFromManager()
            if var newId = Set(state.project.textOverlays.map(\.id)).subtracting(idsBefore).first {
                state.history.record(UndoableAction(
                    label: "Duplicate text",
                    undo: { try await projectManager.deleteTextOverlay(textId: newId) },
                    redo: {
                        try await projectManager.addTextOverlay(
                            text: overlay.text, xNorm: newXNorm, yNorm: newYNorm, widthNorm: overlay.widthNorm,
                            rotation: overlay.rotation, startSeconds: overlay.startSeconds, endSeconds: overlay.endSeconds
                        )
                        if let recreated = projectManager.loadedProject?.textOverlays.last { newId = recreated.id }
                    }
                ))
            }
        } catch {
            print("[TextOverlayCanvasView] duplicate error: \(error)")
        }
    }

    /// Mirrors TimelineTrackView/AudioTrackRow's identical helper — reflects ProjectManager's
    /// persisted result back onto the shared EditorState.
    private func syncProjectFromManager() {
        if let refreshed = projectManager.loadedProject {
            state.project = refreshed
        }
    }
}

// MARK: - One on-video text overlay: drag-anywhere-on-body move, corner controls when selected.

private struct TextOverlayItemView: View {
    let overlay: TextOverlay
    let canvasSize: CGSize
    let isSelected: Bool
    /// 13-22 i6.2: gates selectionFrame/corner buttons/rotation handle — `false` in the fullscreen
    /// preview surface (see TextOverlayCanvasView.showsControls's doc comment).
    let showsControls: Bool
    /// Flips true when the contextual bottom bar's "Edit" action targets this overlay (13-19 Task
    /// A) — mirrors tapping the ✎ corner button. Consumed via `onEditTriggerConsumed` immediately.
    let startEditing: Bool
    let onSelect: () -> Void
    /// Fires once, on drag release, with the final normalized (xNorm, yNorm) — mirrors
    /// ClipPillView's onReorder/onTrimChange contract: this view only previews the live drag via a
    /// local offset, the CALLER performs the PATCH.
    let onMove: (Double, Double) -> Void
    /// Fires once, on resize-handle release, with the final font-scale factor (0.5x-3x).
    let onResize: (Double) -> Void
    /// Fires once, on rotation-handle release, with the final angle in degrees (clockwise-positive,
    /// matching `.rotationEffect`) — 13-19 Task H.
    let onRotate: (Double) -> Void
    /// Fires once, when the inline edit TextField commits a non-empty, changed value.
    let onEditCommit: (String) -> Void
    let onEditTriggerConsumed: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var scaleDelta: Double = 0
    @State private var rotationDelta: Double = 0
    @State private var isEditing = false
    @State private var editDraft = ""
    @FocusState private var editFieldFocused: Bool

    private let baseFontSize: CGFloat = 26
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439) // #FF5470

    private var baseScale: Double { overlay.widthNorm ?? 1.0 }
    private var liveScale: Double { min(3.0, max(0.5, baseScale + scaleDelta)) }
    private var liveRotation: Double { overlay.rotation + rotationDelta }

    private var basePosition: CGPoint {
        CGPoint(x: overlay.xNorm * canvasSize.width, y: overlay.yNorm * canvasSize.height)
    }

    var body: some View {
        Group {
            if isEditing {
                editingView
            } else {
                displayView
            }
        }
        .position(x: basePosition.x + dragOffset.width, y: basePosition.y + dragOffset.height)
        .onAppear { editDraft = overlay.text }
        .onChange(of: overlay.text) { _, newValue in
            if !isEditing { editDraft = newValue }
        }
        .onChange(of: startEditing) { _, shouldStart in
            guard shouldStart, !isEditing else { return }
            editDraft = overlay.text
            isEditing = true
            onEditTriggerConsumed()
        }
    }

    // The ENTIRE box — text, selection frame, and all four corner controls — is composed FIRST,
    // then `.rotationEffect` is the LAST modifier applied, so every control rotates together as
    // one rigid unit around the box's center (CapCut-style), and `.overlay(alignment:)` below
    // aligns against the box's own (pre-rotation) bounds rather than a screen-axis-aligned one.
    //
    // F14 (Plan 13-21) corner-offset geometry: `.overlay(alignment:)` positions each button's
    // OWN 44×44 (or 34×34 for the smaller resize handle) invisible hit frame so ITS corner
    // coincides with the TEXT view's frame corner — but `selectionFrame` below draws the VISIBLE
    // stroke `.padding(-8)` OUTSIDE that same text frame (an 8pt margin around the text, matching
    // the sketch), so the visible stroke's actual corner sits 8pt further out than the text
    // frame's corner. The circle glyph is centered inside its hit frame, so with a 44pt hit frame
    // and a 13pt visible radius, the circle's UNADJUSTED center sits (22,22) inside the text-frame
    // corner as the anchor — 8pt more once you account for the stroke's own outward expansion.
    // Each offset below is `-(hitFrame/2 + strokeExpansion)` on both axes (toward the corner),
    // computed to land the circle's center exactly ON the visible stroke's corner — VERIFIED via
    // zoomed simulator screenshot (13-21 F14 verification gate), not eyeballed.
    private var displayView: some View {
        Text(overlay.text)
            .font(.system(size: baseFontSize * liveScale, weight: .heavy))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.65), radius: 10, y: 2)
            .fixedSize()
            .padding(6)
            .overlay(selectionFrame)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .highPriorityGesture(moveDragGesture)
            .overlay(alignment: .topLeading) {
                if showsControls && isSelected { deleteButton.offset(x: -30, y: -30) }
            }
            .overlay(alignment: .topTrailing) {
                if showsControls && isSelected { editButton.offset(x: 30, y: -30) }
            }
            .overlay(alignment: .bottomLeading) {
                if showsControls && isSelected { duplicateButton.offset(x: -30, y: 30) }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsControls && isSelected { resizeHandle.offset(x: 25, y: 25) }
            }
            .overlay(alignment: .top) {
                // 13-23 J6: with `.overlay(alignment: .top)` the handle assembly's frame is
                // top-aligned to the TEXT frame (its top at text-frame y = 0). The assembly's
                // frame height is stemHeight + dotRadius (the dot's top half pokes above the stem
                // top — see rotationHandle's own geometry doc) and its BOTTOM edge IS the stem's
                // bottom. That bottom must land on the selection frame's top border (text-frame
                // y = -8, from selectionFrame's `.padding(-8)`), so:
                // offset = -(assemblyHeight + 8) = -(stemHeight + dotRadius + 8). Computed, not
                // eyeballed.
                if showsControls && isSelected {
                    rotationHandle.offset(y: -(rotationStemHeight + rotationDotDiameter / 2 + 8))
                }
            }
            .rotationEffect(.degrees(liveRotation))
    }

    private var editingView: some View {
        TextField("Text", text: $editDraft)
            .font(.system(size: baseFontSize * liveScale, weight: .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .focused($editFieldFocused)
            .submitLabel(.done)
            .fixedSize()
            .frame(minWidth: 60)
            .onSubmit { commitEdit() }
            .onChange(of: editFieldFocused) { _, focused in
                if !focused { commitEdit() }
            }
            .onAppear { editFieldFocused = true }
    }

    private var selectionFrame: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.white, lineWidth: 1.5)
            .padding(-8)
            .opacity(showsControls && isSelected ? 1 : 0)
    }

    // MARK: - Corner controls (delete / edit / duplicate = discrete tap, 44pt target;
    // resize = continuous drag, exempt from 44pt per 13-UI-SPEC.md)

    private var deleteButton: some View {
        cornerButton(systemName: "xmark", label: "Delete text overlay", background: destructive) {
            onDelete()
        }
    }

    private var editButton: some View {
        cornerButton(systemName: "pencil", label: "Edit text overlay") {
            editDraft = overlay.text
            isEditing = true
        }
    }

    private var duplicateButton: some View {
        cornerButton(systemName: "square.on.square", label: "Duplicate text overlay") {
            onDuplicate()
        }
    }

    // 13-22 i7.3: visible circles 26 → 22pt, glyphs 11 → 9pt (the ✕ especially — it read as
    // oversized). Hit targets are UNCHANGED (44pt discrete-tap here, 34pt continuous-drag on
    // resizeHandle below) — the corner-offset math (deleteButton/editButton/duplicateButton/
    // resizeHandle's `.offset` values above) is `-(hitFrame/2 + strokeExpansion)`, which depends
    // ONLY on the hit frame's size, not the visible circle's diameter (the circle is centered
    // WITHIN the unchanged hit frame either way) — so those offsets need no recomputation; the
    // circle's center still lands exactly on the selection-frame's corner.
    private func cornerButton(
        systemName: String,
        label: String,
        background: Color = Color.black.opacity(0.85),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Color.clear.frame(width: 44, height: 44)
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(background, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(label)
    }

    private var resizeHandle: some View {
        ZStack {
            Color.white.opacity(0.001).frame(width: 34, height: 34)
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        .highPriorityGesture(resizeDragGesture)
        .accessibilityLabel("Resize text overlay")
    }

    // MARK: - Rotation (NEW, 13-19 Task H; geometry rebuilt 13-23 J6) — short vertical line
    // rising from the box's top-center to a small dot; press-drag the dot to rotate clockwise/
    // counterclockwise. Continuous-drag control, exempt from the 44pt rule (same exemption
    // resizeHandle relies on).
    //
    // J6 root cause of "dot disconnected from the stem": the previous version bottom-aligned a
    // 28×28 hit-area ZStack (dot centered inside) against the 18pt stem frame, then offset that
    // layer up by the FULL stem height — the dot's center landed at hit-half (14pt) MINUS the
    // intended anchor above the stem top, i.e. 14pt above it, leaving a visible ~9pt gap between
    // the dot's bottom edge and the stem's top pixel.
    //
    // Rebuilt with explicit geometry, no alignment/offset stacking guesswork:
    //   - assembly frame: width 28 (hit width), height = stemHeight + dotRadius, bottom-aligned
    //     content — the frame's BOTTOM edge is the stem's bottom endpoint (the mount anchor).
    //   - stem: 1.5 × 18, bottom at the frame's bottom → stem TOP sits at frame-y = dotRadius.
    //   - dot: 10pt circle, bottom-aligned like the stem (center at frame-bottom − 5), then
    //     offset UP by (stemHeight − dotRadius) so its CENTER lands exactly ON the stem's top
    //     endpoint (frame-y = dotRadius): -13 = -(18 − 5). No gap — the dot's lower half overlaps
    //     the stem's last 5 pixels.
    //   - contentShape covers the full 28-wide assembly (dot + entire stem) for the drag target.
    private let rotationStemHeight: CGFloat = 18
    private let rotationDotDiameter: CGFloat = 10

    private var rotationHandle: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 1.5, height: rotationStemHeight)
            Circle()
                .fill(Color.white)
                .frame(width: rotationDotDiameter, height: rotationDotDiameter)
                .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                .offset(y: -(rotationStemHeight - rotationDotDiameter / 2)) // center == stem top
        }
        .frame(width: 28, height: rotationStemHeight + rotationDotDiameter / 2, alignment: .bottom)
        .contentShape(Rectangle())
        .highPriorityGesture(rotationDragGesture)
        .accessibilityLabel("Rotate text overlay")
    }

    // Approximate distance (points) from the box's CENTER to the handle's rest position — the box
    // varies in height with font size/scale, so this is a fixed, "close enough" constant rather
    // than exact per-overlay geometry (same pragmatic tradeoff resizeHandle's /120 divisor makes).
    private let rotationHandleRadius: Double = 62

    // SwiftUI delivers DragGesture translation in the GESTURE-ATTACHED view's own local coordinate
    // space, already adjusted for any ancestor `.rotationEffect` — so at the CURRENT (possibly
    // already-rotated) orientation, "straight up" from the handle's rest point is still (0, -R) in
    // this local frame. The finger's current vector from box-center is therefore
    // (0, -R) + translation; atan2(x, -y) of that vector gives the ADDITIONAL clockwise angle
    // (SwiftUI's .rotationEffect convention) relative to the box's current rotation — i.e. exactly
    // `rotationDelta`, added to `overlay.rotation` by `liveRotation` above.
    private var rotationDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                let vectorX = value.translation.width
                let vectorY = -rotationHandleRadius + value.translation.height
                rotationDelta = atan2(vectorX, -vectorY) * 180 / .pi
            }
            .onEnded { _ in
                let finalRotation = liveRotation
                rotationDelta = 0
                onRotate(finalRotation)
            }
    }

    // MARK: - Move (drag-anywhere-on-body)

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragOffset = value.translation
            }
            .onEnded { value in
                let deltaXNorm = value.translation.width / max(canvasSize.width, 1)
                let deltaYNorm = value.translation.height / max(canvasSize.height, 1)
                let newX = min(0.98, max(0.02, overlay.xNorm + deltaXNorm))
                let newY = min(0.98, max(0.02, overlay.yNorm + deltaYNorm))
                dragOffset = .zero
                onMove(newX, newY)
            }
    }

    // MARK: - Resize (bottom-right corner drag scales font 0.5x-3x, matching the sketch's /120
    // divisor feel)

    private var resizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                scaleDelta = Double(value.translation.width) / 120.0
            }
            .onEnded { _ in
                let finalScale = liveScale
                scaleDelta = 0
                onResize(finalScale)
            }
    }

    // MARK: - Edit commit

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        editFieldFocused = false
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != overlay.text {
            onEditCommit(trimmed)
        } else {
            editDraft = overlay.text
        }
    }
}
