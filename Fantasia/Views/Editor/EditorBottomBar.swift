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
    let onDone: () -> Void
    let onDeleteSelected: () -> Void
    let onEditText: () -> Void
    let onDuplicateText: () -> Void
    let onEditCaption: () -> Void

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
            tool(icon: "pencil.and.outline", label: "Edit", action: onEdit)
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
    private var captionBar: some View {
        HStack(spacing: 0) {
            ctxTool(icon: "pencil", label: "Edit", action: onEditCaption)
            ctxTool(icon: "trash", label: "Delete", color: destructive, action: onDeleteSelected)
            ctxTool(icon: "checkmark", label: "Done", action: onDone)
        }
    }

    // MARK: - Shared button styles

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

    private func ctxTool(icon: String, label: String, color: Color = .white, action: @escaping () -> Void) -> some View {
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
        }
        .accessibilityLabel(label)
    }
}
