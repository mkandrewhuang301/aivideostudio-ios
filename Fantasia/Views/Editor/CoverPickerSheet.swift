// CoverPickerSheet.swift
// Fantasia
// Plan 13-21 F17: scrub the WHOLE project timeline, pick a frame, set it as the project's cover
// (thumbnail). Reuses EditorCompositionBuilder (F1's shared multi-clip AVMutableComposition
// builder) + AVAssetImageGenerator for both the frame strip and the large scrubbed preview — the
// exact same "build once, generate frames against it" pattern ClipPillView's filmstrip already
// uses, just against the WHOLE-PROJECT composition instead of one clip's own asset.
//
// Picked global (composition) time resolves to a (clipId, localSeconds) pair via the SAME
// composition's clip ranges: for a video clip, localSeconds is the clip's OWN SOURCE-FILE time
// (trimStartSeconds + offset into that clip's segment) — extractVideoFrame (backend) operates on
// the raw downloaded clip file, not composition-relative time. Image clips have no meaningful
// "frame position" — they resolve to that clip's id with at_seconds: 0 (backend CopyObjects the
// clip's own r2_key regardless of the value).

import SwiftUI
import AVFoundation

struct CoverPickerSheet: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    let project: EditProject
    /// Fires once the cover has actually been persisted — the caller (EditorView) reconciles
    /// `state.project` from `projectManager.loadedProject` and shows the "Cover updated" toast.
    var onCoverSet: () -> Void

    @State private var composition: AVMutableComposition?
    // 13-23 J4: applied to every AVAssetImageGenerator below so picked/strip frames render with
    // the same per-clip aspect-fit the live preview and export use — never stretched.
    @State private var videoComposition: AVMutableVideoComposition?
    @State private var ranges: [EditorCompositionBuilder.ClipRange] = []
    @State private var totalDuration: Double = 0

    @State private var scrubbedTime: Double = 0
    @State private var previewImage: UIImage?
    @State private var stripFrames: [UIImage?] = []
    @State private var isLoadingComposition = true
    @State private var isSettingCover = false
    @State private var errorMessage: String?

    @State private var previewGenerationTask: Task<Void, Never>?

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)      // #8C59FF
    private let stripCount = 10

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isLoadingComposition {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                } else if totalDuration <= 0 {
                    Spacer()
                    Text("This project has no playable clips yet.")
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                } else {
                    largePreview
                    frameStrip
                    Slider(
                        value: Binding(
                            get: { scrubbedTime },
                            set: { newValue in
                                scrubbedTime = newValue
                                schedulePreviewRegeneration()
                            }
                        ),
                        in: 0...totalDuration
                    )
                    .tint(accent)
                    .padding(.horizontal, 20)

                    Text(TimelineTrackView.formatTime(scrubbedTime))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 1.0, green: 0.329, blue: 0.439))
                    }

                    Button {
                        Task { await commitCover() }
                    } label: {
                        HStack(spacing: 8) {
                            if isSettingCover { ProgressView().tint(.white) }
                            Text(isSettingCover ? "Setting cover…" : "Set cover")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(isSettingCover)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .background(Color(red: 0.039, green: 0.039, blue: 0.051).ignoresSafeArea())
            .navigationTitle("Choose Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.078, green: 0.078, blue: 0.098), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadComposition() }
    }

    // MARK: - Composition + preview generation

    private func loadComposition() async {
        isLoadingComposition = true
        guard let (built, builtVideoComposition, builtRanges) = await EditorCompositionBuilder.build(
            clips: project.clips, aspectRatio: project.aspectRatio
        ) else {
            isLoadingComposition = false
            return
        }
        composition = built
        videoComposition = builtVideoComposition
        ranges = builtRanges
        totalDuration = builtRanges.last?.end ?? 0
        isLoadingComposition = false
        await generatePreview(at: scrubbedTime)
        await generateStrip()
    }

    private func schedulePreviewRegeneration() {
        previewGenerationTask?.cancel()
        let target = scrubbedTime
        previewGenerationTask = Task {
            try? await Task.sleep(for: .milliseconds(120)) // debounce continuous slider drags
            guard !Task.isCancelled else { return }
            await generatePreview(at: target)
        }
    }

    private func generatePreview(at time: Double) async {
        guard let composition else { return }
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = videoComposition // J4: aspect-fit frames (nil = no video clips)
        generator.maximumSize = CGSize(width: 480, height: 480)
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: cmTime) else { return }
        if Task.isCancelled { return }
        previewImage = UIImage(cgImage: cgImage)
    }

    private func generateStrip() async {
        guard let composition, totalDuration > 0 else { return }
        stripFrames = Array(repeating: nil, count: stripCount)
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = videoComposition // J4: aspect-fit frames (nil = no video clips)
        generator.maximumSize = CGSize(width: 160, height: 200)
        for index in 0..<stripCount {
            if Task.isCancelled { return }
            let t = totalDuration * Double(index) / Double(max(stripCount - 1, 1))
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: cmTime) else { continue }
            if Task.isCancelled { return }
            stripFrames[index] = UIImage(cgImage: cgImage)
        }
    }

    // MARK: - Commit

    private func commitCover() async {
        guard let target = resolveCoverTarget(scrubbedTime: scrubbedTime) else {
            errorMessage = "Couldn't resolve a clip at this position."
            return
        }
        isSettingCover = true
        errorMessage = nil
        do {
            try await projectManager.setCover(clipId: target.clipId, atSeconds: target.atSeconds)
            isSettingCover = false
            onCoverSet()
            dismiss()
        } catch {
            print("[CoverPickerSheet] setCover error: \(error)")
            isSettingCover = false
            errorMessage = "Couldn't set cover — try again."
        }
    }

    /// Resolves the picked GLOBAL (composition) time into a (clipId, localSeconds) pair. Video
    /// clips: localSeconds is the clip's OWN SOURCE-FILE time (trimStartSeconds + offset into its
    /// segment) — extractVideoFrame (backend) operates on the raw clip file, not composition-
    /// relative time. Image clips: at_seconds is irrelevant server-side (CopyObject, not a frame
    /// extraction), always 0.
    private func resolveCoverTarget(scrubbedTime: Double) -> (clipId: String, atSeconds: Double)? {
        let range = ranges.first(where: { scrubbedTime >= $0.start && scrubbedTime < $0.end }) ?? ranges.last
        guard let range, let clip = project.clips.first(where: { $0.id == range.clipId }) else { return nil }
        if clip.mediaType == "image" {
            return (clip.id, 0)
        }
        let localSourceSeconds = clip.trimStartSeconds + (scrubbedTime - range.start)
        return (clip.id, max(0, localSourceSeconds))
    }

    // MARK: - Subviews

    private var largePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black)
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(height: 260)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var frameStrip: some View {
        HStack(spacing: 2) {
            ForEach(0..<stripFrames.count, id: \.self) { index in
                Group {
                    if let frame = stripFrames[index] {
                        Image(uiImage: frame).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(height: 52)
                .clipped()
                .onTapGesture {
                    scrubbedTime = totalDuration * Double(index) / Double(max(stripCount - 1, 1))
                    schedulePreviewRegeneration()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
    }
}
