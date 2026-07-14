// EditorView.swift
// Fantasia
// Phase 13, Plan 11: the Editor shell (top bar, preview stage, controls row, timeline mount
// point) hosting the locked sketch's layout (.planning/sketches/001-video-editor-v0/index.html)
// + 13-UI-SPEC.md's Editor deltas (project-title rename, forced-dark canvas). This is a
// SEPARATE screen tree from GenerateView — nothing here touches the composer/keyboard code
// (CLAUDE.md frozen section).
//
// Forced-dark exception (13-UI-SPEC.md): this canvas is ALWAYS dark, regardless of the app's
// light/dark ThemeManager setting — matches every professional video editor convention and the
// locked sketch, which has no light variant.
//
// Plan 12 replaced plan 11's placeholder mount view below with the real TimelineTrackView
// (Fantasia/Views/Editor/TimelineTrackView.swift) — filmstrip clips, fixed-center playhead,
// background scrub, and the stacked Text/Audio/Caption track mount points.

import SwiftUI
import AVFoundation

struct EditorView: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    @State private var state: EditorState
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?

    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleError: String?
    @State private var titleErrorClearTask: Task<Void, Never>?

    @State private var isExporting = false

    // Forced-dark palette (13-UI-SPEC.md Color contract) — NOT theme.background/theme.surface.
    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051)   // #0A0A0D
    private let previewStageBackground = Color(red: 0.047, green: 0.047, blue: 0.067) // #0C0C11
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)                 // #8C59FF
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)          // #FF5470

    private static let aspectOptions: [String] = ["9:16", "4:5", "1:1", "16:9"]

    init(project: EditProject) {
        _state = State(initialValue: EditorState(project: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            previewStage
            controlsRow
            TimelineTrackView(state: state)
        }
        .background(canvasBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { setUpPlayer() }
        .onDisappear { tearDownPlayer() }
        .onChange(of: state.isPlaying) { _, isPlaying in
            if isPlaying { player?.play() } else { player?.pause() }
        }
    }

    // MARK: - Top bar: close ✕ / tap-to-rename title (Delta 1) / Export

    private var topBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close editor")

                Spacer(minLength: 8)

                titleView

                Spacer(minLength: 8)

                exportButton
            }

            if let titleError {
                Text(titleError)
                    .font(.system(size: 11))
                    .foregroundStyle(destructive)
                    .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Untitled Project", text: $titleDraft)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .frame(maxWidth: 200)
                .onSubmit { commitTitleRename() }
        } else {
            Button {
                titleDraft = state.project.title ?? ""
                isEditingTitle = true
            } label: {
                HStack(spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var displayTitle: String {
        let title = state.project.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled Project" : title
    }

    private var exportButton: some View {
        Button {
            // Plan 14 wires the real export dispatch (D-10/D-12) — placeholder no-op stub.
        } label: {
            Group {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView().tint(.white)
                        Text("Exporting…")
                    }
                } else {
                    Text("Export")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(accent, in: Capsule())
        }
        .disabled(isExporting)
    }

    private func commitTitleRename() {
        isEditingTitle = false
        let newTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousTitle = state.project.title
        guard newTitle != (previousTitle ?? "") else { return }

        state.project.title = newTitle.isEmpty ? nil : newTitle // optimistic local update
        Task {
            do {
                try await projectManager.updateProjectTitle(newTitle)
            } catch {
                print("[EditorView] updateProjectTitle error: \(error)")
                state.project.title = previousTitle // revert — no blocking alert
                showTitleError("Couldn't rename project.")
            }
        }
    }

    private func showTitleError(_ message: String) {
        titleError = message
        titleErrorClearTask?.cancel()
        titleErrorClearTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            titleError = nil
        }
    }

    // MARK: - Preview stage: AVPlayer-backed inline surface, letterboxed to state.aspectRatio

    private var previewStage: some View {
        GeometryReader { geo in
            let ratio = Self.aspectFraction(state.aspectRatio)
            let maxHeight: CGFloat = 340
            let availWidth = geo.size.width - 24
            let size: CGSize = {
                if maxHeight * ratio <= availWidth {
                    return CGSize(width: maxHeight * ratio, height: maxHeight)
                } else {
                    return CGSize(width: availWidth, height: availWidth / ratio)
                }
            }()

            ZStack {
                if let player {
                    FillingVideoPlayerView(player: player, videoGravity: .resizeAspect)
                } else {
                    Color.black
                    Image(systemName: "film")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                // Plan 13: on-video Text overlays (SC3), sized/clipped to the same letterboxed
                // canvas frame the AVPlayer surface renders in so overlay coordinates line up 1:1.
                TextOverlayCanvasView(state: state)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(height: 340)
        .frame(maxWidth: .infinity)
        .background(previewStageBackground)
    }

    private static func aspectFraction(_ ratio: String) -> CGFloat {
        switch ratio {
        case "9:16": return 9.0 / 16.0
        case "4:5": return 4.0 / 5.0
        case "1:1": return 1.0
        case "16:9": return 16.0 / 9.0
        default: return 9.0 / 16.0
        }
    }

    // MARK: - Controls row: fullscreen + aspect-ratio toggle + undo/redo (sketch's controls-row)

    private var controlsRow: some View {
        HStack(spacing: 4) {
            Button {
                // Plan 14 wires the real fullscreen player (FullscreenEditorPlayerView).
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Fullscreen")

            Button {
                cycleAspectRatio()
            } label: {
                Text(state.aspectRatio)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Aspect ratio")

            Spacer()

            Button {
                // Plan 12 wires real undo (timeline/edit history).
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Undo")

            Button {
                // Plan 12 wires real redo (timeline/edit history).
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Redo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func cycleAspectRatio() {
        let options = Self.aspectOptions
        let currentIndex = options.firstIndex(of: state.aspectRatio) ?? 0
        let nextRatio = options[(currentIndex + 1) % options.count]
        let previousRatio = state.aspectRatio

        state.aspectRatio = nextRatio // immediate local preview feedback
        Task {
            do {
                try await projectManager.updateAspectRatio(nextRatio)
                state.project.aspectRatio = nextRatio
            } catch {
                print("[EditorView] updateAspectRatio error: \(error)")
                state.aspectRatio = previousRatio // revert on 400/failure
            }
        }
    }

    // MARK: - Player plumbing (analog: FullScreenVideoPlayerView's AVPlayer setup — this is a
    // smaller inline preview, no pan-to-dismiss/zoom). Only the first clip is previewed here;
    // multi-clip playback stitching is the timeline's job (plan 12).

    private func setUpPlayer() {
        guard player == nil,
              let urlString = state.project.clips.first?.url,
              let url = URL(string: urlString) else { return }
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        player = avPlayer

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                state.currentTime = time.seconds
            }
        }
    }

    private func tearDownPlayer() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        titleErrorClearTask?.cancel()
    }
}
