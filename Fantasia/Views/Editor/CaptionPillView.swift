// CaptionPillView.swift
// Fantasia
// Phase 13, Plan 15: one caption CUE's blue timeline pill (SC5) — body-drag to move (retime both
// start/end together), edge-handle drag to retime start/end independently, mirroring
// ClipPillView/TextOverlayPillView/AudioPillView's gesture layering exactly
// (`.contentShape(Rectangle()).onTapGesture{onSelect()}.highPriorityGesture(bodyDragGesture)` +
// `.highPriorityGesture` on invisible edge-handle overlays). ONE pill per cue (a displayed
// line/phrase), NOT per word — per-word timing fine-tune is explicitly deferred (13-CONTEXT.md
// <deferred>); word-level editing instead happens via tap-to-edit (Spike 002's validated pattern),
// adapted here from the spike's fullscreen-overlay context into this timeline-pill context (the
// live karaoke overlay itself is deliberately deferred to Plan 16 per this plan's objective).
//
// `onEditToggle` is NOT part of the plan's minimum interface list, but is required to actually
// TRIGGER `isEditing` from inside the pill: the persistent contextual Edit/Delete/Done bar that
// would normally drive this (13-UI-SPEC.md Delta 3) isn't wired until Plan 16/17. Without some
// affordance, "tap-to-edit" would be unreachable/unverifiable within this plan's scope (Rule 2) —
// so, mirroring ClipPillView's `isSelected`-gated delete-button treatment, a second pencil
// affordance appears alongside delete when the pill is selected.
//
// 26-30pt pill height / 12pt edge handles are HIG-exempt continuous-drag hit targets per
// 13-UI-SPEC.md (same exemption ClipPillView/TextOverlayPillView/AudioPillView's edge handles
// rely on) — do not enlarge to 44pt.

import SwiftUI

struct CaptionPillView: View {
    let cue: CaptionCue
    let pxPerSecond: Double
    let isSelected: Bool
    /// Set by the caller (CaptionTrackRow) when this cue is both selected AND the user tapped
    /// the pencil affordance — swaps the pill's label for an inline transcript-editable TextField.
    let isEditing: Bool
    let onSelect: () -> Void
    /// Fires once, on drag release (body move OR edge-handle retime), with the final
    /// (startSeconds, endSeconds) — the CALLER (CaptionTrackRow) PATCHes via
    /// `ProjectManager.updateCaptionCue`.
    let onRetime: (Double, Double) -> Void
    /// Fires once, on TextField submit, with a re-split word list (evenly distributed across the
    /// cue's existing [start, end] window — per-word manual timing is deferred, see file header).
    let onWordsCommit: ([CaptionWord]) -> Void
    /// Toggles `isEditing` for this cue in the caller — see file header.
    let onEditToggle: () -> Void

    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStartTime: Double? = nil
    @State private var rightDragStartTime: Double? = nil
    @State private var editingText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    // 13-22 i4: commit-on-release — onChanged only updates these LOCAL preview values (pill
    // width/offset render from them); onRetime fires ONCE in .onEnded with the final values.
    // Previously onRetime fired on every onChanged (a network PATCH + full re-sync per finger
    // movement). nil = idle, render from `cue`'s committed values.
    @State private var previewStart: Double? = nil
    @State private var previewEnd: Double? = nil

    private let blue = Color(red: 0.169, green: 0.561, blue: 0.851)         // #2B8FD9
    private let pillHeight: CGFloat = 28

    private var effectiveStart: Double { previewStart ?? cue.startSeconds }
    private var effectiveEnd: Double { previewEnd ?? cue.endSeconds }
    private var width: Double { max((effectiveEnd - effectiveStart) * pxPerSecond, 30) }
    // The parent row positions this pill via `.offset(x: cue.startSeconds * pxPerSecond)` using
    // the COMMITTED startSeconds (unchanged until onRetime fires at release) — this local offset
    // compensates during a left-handle drag so the leading edge tracks the finger while the
    // trailing edge stays visually fixed. Zero during a right-handle or body drag.
    private var trimHandleOffsetX: CGFloat { CGFloat(effectiveStart - cue.startSeconds) * pxPerSecond }

    private var joinedWords: String {
        let text = cue.words.map(\.text).joined(separator: " ")
        return text.isEmpty ? "Caption" : text
    }

    var body: some View {
        Group {
            if isEditing {
                editingPill
            } else {
                staticPill
            }
        }
        .frame(width: width, height: pillHeight)
        .offset(x: dragTranslation + trimHandleOffsetX)
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                editingText = joinedWords
                isTextFieldFocused = true
            } else {
                isTextFieldFocused = false
            }
        }
    }

    // MARK: - Static pill (selected/unselected, not mid-edit)

    private var staticPill: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(blue)
            Text(joinedWords)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.white : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .highPriorityGesture(bodyDragGesture)
        .overlay(alignment: .leading) {
            if isSelected { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected { handle.highPriorityGesture(rightHandleGesture) }
        }
        .overlay(alignment: .topLeading) {
            if isSelected { editButton }
        }
    }

    // MARK: - Editing pill (transcript-style TextField, pre-filled with this cue's words) —
    // deliberately NOT wrapped in onTapGesture/highPriorityGesture like staticPill: those would
    // compete with the TextField's own tap-to-focus (the exact kind of "surprise" Spike 002 was
    // run to catch), so this is a separate, simpler view.

    private var editingPill: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(blue)
            TextField("Caption text", text: $editingText)
                .focused($isTextFieldFocused)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .submitLabel(.done)
                .padding(.horizontal, 8)
                .onSubmit { commitEdit() }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white, lineWidth: 2)
        )
    }

    private var handle: some View {
        ZStack {
            Color.white.opacity(0.001) // invisible but hit-testable — widens the drag target
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: 2, height: 14)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
    }

    private var editButton: some View {
        Button(action: onEditToggle) {
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .offset(x: -4, y: -6)
        .accessibilityLabel("Edit caption words")
    }

    // MARK: - Body drag (move — retimes the whole [start, end] window together)

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                dragTranslation = 0
                let duration = cue.endSeconds - cue.startSeconds
                let newStart = max(0, cue.startSeconds + deltaSeconds)
                onRetime(newStart, newStart + duration)
            }
    }

    // MARK: - Edge-handle retime (start/end independently)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStartTime == nil { leftDragStartTime = cue.startSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                var newStart = (leftDragStartTime ?? cue.startSeconds) + deltaSeconds
                let endBound = previewEnd ?? cue.endSeconds
                newStart = max(0, min(newStart, endBound - 0.3))
                previewStart = newStart
            }
            .onEnded { _ in
                let finalStart = previewStart ?? cue.startSeconds
                let finalEnd = previewEnd ?? cue.endSeconds
                leftDragStartTime = nil
                onRetime(finalStart, finalEnd)
                previewStart = nil
                previewEnd = nil
            }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if rightDragStartTime == nil { rightDragStartTime = cue.endSeconds }
                let deltaSeconds = Double(value.translation.width) / pxPerSecond
                let startBound = previewStart ?? cue.startSeconds
                let newEnd = max(startBound + 0.3, (rightDragStartTime ?? cue.endSeconds) + deltaSeconds)
                previewEnd = newEnd
            }
            .onEnded { _ in
                let finalStart = previewStart ?? cue.startSeconds
                let finalEnd = previewEnd ?? cue.endSeconds
                rightDragStartTime = nil
                onRetime(finalStart, finalEnd)
                previewStart = nil
                previewEnd = nil
            }
    }

    // MARK: - Tap-to-edit commit (Spike 002's validated pattern, adapted to this timeline pill)
    //
    // Manual per-word timing fine-tune is explicitly deferred (13-CONTEXT.md <deferred>) — the
    // heuristic here evenly distributes the cue's EXISTING [start, end] duration across the new
    // word count, preserving the cue's overall timing window untouched.

    private func commitEdit() {
        let tokens = editingText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else {
            onEditToggle()
            return
        }
        let totalDuration = max(0, cue.endSeconds - cue.startSeconds)
        let perWord = totalDuration / Double(tokens.count)
        var words: [CaptionWord] = []
        for (index, token) in tokens.enumerated() {
            let start = cue.startSeconds + perWord * Double(index)
            let end = index == tokens.count - 1 ? cue.endSeconds : start + perWord
            words.append(CaptionWord(id: nil, text: token, startSeconds: start, endSeconds: end))
        }
        onWordsCommit(words)
        onEditToggle()
    }
}
