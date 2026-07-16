// CoverPickerSheet.swift
// Fantasia
// Plan 13-24 K6: full-screen CapCut-style cover editor — gapless frame strip, ephemeral text/
// photo overlays composited client-side, multipart JPEG upload (K-B1). Reuses
// EditorCompositionBuilder + AVAssetImageGenerator for strip/preview frames.
//
// Cover overlays are EPHEMERAL: reopening the editor starts fresh from the frame strip; the
// current cover thumbnail is not decomposed back into editable overlays.

import SwiftUI
import AVFoundation
import PhotosUI

struct CoverPickerSheet: View {
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.dismiss) private var dismiss

    let project: EditProject
    /// Fires once the cover has actually been persisted — the caller reconciles project state and
    /// shows the "Cover updated" toast.
    var onCoverSet: () -> Void

    @State private var composition: AVMutableComposition?
    @State private var videoComposition: AVMutableVideoComposition?
    @State private var ranges: [EditorCompositionBuilder.ClipRange] = []
    @State private var sourceGenerators: [String: AVAssetImageGenerator] = [:]
    @State private var totalDuration: Double = 0

    @State private var scrubbedTime: Double = 0
    @State private var previewImage: UIImage?
    @State private var stripFrames: [UIImage?] = []
    @State private var stripCellCount = 0
    @State private var isLoadingComposition = true
    @State private var mediaLoadFailed = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    // 13-26 M5: latest-wins preview generation (replaces the cancel-storm debounce — see
    // schedulePreviewRegeneration's doc comment). `pendingTime` is the newest scrubbed time not
    // yet rendered; `isGeneratingPreview` is true while the drain loop runs.
    @State private var isGeneratingPreview = false
    @State private var pendingTime: Double?
    @State private var stripDragStartTime: Double?

    // Ephemeral overlay state — never persisted; see file header.
    @State private var coverOverlays: [CoverOverlay] = []
    @State private var selectedOverlayId: UUID?
    @State private var selectedTab: CoverEditorTab = .frame
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var canvasPixelSize = CGSize(width: 1080, height: 1920)
    @State private var canvasAspect: CGFloat = 9.0 / 16.0

    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051) // #0A0A0D
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)               // #8C59FF
    private let stripCellWidth: CGFloat = 46
    private let stripCellHeight: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if isLoadingComposition {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            } else if totalDuration <= 0 {
                Spacer()
                Text("This project has no playable clips yet.")
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            } else if mediaLoadFailed {
                Spacer()
                VStack(spacing: 14) {
                    Text("Couldn't load media")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Button("Retry") {
                        Task { await loadComposition() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(accent, in: Capsule())
                }
                Spacer()
            } else {
                previewSection
                    .layoutPriority(1)

                frameStripSection

                Text("Slide to select")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.top, 10)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1.0, green: 0.329, blue: 0.439))
                        .padding(.top, 6)
                }

                bottomTabBar
            }
        }
        .background(canvasBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await loadComposition() }
        .onChange(of: selectedPhotoItem) { _, item in
            Task { await handlePhotoSelection(item) }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .frame { selectedOverlayId = nil }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")

            Spacer()

            Button {
                Task { await saveCover() }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().tint(.white).scaleEffect(0.85) }
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(accent, in: Capsule())
            }
            .disabled(isSaving || previewImage == nil)
            .accessibilityLabel("Save cover")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Preview + overlays

    private var previewSection: some View {
        GeometryReader { geo in
            let fitted = aspectFitRect(container: geo.size, contentAspect: canvasAspect)
            ZStack {
                Color.black
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)
                } else {
                    ProgressView().tint(.white)
                }

                CoverOverlayCanvas(
                    overlays: coverOverlays,
                    selectedOverlayId: selectedOverlayId,
                    canvasSize: fitted.size,
                    gestureOrigin: CGPoint(x: fitted.minX, y: fitted.minY),
                    showsControls: true,
                    onSelect: { selectedOverlayId = $0 },
                    onUpdate: updateOverlay,
                    onDelete: deleteOverlay,
                    onDuplicateText: duplicateTextOverlay
                )
                .frame(width: fitted.width, height: fitted.height)
                .position(x: fitted.midX, y: fitted.midY)
            }
            .coordinateSpace(name: "coverCanvas")
            .contentShape(Rectangle())
            .onTapGesture { selectedOverlayId = nil }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Frame strip

    private var frameStripSection: some View {
        GeometryReader { geo in
            let viewportWidth = geo.size.width
            let px = stripPixelsPerSecond(viewportWidth: viewportWidth)
            let count = max(1, Int(ceil(totalDuration * px / stripCellWidth)))
            let stripOffset = viewportWidth / 2 - scrubbedTime * px

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        stripCellView(index: index, stripPx: px)
                            .frame(width: stripCellWidth, height: stripCellHeight)
                    }
                }
                .offset(x: stripOffset)

                Rectangle()
                    .fill(Color.white)
                    .frame(width: 1.5, height: stripCellHeight + 8)
                    .position(x: viewportWidth / 2, y: stripCellHeight / 2)
                    .allowsHitTesting(false)
            }
            .frame(height: stripCellHeight)
            .clipped()
            .contentShape(Rectangle())
            .gesture(stripDragGesture(stripPx: px))
            .onAppear {
                if stripCellCount != count {
                    stripCellCount = count
                    Task { await generateStrip(cellCount: count, stripPx: px) }
                }
            }
            .onChange(of: count) { _, newCount in
                stripCellCount = newCount
                Task { await generateStrip(cellCount: newCount, stripPx: px) }
            }
        }
        .frame(height: stripCellHeight)
    }

    private func stripCellView(index: Int, stripPx: CGFloat) -> some View {
        Group {
            if index < stripFrames.count, let frame = stripFrames[index] {
                Image(uiImage: frame)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(width: stripCellWidth, height: stripCellHeight)
        .clipped()
    }

    private func stripDragGesture(stripPx: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if stripDragStartTime == nil { stripDragStartTime = scrubbedTime }
                let start = stripDragStartTime ?? scrubbedTime
                let next = start - value.translation.width / stripPx
                scrubbedTime = min(max(0, next), totalDuration)
                schedulePreviewRegeneration()
            }
            .onEnded { _ in
                stripDragStartTime = nil
                // 13-26 M5: one PRECISE (zero-tolerance) render at the final resting time — the
                // during-drag loop uses fast keyframe-near frames, this lands the exact frame.
                let finalTime = scrubbedTime
                Task { await generatePreview(at: finalTime) }
            }
    }

    // MARK: - Bottom tabs

    private var bottomTabBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            HStack(spacing: 0) {
                // 13-26 M6.1: "Frame" → "Cover" — this tab picks the COVER frame; the old label
                // read as a generic frame tool.
                coverTab(icon: "film", label: "Cover", tab: .frame) {
                    selectedTab = .frame
                    selectedOverlayId = nil
                }
                coverTab(icon: "textformat", label: "Text", tab: .text) {
                    selectedTab = .text
                    addTextOverlay()
                }
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    coverTabLabel(icon: "photo", label: "Add photo", isSelected: selectedTab == .addPhoto)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(canvasBackground)
    }

    private func coverTab(icon: String, label: String, tab: CoverEditorTab, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            coverTabLabel(icon: icon, label: label, isSelected: selectedTab == tab)
        }
        .accessibilityLabel(label)
    }

    private func coverTabLabel(icon: String, label: String, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 19))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(isSelected ? accent : .white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Composition + preview generation

    private func loadComposition() async {
        isLoadingComposition = true
        mediaLoadFailed = false
        previewImage = nil
        stripFrames = []
        stripCellCount = 0
        sourceGenerators.removeAll()
        guard let (built, builtVideoComposition, builtRanges, _) = await EditorCompositionBuilder.build(
            clips: project.clips, aspectRatio: project.aspectRatio
        ) else {
            isLoadingComposition = false
            return
        }
        composition = built
        videoComposition = builtVideoComposition
        ranges = builtRanges
        totalDuration = builtRanges.last?.end ?? 0

        if let renderSize = builtVideoComposition?.renderSize, renderSize.width > 0, renderSize.height > 0 {
            canvasPixelSize = capLongEdge(renderSize, maxEdge: 1440)
            canvasAspect = renderSize.width / renderSize.height
        } else {
            canvasAspect = aspectFraction(for: project.aspectRatio)
            canvasPixelSize = capLongEdge(
                CGSize(width: 1080, height: 1080 / canvasAspect),
                maxEdge: 1440
            )
        }

        await generatePreview(at: scrubbedTime)
        isLoadingComposition = false
    }

    /// 13-26 M5: latest-wins throttling. The old cancel+120ms-sleep debounce cancelled the pending
    /// task on EVERY drag change — during continuous strip movement no render ever survived to
    /// completion, so the big preview sat frozen until the finger stopped (the reported "strip
    /// slides but preview never updates" bug). Now: every change just records the newest time;
    /// exactly one drain loop runs at a time, rendering FAST (½s-tolerance, keyframe-near) frames
    /// back-to-back, always picking up the most recent pending time next — the preview visibly
    /// tracks the drag at whatever rate the device can decode. The strip gesture's .onEnded fires
    /// one final PRECISE render at the resting time.
    private func schedulePreviewRegeneration() {
        pendingTime = scrubbedTime
        guard !isGeneratingPreview else { return }
        isGeneratingPreview = true
        Task {
            while let t = pendingTime {
                pendingTime = nil
                await generateFastPreview(at: t)
            }
            isGeneratingPreview = false
        }
    }

    /// FAST during-drag frame: ½-second tolerance snaps to a cheap nearby keyframe.
    private func generateFastPreview(at time: Double) async {
        guard let active = activeClip(at: time),
              let image = await sourceImage(
                for: active.clip,
                localTime: active.localTime,
                tolerance: CMTime(value: 1, timescale: 2)
              ) else { return }
        previewImage = image
    }

    /// PRECISE frame (zero tolerance) — initial load, drag-end landing, and the frame Save uses.
    private func generatePreview(at time: Double) async {
        guard let active = activeClip(at: time),
              let image = await sourceImage(
                for: active.clip,
                localTime: active.localTime,
                tolerance: .zero
              ) else { return }
        if Task.isCancelled { return }
        canvasPixelSize = capLongEdge(
            CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            ),
            maxEdge: 1440
        )
        canvasAspect = canvasPixelSize.width / canvasPixelSize.height
        previewImage = image
    }

    /// Resolves the project-timeline playhead to a source clip and that asset's local timeline.
    /// Ranges are half-open; the project endpoint is assigned to the final clip so the rightmost
    /// strip position still produces a cover frame.
    private func activeClip(at time: Double) -> (clip: ProjectClip, localTime: Double)? {
        guard !ranges.isEmpty else { return nil }
        let clampedTime = min(max(0, time), totalDuration)

        let activeRange: EditorCompositionBuilder.ClipRange?
        if let last = ranges.last, clampedTime >= last.end {
            activeRange = last
        } else {
            activeRange = ranges.first { clampedTime >= $0.start && clampedTime < $0.end }
        }

        guard let activeRange,
              let clip = project.clips.first(where: { $0.id == activeRange.clipId }) else { return nil }
        return (clip, clip.trimStartSeconds + (clampedTime - activeRange.start))
    }

    /// Produces an uncomposited source frame. The project-canvas AVVideoComposition is
    /// intentionally absent here so aspect-fit letterbox bars can never enter the saved cover.
    private func sourceImage(
        for clip: ProjectClip,
        localTime: Double,
        tolerance: CMTime
    ) async -> UIImage? {
        if clip.mediaType == "image" {
            guard let url = await sourceURL(for: clip) else { return nil }
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            return data.flatMap(UIImage.init(data:))
        }

        guard let generator = await sourceGenerator(for: clip) else { return nil }
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let cmTime = CMTime(seconds: localTime, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: cmTime) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func sourceGenerator(for clip: ProjectClip) async -> AVAssetImageGenerator? {
        if let cached = sourceGenerators[clip.id] { return cached }
        guard let url = await sourceURL(for: clip) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        sourceGenerators[clip.id] = generator
        return generator
    }

    private func sourceURL(for clip: ProjectClip) async -> URL? {
        guard let urlString = clip.url, let remoteURL = URL(string: urlString) else { return nil }
        return await ClipFileCache.shared.localURL(clipId: clip.id, remoteURL: remoteURL)
    }

    private func generateStrip(cellCount: Int, stripPx: CGFloat) async {
        guard let composition, totalDuration > 0 else { return }
        stripFrames = Array(repeating: nil, count: cellCount)
        let generator = AVAssetImageGenerator(asset: composition)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = videoComposition
        generator.maximumSize = CGSize(width: 160, height: 200)
        let stripTolerance = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceBefore = stripTolerance
        generator.requestedTimeToleranceAfter = stripTolerance

        for index in 0..<cellCount {
            if Task.isCancelled { return }
            let cellCenter = (Double(index) + 0.5) * Double(stripCellWidth)
            let t = min(totalDuration, max(0, cellCenter / Double(stripPx)))
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: cmTime) else { continue }
            if Task.isCancelled { return }
            if index < stripFrames.count {
                stripFrames[index] = UIImage(cgImage: cgImage)
            }
        }

        if !ranges.isEmpty, stripFrames.allSatisfy({ $0 == nil }), previewImage == nil {
            mediaLoadFailed = true
        }
    }

    // MARK: - Overlays

    private func addTextOverlay() {
        let overlay = CoverOverlay.text(
            id: UUID(),
            text: "Text",
            xNorm: 0.5,
            yNorm: 0.5,
            scale: 1.0,
            rotation: 0
        )
        coverOverlays.append(overlay)
        selectedOverlayId = overlay.id
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        selectedTab = .addPhoto
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            selectedPhotoItem = nil
            return
        }
        let overlay = CoverOverlay.photo(
            id: UUID(),
            image: image,
            xNorm: 0.5,
            yNorm: 0.5,
            scale: 1.0,
            rotation: 0,
            mirrored: false
        )
        coverOverlays.append(overlay)
        selectedOverlayId = overlay.id
        selectedPhotoItem = nil
    }

    private func updateOverlay(_ overlay: CoverOverlay) {
        guard let index = coverOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        coverOverlays[index] = overlay
    }

    private func deleteOverlay(id: UUID) {
        coverOverlays.removeAll { $0.id == id }
        if selectedOverlayId == id { selectedOverlayId = nil }
    }

    private func duplicateTextOverlay(_ overlay: CoverOverlay) {
        guard case .text(let text, let x, let y, let scale, let rotation) = overlay.kind else { return }
        let duplicate = CoverOverlay.text(
            id: UUID(),
            text: text,
            xNorm: min(0.94, x + 0.04),
            yNorm: min(0.94, y + 0.04),
            scale: scale,
            rotation: rotation
        )
        coverOverlays.append(duplicate)
        selectedOverlayId = duplicate.id
    }

    // MARK: - Save

    private func saveCover() async {
        guard let previewImage else {
            errorMessage = "No frame selected."
            return
        }
        isSaving = true
        errorMessage = nil
        guard let jpeg = renderCompositeJPEG(frameImage: previewImage) else {
            isSaving = false
            errorMessage = "Couldn't render cover — try again."
            return
        }
        do {
            try await projectManager.setCoverImage(data: jpeg)
            isSaving = false
            onCoverSet()
            dismiss()
        } catch {
            print("[CoverPickerSheet] setCoverImage error: \(error)")
            isSaving = false
            errorMessage = "Couldn't save cover — try again."
        }
    }

    @MainActor
    private func renderCompositeJPEG(frameImage: UIImage) -> Data? {
        let view = CoverCompositeView(
            frameImage: frameImage,
            canvasSize: canvasPixelSize,
            overlays: coverOverlays
        )
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(canvasPixelSize)
        renderer.scale = 1.0
        guard let uiImage = renderer.uiImage else { return nil }
        return uiImage.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Helpers

    private func stripPixelsPerSecond(viewportWidth: CGFloat) -> CGFloat {
        guard totalDuration > 0 else { return 44 }
        return max(44, viewportWidth / CGFloat(totalDuration))
    }

    private func aspectFitRect(container: CGSize, contentAspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, contentAspect > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        if containerAspect > contentAspect {
            let height = container.height
            let width = height * contentAspect
            return CGRect(x: (container.width - width) / 2, y: 0, width: width, height: height)
        } else {
            let width = container.width
            let height = width / contentAspect
            return CGRect(x: 0, y: (container.height - height) / 2, width: width, height: height)
        }
    }

    private func capLongEdge(_ size: CGSize, maxEdge: CGFloat) -> CGSize {
        let long = max(size.width, size.height)
        guard long > 0 else { return size }
        let scale = min(1, maxEdge / long)
        return CGSize(
            width: evenFloor(size.width * scale),
            height: evenFloor(size.height * scale)
        )
    }

    private func evenFloor(_ value: CGFloat) -> CGFloat {
        let floored = max(2, Int(value.rounded(.down)))
        return CGFloat(floored.isMultiple(of: 2) ? floored : floored - 1)
    }

    private func aspectFraction(for ratio: String) -> CGFloat {
        switch ratio {
        case "9:16": return 9.0 / 16.0
        case "4:5": return 4.0 / 5.0
        case "1:1": return 1.0
        case "16:9": return 16.0 / 9.0
        default:
            let sorted = project.clips.sorted { $0.sortOrder < $1.sortOrder }
            if let first = sorted.first, let w = first.width, let h = first.height, h > 0 {
                return CGFloat(w) / CGFloat(h)
            }
            return 9.0 / 16.0
        }
    }
}

// MARK: - Tabs + overlay model

private enum CoverEditorTab {
    case frame, text, addPhoto
}

private struct CoverOverlay: Identifiable {
    let id: UUID
    enum Kind {
        case text(String, xNorm: Double, yNorm: Double, scale: Double, rotation: Double)
        case photo(UIImage, xNorm: Double, yNorm: Double, scale: Double, rotation: Double, mirrored: Bool)
    }
    var kind: Kind

    static func text(
        id: UUID, text: String, xNorm: Double, yNorm: Double, scale: Double, rotation: Double
    ) -> CoverOverlay {
        CoverOverlay(id: id, kind: .text(text, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: rotation))
    }

    static func photo(
        id: UUID, image: UIImage, xNorm: Double, yNorm: Double,
        scale: Double, rotation: Double, mirrored: Bool
    ) -> CoverOverlay {
        CoverOverlay(id: id, kind: .photo(image, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: rotation, mirrored: mirrored))
    }
}

// MARK: - Interactive overlay canvas

private struct CoverOverlayCanvas: View {
    let overlays: [CoverOverlay]
    let selectedOverlayId: UUID?
    let canvasSize: CGSize
    /// Offset of this canvas within the named `coverCanvas` coordinate space (`.zero` for export).
    let gestureOrigin: CGPoint
    let showsControls: Bool
    let onSelect: (UUID) -> Void
    let onUpdate: (CoverOverlay) -> Void
    let onDelete: (UUID) -> Void
    let onDuplicateText: (CoverOverlay) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(overlays) { overlay in
                switch overlay.kind {
                case .text(let text, let xNorm, let yNorm, let scale, let rotation):
                    CoverTextOverlayItemView(
                        text: text,
                        xNorm: xNorm,
                        yNorm: yNorm,
                        scale: scale,
                        rotation: rotation,
                        canvasSize: canvasSize,
                        gestureOrigin: gestureOrigin,
                        isSelected: selectedOverlayId == overlay.id,
                        showsControls: showsControls,
                        onSelect: { onSelect(overlay.id) },
                        onMove: { x, y in
                            var updated = overlay
                            updated.kind = .text(text, xNorm: x, yNorm: y, scale: scale, rotation: rotation)
                            onUpdate(updated)
                        },
                        onResize: { newScale in
                            var updated = overlay
                            updated.kind = .text(text, xNorm: xNorm, yNorm: yNorm, scale: newScale, rotation: rotation)
                            onUpdate(updated)
                        },
                        onRotate: { newRotation in
                            var updated = overlay
                            updated.kind = .text(text, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: newRotation)
                            onUpdate(updated)
                        },
                        onEditCommit: { newText in
                            var updated = overlay
                            updated.kind = .text(newText, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: rotation)
                            onUpdate(updated)
                        },
                        onDelete: { onDelete(overlay.id) },
                        onDuplicate: { onDuplicateText(overlay) }
                    )

                case .photo(let image, let xNorm, let yNorm, let scale, let rotation, let mirrored):
                    CoverPhotoOverlayItemView(
                        image: image,
                        xNorm: xNorm,
                        yNorm: yNorm,
                        scale: scale,
                        rotation: rotation,
                        mirrored: mirrored,
                        canvasSize: canvasSize,
                        gestureOrigin: gestureOrigin,
                        isSelected: selectedOverlayId == overlay.id,
                        showsControls: showsControls,
                        onSelect: { onSelect(overlay.id) },
                        onMove: { x, y in
                            var updated = overlay
                            updated.kind = .photo(image, xNorm: x, yNorm: y, scale: scale, rotation: rotation, mirrored: mirrored)
                            onUpdate(updated)
                        },
                        onResize: { newScale in
                            var updated = overlay
                            updated.kind = .photo(image, xNorm: xNorm, yNorm: yNorm, scale: newScale, rotation: rotation, mirrored: mirrored)
                            onUpdate(updated)
                        },
                        onRotate: { newRotation in
                            var updated = overlay
                            updated.kind = .photo(image, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: newRotation, mirrored: mirrored)
                            onUpdate(updated)
                        },
                        onMirror: {
                            var updated = overlay
                            updated.kind = .photo(image, xNorm: xNorm, yNorm: yNorm, scale: scale, rotation: rotation, mirrored: !mirrored)
                            onUpdate(updated)
                        },
                        onDelete: { onDelete(overlay.id) }
                    )
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .allowsHitTesting(showsControls)
    }
}

// MARK: - Static composite (ImageRenderer export)

private struct CoverCompositeView: View {
    let frameImage: UIImage
    let canvasSize: CGSize
    let overlays: [CoverOverlay]

    var body: some View {
        ZStack {
            Color.black
            Image(uiImage: frameImage)
                .resizable()
                .scaledToFit()
                .frame(width: canvasSize.width, height: canvasSize.height)

            CoverOverlayCanvas(
                overlays: overlays,
                selectedOverlayId: nil,
                canvasSize: canvasSize,
                gestureOrigin: .zero,
                showsControls: false,
                onSelect: { _ in },
                onUpdate: { _ in },
                onDelete: { _ in },
                onDuplicateText: { _ in }
            )
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

// MARK: - Text overlay (faithful sibling of TextOverlayItemView)

private struct CoverTextOverlayItemView: View {
    let text: String
    let xNorm: Double
    let yNorm: Double
    let scale: Double
    let rotation: Double
    let canvasSize: CGSize
    let gestureOrigin: CGPoint
    let isSelected: Bool
    let showsControls: Bool
    let onSelect: () -> Void
    let onMove: (Double, Double) -> Void
    let onResize: (Double) -> Void
    let onRotate: (Double) -> Void
    let onEditCommit: (String) -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var scaleDelta: Double = 0
    @State private var rotationDelta: Double = 0
    @State private var rotationGrabAngle: Double?
    @State private var isEditing = false
    @State private var editDraft = ""
    @FocusState private var editFieldFocused: Bool

    private let baseFontSize: CGFloat = 26
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    private var liveScale: Double { min(3.0, max(0.5, scale + scaleDelta)) }
    private var liveRotation: Double { rotation + rotationDelta }

    private var basePosition: CGPoint {
        CGPoint(x: xNorm * canvasSize.width, y: yNorm * canvasSize.height)
    }

    var body: some View {
        Group {
            if isEditing {
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
            } else {
                Text(text)
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
                        if showsControls && isSelected {
                            rotationHandle.offset(y: -(rotationStemHeight + rotationDotDiameter / 2 + 8))
                        }
                    }
                    .rotationEffect(.degrees(liveRotation))
            }
        }
        .position(x: basePosition.x + dragOffset.width, y: basePosition.y + dragOffset.height)
        .onAppear { editDraft = text }
        .onChange(of: text) { _, newValue in
            if !isEditing { editDraft = newValue }
        }
    }

    private var selectionFrame: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.white, lineWidth: 1.5)
            .padding(-8)
            .opacity(showsControls && isSelected ? 1 : 0)
    }

    private var deleteButton: some View {
        cornerButton(systemName: "xmark", background: destructive, action: onDelete)
    }

    private var editButton: some View {
        cornerButton(systemName: "pencil") {
            editDraft = text
            isEditing = true
        }
    }

    private var duplicateButton: some View {
        cornerButton(systemName: "square.on.square", action: onDuplicate)
    }

    private func cornerButton(
        systemName: String,
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
    }

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
                .offset(y: -(rotationStemHeight - rotationDotDiameter / 2))
        }
        .frame(width: 28, height: rotationStemHeight + rotationDotDiameter / 2, alignment: .bottom)
        .contentShape(Rectangle())
        .highPriorityGesture(rotationDragGesture)
    }

    private var rotationDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("coverCanvas"))
            .onChanged { value in
                onSelect()
                let center = CGPoint(
                    x: gestureOrigin.x + basePosition.x + dragOffset.width,
                    y: gestureOrigin.y + basePosition.y + dragOffset.height
                )
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                if rotationGrabAngle == nil { rotationGrabAngle = angle }
                guard let grab = rotationGrabAngle else { return }
                rotationDelta = (angle - grab) * 180 / .pi
            }
            .onEnded { _ in
                var finalRotation = liveRotation
                finalRotation = finalRotation.truncatingRemainder(dividingBy: 360)
                if finalRotation > 180 { finalRotation -= 360 }
                if finalRotation <= -180 { finalRotation += 360 }
                rotationDelta = 0
                rotationGrabAngle = nil
                onRotate(finalRotation)
            }
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragOffset = value.translation
            }
            .onEnded { value in
                let deltaX = value.translation.width / max(canvasSize.width, 1)
                let deltaY = value.translation.height / max(canvasSize.height, 1)
                let newX = min(0.98, max(0.02, xNorm + deltaX))
                let newY = min(0.98, max(0.02, yNorm + deltaY))
                dragOffset = .zero
                onMove(newX, newY)
            }
    }

    private var resizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                scaleDelta = Double(value.translation.width) / 120.0
            }
            .onEnded { _ in
                onResize(liveScale)
                scaleDelta = 0
            }
    }

    private func commitEdit() {
        guard isEditing else { return }
        isEditing = false
        editFieldFocused = false
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != text {
            onEditCommit(trimmed)
        } else {
            editDraft = text
        }
    }
}

// MARK: - Photo overlay

private struct CoverPhotoOverlayItemView: View {
    let image: UIImage
    let xNorm: Double
    let yNorm: Double
    let scale: Double
    let rotation: Double
    let mirrored: Bool
    let canvasSize: CGSize
    let gestureOrigin: CGPoint
    let isSelected: Bool
    let showsControls: Bool
    let onSelect: () -> Void
    let onMove: (Double, Double) -> Void
    let onResize: (Double) -> Void
    let onRotate: (Double) -> Void
    let onMirror: () -> Void
    let onDelete: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var scaleDelta: Double = 0
    @State private var rotationDelta: Double = 0
    @State private var rotationGrabAngle: Double?

    private let baseWidthFraction: CGFloat = 0.4
    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    private var liveScale: Double { min(3.0, max(0.2, scale + scaleDelta)) }
    private var liveRotation: Double { rotation + rotationDelta }

    private var boxSize: CGSize {
        let width = canvasSize.width * baseWidthFraction * CGFloat(liveScale)
        let aspect = image.size.width / max(image.size.height, 1)
        return CGSize(width: width, height: width / aspect)
    }

    private var basePosition: CGPoint {
        CGPoint(x: xNorm * canvasSize.width, y: yNorm * canvasSize.height)
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            .frame(width: boxSize.width, height: boxSize.height)
            .overlay(selectionFrame)
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }
            .highPriorityGesture(moveDragGesture)
            .overlay(alignment: .topLeading) {
                if showsControls && isSelected { deleteButton.offset(x: -30, y: -30) }
            }
            .overlay(alignment: .bottomLeading) {
                if showsControls && isSelected { mirrorButton.offset(x: -30, y: 30) }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsControls && isSelected { resizeHandle.offset(x: 25, y: 25) }
            }
            .overlay(alignment: .top) {
                if showsControls && isSelected {
                    rotationHandle.offset(y: -(rotationStemHeight + rotationDotDiameter / 2 + 8))
                }
            }
            .rotationEffect(.degrees(liveRotation))
            .position(x: basePosition.x + dragOffset.width, y: basePosition.y + dragOffset.height)
    }

    private var selectionFrame: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.white, lineWidth: 1.5)
            .padding(-8)
            .opacity(showsControls && isSelected ? 1 : 0)
    }

    private var deleteButton: some View {
        cornerButton(systemName: "xmark", background: destructive, action: onDelete)
    }

    private var mirrorButton: some View {
        cornerButton(systemName: "arrow.left.and.right", action: onMirror)
    }

    private func cornerButton(
        systemName: String,
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
    }

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
                .offset(y: -(rotationStemHeight - rotationDotDiameter / 2))
        }
        .frame(width: 28, height: rotationStemHeight + rotationDotDiameter / 2, alignment: .bottom)
        .contentShape(Rectangle())
        .highPriorityGesture(rotationDragGesture)
    }

    private var rotationDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("coverCanvas"))
            .onChanged { value in
                onSelect()
                let center = CGPoint(
                    x: gestureOrigin.x + basePosition.x + dragOffset.width,
                    y: gestureOrigin.y + basePosition.y + dragOffset.height
                )
                let angle = atan2(value.location.y - center.y, value.location.x - center.x)
                if rotationGrabAngle == nil { rotationGrabAngle = angle }
                guard let grab = rotationGrabAngle else { return }
                rotationDelta = (angle - grab) * 180 / .pi
            }
            .onEnded { _ in
                var finalRotation = liveRotation
                finalRotation = finalRotation.truncatingRemainder(dividingBy: 360)
                if finalRotation > 180 { finalRotation -= 360 }
                if finalRotation <= -180 { finalRotation += 360 }
                rotationDelta = 0
                rotationGrabAngle = nil
                onRotate(finalRotation)
            }
    }

    private var moveDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragOffset = value.translation
            }
            .onEnded { value in
                let deltaX = value.translation.width / max(canvasSize.width, 1)
                let deltaY = value.translation.height / max(canvasSize.height, 1)
                let newX = min(0.98, max(0.02, xNorm + deltaX))
                let newY = min(0.98, max(0.02, yNorm + deltaY))
                dragOffset = .zero
                onMove(newX, newY)
            }
    }

    private var resizeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                scaleDelta = Double(value.translation.width) / 120.0
            }
            .onEnded { _ in
                onResize(liveScale)
                scaleDelta = 0
            }
    }
}
