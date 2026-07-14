// AddAudioSheet.swift
// Fantasia
// Phase 13, Plan 14: the "Add Audio" sheet (SC4) — lets the user add either an uploaded audio
// file (Files document picker) or a bundled preset background-music track to the project's
// multi-clip Audio track. Mirrors MediaPickerSheet.swift's segmented-tab sheet structure
// (Views/Studio/MediaPickerSheet.swift) but is audio-specific, not reused directly.
//
// Calls straight through ProjectManager's `addAudioClip`/`addPresetAudio` (plan 08) — those
// methods already reconcile the whole project via `refreshLoadedProjectURLs()` after a
// successful POST (see their "reconcile via re-fetch (url-less mutation responses)" doc comment),
// so this sheet's `onAdded` closure carries no payload — the CALLER (AudioTrackRow) re-syncs
// `state.project` from `projectManager.loadedProject`, exactly like TimelineTrackView's
// `syncProjectFromManager()` does after a clip mutation.
//
// Preset catalog below is a small, deliberately hardcoded client-side mirror of
// aivideostudio-backend/src/config/presetMusic.ts's `PRESET_MUSIC` registry (ACCEPTED DISCRETION
// TRADEOFF documented in 13-14-PLAN.md — no dedicated GET /api/projects/preset-music listing
// endpoint for this small, rarely-changing 4-track catalog). Keep these two lists in sync by hand
// when presetMusic.ts changes.

import SwiftUI
import UniformTypeIdentifiers

struct AddAudioSheet: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    /// Playhead time (seconds) at the moment the sheet was opened — defaults a newly added
    /// clip's `start_offset_seconds` to wherever the user is currently scrubbed to.
    let currentTime: Double
    /// Fires once a clip has actually been persisted (upload or preset) — no payload, since
    /// ProjectManager's add methods return Void and reconcile via re-fetch (see file header).
    var onAdded: () -> Void

    private enum Tab: String, CaseIterable {
        case upload = "Upload"
        case preset = "Preset Music"
    }

    @State private var activeTab: Tab = .upload
    @State private var showFileImporter = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    private let studioAccent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    private struct PresetTrack: Identifiable {
        let id: String
        let title: String
        let durationSeconds: Int
    }

    // Mirrors presetMusic.ts's PRESET_MUSIC array (ids/titles/durations only — r2Key stays
    // server-side, the client never needs it).
    private let presetTracks: [PresetTrack] = [
        PresetTrack(id: "upbeat-corporate", title: "Upbeat Corporate", durationSeconds: 220),
        PresetTrack(id: "carefree", title: "Carefree", durationSeconds: 205),
        PresetTrack(id: "sneaky-snitch", title: "Sneaky Snitch", durationSeconds: 137),
        PresetTrack(id: "cheery-monday", title: "Cheery Monday", durationSeconds: 80),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Picker("", selection: $activeTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(studioAccent)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                switch activeTab {
                case .upload: uploadTab
                case .preset: presetTab
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(destructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                }
            }
            .background(theme.background.ignoresSafeArea())
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
                    .disabled(isAdding)
                }
            }
            .overlay {
                if isAdding {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView().tint(.white)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio]
        ) { result in
            Task { await handleImportedFile(result) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Add Audio")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Upload a file or pick bundled background music.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
    }

    // MARK: - Upload tab

    private var uploadTab: some View {
        VStack(spacing: 16) {
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(studioAccent)
                    Text("Choose an audio file")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isAdding)

            Text("Supports M4A, MP3, and WAV files from Files or iCloud Drive.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 20)
    }

    // MARK: - Preset Music tab

    private var presetTab: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(presetTracks) { track in
                    presetRow(track)
                }
            }
            .padding(16)
        }
    }

    private func presetRow(_ track: PresetTrack) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(studioAccent)
                .frame(width: 28, height: 28)
                .background(theme.elevatedBackground, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textPrimary)
                Text(formattedDuration(track.durationSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button {
                Task { await addPreset(track) }
            } label: {
                Text("Add")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(studioAccent, in: Capsule())
            }
            .disabled(isAdding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func formattedDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Actions

    /// Files-tab entry point: reads the security-scoped resource's bytes into a plain temp file
    /// (mirrors MediaPickerSheet's `handleImportedFile`) so `APIClient.addAudioClip`'s later
    /// `Data(contentsOf:)` read succeeds after this function's security scope closes, then hands
    /// off to `ProjectManager.addAudioClip`.
    private func handleImportedFile(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access that file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: tmpURL)
        } catch {
            errorMessage = "Couldn't read that file."
            return
        }

        isAdding = true
        errorMessage = nil
        do {
            try await projectManager.addAudioClip(
                fileURL: tmpURL,
                startOffsetSeconds: currentTime,
                trimStartSeconds: 0,
                trimEndSeconds: nil
            )
            isAdding = false
            onAdded()
            dismiss()
        } catch {
            isAdding = false
            errorMessage = "Couldn't add this audio file. Check your connection and try again."
        }
    }

    private func addPreset(_ track: PresetTrack) async {
        isAdding = true
        errorMessage = nil
        do {
            try await projectManager.addPresetAudio(
                presetMusicId: track.id,
                startOffsetSeconds: currentTime,
                trimStartSeconds: 0,
                trimEndSeconds: nil
            )
            isAdding = false
            onAdded()
            dismiss()
        } catch {
            isAdding = false
            errorMessage = "Couldn't add that track. Check your connection and try again."
        }
    }
}
