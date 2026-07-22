// EditorBottomBar.swift
// Fantasia
// Phase 13-19 Task A: the persistent bottom bar the Editor was missing entirely — default
// (nothing selected) `Edit · Text · Audio · Captions`, swapping to a contextual
// Split/Edit/Duplicate/Delete/Done row per `state.selection` (mirrors the locked sketch's
// `updateHybrid()`, .planning/sketches/001-video-editor-v0/index.html:573, and 13-UI-SPEC.md
// Delta 2). This view is DELIBERATELY dumb — it renders buttons and calls closures; the owner
// (EditorView) does every `projectManager` call, sheet presentation, and toast.
//
// Forced-dark palette (matches EditorView.canvasBackground / topBar convention) — this bar is
// part of the same always-dark Editor canvas, never affected by ThemeManager.
//
// This file, and everything downstream of it, is a completely separate view tree from
// GenerateView — nothing here touches the composer/keyboard code (CLAUDE.md frozen section).

import SwiftUI

struct EditorBottomBar: View {
    let state: EditorState

    // MARK: - Default bar (nothing selected)
    let onEdit: () -> Void
    let onAddText: () -> Void
    let onAddAudio: () -> Void
    let onCaptions: () -> Void
    let hasCaptionableMedia: Bool
    let isCaptionsBusy: Bool

    // MARK: - Contextual bar (a selection is active)
    let onSplit: () -> Void
    let onVolume: () -> Void
    let onDone: () -> Void
    let onDeleteSelected: () -> Void
    let onEditText: () -> Void
    let onDuplicateText: () -> Void
    let onEditCaption: () -> Void
    let onDeleteAllCaptions: () -> Void

    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051) // #0A0A0D
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)               // #8C59FF
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)        // #FF5470

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            content
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .background(canvasBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch state.selection {
        case .none:
            defaultBar
        case .clip:
            clipBar
        case .text:
            textBar
        case .audio:
            audioBar
        case .caption:
            captionBar
        }
    }

    // MARK: - Default bar: Edit · Text · Audio · Captions

    private var defaultBar: some View {
        HStack(spacing: 0) {
            tool(icon: "pencil", label: "Edit", action: onEdit)
            tool(icon: "textformat", label: "Text", action: onAddText)
            tool(icon: "music.note", label: "Audio", action: onAddAudio)
            captionsTool
        }
    }

    // Captions is always visible but disabled/grayed until there's captionable media (>=1 video
    // clip — images carry no audio to transcribe).
    private var captionsTool: some View {
        Button(action: onCaptions) {
            VStack(spacing: 4) {
                if isCaptionsBusy {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 19))
                }
                Text("Captions")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .opacity(hasCaptionableMedia ? 1.0 : 0.4)
        }
        .disabled(!hasCaptionableMedia || isCaptionsBusy)
        .accessibilityLabel("Captions")
    }

    // MARK: - Contextual bars

    private var clipBar: some View {
        HStack(spacing: 0) {
            ctxTool(icon: "scissors", label: "Split", action: onSplit)
            ctxTool(
                icon: "speaker.wave.2",
                label: "Volume",
                isDisabled: !selectedClipHasAudio,
                action: onVolume
            )
            ctxTool(icon: "textformat", label: "Text", action: onAddText)
            ctxTool(icon: "trash", label: "Delete", color: destructive, action: onDeleteSelected)
            ctxTool(icon: "checkmark", label: "Done", action: onDone)
        }
    }

    private var textBar: some View {
        HStack(spacing: 0) {
            ctxTool(icon: "scissors", label: "Split", action: onSplit)
            ctxTool(icon: "pencil", label: "Edit", action: onEditText)
            ctxTool(icon: "square.on.square", label: "Duplicate", action: onDuplicateText)
            ctxTool(icon: "trash", label: "Remove", color: destructive, action: onDeleteSelected)
            ctxTool(icon: "checkmark", label: "Done", action: onDone)
        }
    }

    private var audioBar: some View {
        HStack(spacing: 0) {
            ctxTool(icon: "scissors", label: "Split", action: onSplit)
            ctxTool(icon: "trash", label: "Remove", color: destructive, action: onDeleteSelected)
            ctxTool(icon: "checkmark", label: "Done", action: onDone)
        }
    }

    // No Split on captions, per user decision — a caption cue's word timing doesn't split.
    // "Delete" removes just the selected cue (same projectManager.deleteCaptionCue(cueId:) call
    // as the default per-cue path); "Delete All" surfaces the existing D-13 bulk action + its
    // confirmation dialog (CaptionTrackRow) as a second entry point, same as CaptionStyleSheet's
    // "Delete All Captions" row — no new deletion logic anywhere.
    private var captionBar: some View {
        HStack(spacing: 0) {
            ctxTool(icon: "pencil", label: "Edit", action: onEditCaption)
            ctxTool(icon: "trash", label: "Delete", color: destructive, action: onDeleteSelected)
            ctxTool(icon: "trash.fill", label: "Delete All", color: destructive, action: onDeleteAllCaptions)
            ctxTool(icon: "checkmark", label: "Done", action: onDone)
        }
    }

    // MARK: - Shared button styles

    private var selectedClipHasAudio: Bool {
        guard case .clip(let id) = state.selection else { return false }
        return state.project.clips.first(where: { $0.id == id })?.mediaType == "video"
    }

    private func tool(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .accessibilityLabel(label)
    }

    private func ctxTool(
        icon: String,
        label: String,
        color: Color = .white,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .opacity(isDisabled ? 0.35 : 1)
        }
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }
}

/// Compact native bottom sheet for the selected source clip's audio level. The 0–100% range
/// mirrors AVFoundation's linear gain contract and avoids hidden clipping above the source level.
struct ClipVolumeSheet: View {
    @Binding var volume: Double
    let onDone: () -> Void

    private let panelBackground = Color(red: 0.075, green: 0.075, blue: 0.09)
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clip Volume")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onDone) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Done")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)

            Divider().overlay(Color.white.opacity(0.08))

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(volume <= 0.001 ? .secondary : accent)
                        .frame(width: 26)

                    CircularThumbSlider(value: $volume, accent: accent)
                        .accessibilityLabel("Clip volume")
                        .accessibilityValue("\(Int((volume * 100).rounded())) percent")

                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Text("0%")
                    Spacer()
                    Button("Reset to 100%") { volume = 1 }
                        .fontWeight(.semibold)
                    Spacer()
                    Text("100%")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)

            Spacer(minLength: 8)
        }
        .foregroundStyle(.white)
        .background(panelBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// A compact volume slider with a solid circular thumb. The native slider adopts the system's
/// glass capsule treatment on newer iOS releases, which is too visually heavy for this panel.
private struct CircularThumbSlider: View {
    @Binding var value: Double
    let accent: Color

    private let thumbDiameter: CGFloat = 16
    private let trackHeight: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let travel = max(width - thumbDiameter, 0)
            let normalizedValue = min(max(value, 0), 1)
            let fillWidth = travel * normalizedValue
            let thumbX = (thumbDiameter / 2) + fillWidth

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: travel, height: trackHeight)
                    .offset(x: thumbDiameter / 2)

                Capsule()
                    .fill(accent)
                    .frame(width: fillWidth, height: trackHeight)
                    .offset(x: thumbDiameter / 2)

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .position(x: thumbX, y: proxy.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard travel > 0 else { return }
                        let proposed = (gesture.location.x - (thumbDiameter / 2)) / travel
                        let clamped = min(max(proposed, 0), 1)
                        value = (clamped * 100).rounded() / 100
                    }
            )
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(value + 0.01, 1)
            case .decrement:
                value = max(value - 0.01, 0)
            @unknown default:
                break
            }
        }
    }
}
