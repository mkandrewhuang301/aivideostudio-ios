// CaptionStyleSheet.swift
// Fantasia
// Phase 13, Plan 16: the Caption Style sheet (13-UI-SPEC.md Delta 4) — ONE global caption style
// for the whole project (ROADMAP-locked, no per-cue overrides). Opened from a gear icon in
// EditorView's controls row, shown once the project has >=1 caption cue.
//
// Controls, deliberately minimal per the UI-SPEC lock: a font-size stepper, two rows of the SAME
// fixed 6-swatch palette (one for the base text color, one for the active-word highlight color),
// and a top/middle/bottom position segmented picker — never a full color picker, never freeform
// position drag.
//
// Persists via ProjectManager.updateCaptionStyle(_:) (plan 08, CONCRETE — already calls
// APIClient.updateProject(id:captionStyle:) -> PATCH /api/projects/:id { caption_style }, the SAME
// project-level PATCH route plan 03 defines and plan 11 already uses for title/aspectRatio). No
// new backend or APIClient work in this plan. On failure, the changed control reverts to its
// prior value and a lightweight inline error shows (mirrors EditorView's title-rename error
// pattern) — never a blocking alert.
//
// Styled to match AddAudioSheet.swift's precedent (ThemeManager-driven sheet, NOT the Editor
// canvas's forced-dark palette — 13-UI-SPEC.md's forced-dark exception names only the Editor
// screen and Fullscreen Player, not sheets presented from within it).

import SwiftUI

struct CaptionStyleSheet: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    let state: EditorState

    private static let defaultStyle = CaptionStyle(
        fontSize: 22, color: "#FFFFFF", highlightColor: "#8C59FF", position: "bottom"
    )

    private struct Swatch: Identifiable {
        var id: String { hex }
        let name: String
        let hex: String
    }

    // Fixed palette (13-UI-SPEC.md Delta 4) — white / yellow / black / accent-purple / green / red.
    private static let swatches: [Swatch] = [
        Swatch(name: "White", hex: "#FFFFFF"),
        Swatch(name: "Yellow", hex: "#FFD60A"),
        Swatch(name: "Black", hex: "#000000"),
        Swatch(name: "Accent Purple", hex: "#8C59FF"),
        Swatch(name: "Green", hex: "#34C759"),
        Swatch(name: "Red", hex: "#FF3B30"),
    ]

    @State private var fontSize: Double
    @State private var color: String
    @State private var highlightColor: String
    @State private var position: String
    @State private var errorMessage: String?
    @State private var errorClearTask: Task<Void, Never>?

    // Item 2 (Andrew review, 2026-07-17): the bulk "Delete All Captions" action (D-13) already
    // existed but was hidden behind a 0.5s long-press on the caption track row with no visible
    // affordance. Surfacing it here too — same confirmation copy, same
    // `projectManager.deleteAllCaptions()` call CaptionTrackRow already makes, no new deletion
    // logic. Caption-scoped only; never touches text overlays.
    @State private var showDeleteAllConfirm = false
    @State private var isDeletingAll = false

    private let studioAccent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    init(state: EditorState) {
        self.state = state
        let style = state.project.captionStyle ?? Self.defaultStyle
        _fontSize = State(initialValue: style.fontSize)
        _color = State(initialValue: style.color)
        _highlightColor = State(initialValue: style.highlightColor)
        _position = State(initialValue: style.position)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    fontSizeSection
                    colorSection(title: "Text Color", selection: $color) { previous in
                        persist(revert: { color = previous })
                    }
                    colorSection(title: "Active Word Color", selection: $highlightColor) { previous in
                        persist(revert: { highlightColor = previous })
                    }
                    positionSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(destructive)
                    }

                    deleteAllSection
                }
                .padding(16)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Caption Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityLabel("Close")
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
    }

    // MARK: - Delete All Captions (item 2 — visible affordance for the existing D-13 action)

    private var deleteAllSection: some View {
        Button {
            showDeleteAllConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text(isDeletingAll ? "Deleting…" : "Delete All Captions")
                Spacer()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(destructive)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(state.project.captionCues.isEmpty || isDeletingAll)
        .opacity(state.project.captionCues.isEmpty ? 0.4 : 1)
        .padding(.top, 4)
    }

    /// Verbatim reuse of CaptionTrackRow's bulk-delete call (`projectManager.deleteAllCaptions()`)
    /// — no new deletion logic, just a second, visible entry point to the same action. Stays open
    /// on the (now empty) style sheet rather than dismissing, mirroring the track row's behavior
    /// of staying put after the bulk delete.
    private func deleteAllCaptions() async {
        isDeletingAll = true
        defer { isDeletingAll = false }
        do {
            try await projectManager.deleteAllCaptions()
            if let refreshed = projectManager.loadedProject {
                state.project = refreshed
            }
            if case .caption = state.selection { state.select(.none) }
        } catch {
            print("[CaptionStyleSheet] deleteAllCaptions error: \(error)")
            showError("Couldn't delete captions.")
        }
    }

    // MARK: - Font size

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Font Size")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Stepper(value: $fontSize, in: 16...40, step: 2) {
                Text("\(Int(fontSize))pt")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textPrimary)
            }
            .onChange(of: fontSize) { oldValue, _ in
                persist(revert: { fontSize = oldValue })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Color rows (base + active-word highlight — same fixed palette both times)

    private func colorSection(
        title: String,
        selection: Binding<String>,
        onChange: @escaping (_ previous: String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            HStack(spacing: 12) {
                ForEach(Self.swatches) { swatch in
                    swatchButton(swatch, selection: selection, onChange: onChange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func swatchButton(
        _ swatch: Swatch,
        selection: Binding<String>,
        onChange: @escaping (_ previous: String) -> Void
    ) -> some View {
        let isSelected = selection.wrappedValue.caseInsensitiveCompare(swatch.hex) == .orderedSame
        return Button {
            let previous = selection.wrappedValue
            guard previous.caseInsensitiveCompare(swatch.hex) != .orderedSame else { return }
            selection.wrappedValue = swatch.hex
            onChange(previous)
        } label: {
            ZStack {
                Circle()
                    .fill(Color(hexString: swatch.hex) ?? .white)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Circle().stroke(
                            isSelected ? studioAccent : Color.white.opacity(0.25),
                            lineWidth: isSelected ? 3 : 1
                        )
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(checkmarkColor(for: swatch.hex))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
    }

    /// White/yellow swatches need a dark checkmark to stay legible; every other swatch keeps white.
    private func checkmarkColor(for hex: String) -> Color {
        (hex == "#FFFFFF" || hex == "#FFD60A") ? .black : .white
    }

    // MARK: - Position (segmented, not freeform drag — 13-UI-SPEC.md Delta 4)

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Picker("Position", selection: $position) {
                Text("Top").tag("top")
                Text("Middle").tag("middle")
                Text("Bottom").tag("bottom")
            }
            .pickerStyle(.segmented)
            .tint(studioAccent)
            .onChange(of: position) { oldValue, _ in
                persist(revert: { position = oldValue })
            }
        }
    }

    // MARK: - Persistence

    private var currentStyle: CaptionStyle {
        CaptionStyle(fontSize: fontSize, color: color, highlightColor: highlightColor, position: position)
    }

    /// Fires the PATCH for whatever the current @State values now are; `revert` restores just the
    /// one control that changed (each call site captures its own prior value) on failure.
    private func persist(revert: @escaping () -> Void) {
        let style = currentStyle
        Task {
            do {
                try await projectManager.updateCaptionStyle(style)
                state.project.captionStyle = style
            } catch {
                print("[CaptionStyleSheet] updateCaptionStyle error: \(error)")
                revert()
                showError("Couldn't update caption style.")
            }
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            errorMessage = nil
        }
    }
}
