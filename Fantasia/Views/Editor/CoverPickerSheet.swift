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

private enum CoverPreviewQuality: String {
    case fast
    case precise

    var tolerance: CMTime {
        switch self {
        case .fast: CMTime(value: 1, timescale: 2)
        case .precise: .zero
        }
    }
}

private struct CoverPreviewRequest {
    let version: UInt
    let time: Double
    let quality: CoverPreviewQuality
}

private struct CoverPreviewResult {
    let version: UInt
    let quality: CoverPreviewQuality
    let image: UIImage
    let pixelSize: CGSize
    let aspect: CGFloat
}

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
    @State private var previewResult: CoverPreviewResult?
    @State private var stripFrames: [UIImage?] = []
    @State private var stripCellCount = 0
    @State private var isLoadingComposition = true
    @State private var mediaLoadFailed = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    // One serialized, versioned coordinator owns both fast and precise preview generation.
    @State private var isPreviewRenderInFlight = false
    @State private var pendingPreviewRequest: CoverPreviewRequest?
    @State private var previewRequestVersion: UInt = 0
    @State private var expectedPrecisePreviewVersion: UInt?
    @State private var measuredDisplayVersion: UInt?
    @State private var stripDragStartTime: Double?
    @State private var scrubFrameLadder = ScrubFrameLadder()
    @State private var showsScrubFrame = false

    // Ephemeral overlay state — never persisted; see file header.
    @State private var coverOverlays: [CoverOverlay] = []
    @State private var selectedOverlayId: UUID?
    @State private var selectedTab: CoverEditorTab = .frame
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var fallbackCanvasPixelSize = CGSize(width: 1080, height: 1920)
    @State private var fallbackCanvasAspect: CGFloat = 9.0 / 16.0
    @State private var previewContainerSize: CGSize = .zero
    @State private var canvasDisplaySize: CGSize = .zero

    private let canvasBackground = Color(red: 0.039, green: 0.039, blue: 0.051) // #0A0A0D
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)               // #8C59FF
    private let stripCellWidth: CGFloat = 46
    private let stripCellHeight: CGFloat = 64

    private var ladderFrame: UIImage? {
        guard showsScrubFrame else { return nil }
        return scrubFrameLadder.frame(project: project.clips, at: scrubbedTime, ranges: ranges)
    }
    private var previewImage: UIImage? { ladderFrame ?? previewResult?.image }
    private var canvasPixelSize: CGSize { previewResult?.pixelSize ?? fallbackCanvasPixelSize }
    private var canvasAspect: CGFloat {
        if let ladderFrame, ladderFrame.size.height > 0 {
            return ladderFrame.size.width / ladderFrame.size.height
        }
        return previewResult?.aspect ?? fallbackCanvasAspect
    }
    private var isCurrentPrecisePreviewReady: Bool {
        guard let result = previewResult,
              result.quality == .precise,
              result.version == expectedPrecisePreviewVersion,
              result.version == measuredDisplayVersion,
              canvasDisplaySize.width > 0,
              canvasDisplaySize.height > 0
        else { return false }
        return true
    }

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
            .disabled(isSaving || !isCurrentPrecisePreviewReady)
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
                    overlaySizeScale: 1,
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
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                updatePreviewContainerSize($0)
            }
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
                if stripDragStartTime == nil {
                    stripDragStartTime = scrubbedTime
                    showsScrubFrame = true
                    // A precise request already decoding may finish during this drag. Invalidate
                    // it so ladder display remains authoritative until the release landing.
                    previewRequestVersion &+= 1
                    pendingPreviewRequest = nil
                    expectedPrecisePreviewVersion = nil
                    measuredDisplayVersion = nil
                }
                let start = stripDragStartTime ?? scrubbedTime
                let next = start - value.translation.width / stripPx
                scrubbedTime = min(max(0, next), totalDuration)
            }
            .onEnded { _ in
                stripDragStartTime = nil
                // 13-26 M5: one PRECISE (zero-tolerance) render at the final resting time — the
                // during-drag loop uses fast keyframe-near frames, this lands the exact frame.
                requestPreview(at: scrubbedTime, quality: .precise)
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
        // Invalidate any older coordinator work without starting a second drain. If one request
        // is already decoding, its stale completion will release the slot and pick up the new
        // precise request below.
        previewRequestVersion &+= 1
        pendingPreviewRequest = nil
        expectedPrecisePreviewVersion = nil
        measuredDisplayVersion = nil
        previewResult = nil
        canvasDisplaySize = .zero
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
        scrubFrameLadder.warm(project: project.clips, ranges: builtRanges, at: scrubbedTime)

        if let renderSize = builtVideoComposition?.renderSize, renderSize.width > 0, renderSize.height > 0 {
            fallbackCanvasPixelSize = capLongEdge(renderSize, maxEdge: 1440)
            fallbackCanvasAspect = renderSize.width / renderSize.height
        } else {
            fallbackCanvasAspect = aspectFraction(for: project.aspectRatio)
            fallbackCanvasPixelSize = capLongEdge(
                CGSize(width: 1080, height: 1080 / fallbackCanvasAspect),
                maxEdge: 1440
            )
        }

        requestPreview(at: scrubbedTime, quality: .precise)
        isLoadingComposition = false
    }

    /// One latest-wins request slot backs both drag previews and release landings. A precise
    /// request replaces any unissued fast request; an already-issued stale request is allowed to
    /// finish but can never publish.
    private func requestPreview(at time: Double, quality: CoverPreviewQuality) {
        previewRequestVersion &+= 1
        let request = CoverPreviewRequest(
            version: previewRequestVersion,
            time: time,
            quality: quality
        )
        pendingPreviewRequest = request
        expectedPrecisePreviewVersion = quality == .precise ? request.version : nil
        measuredDisplayVersion = nil

        guard !isPreviewRenderInFlight else { return }
        isPreviewRenderInFlight = true
        Task { await drainPreviewRequests() }
    }

    private func drainPreviewRequests() async {
        while let request = pendingPreviewRequest {
            pendingPreviewRequest = nil
            let result = await renderPreview(request)
            guard request.version == previewRequestVersion else { continue }
            if let result {
                previewResult = result
                synchronizeDisplayGeometry(for: result, container: previewContainerSize)
                if result.quality == .precise {
                    showsScrubFrame = false
                }
            }
        }
        isPreviewRenderInFlight = false
    }

    private func renderPreview(_ request: CoverPreviewRequest) async -> CoverPreviewResult? {
        guard let active = activeClip(at: request.time),
              let image = await sourceImage(
                for: active.clip,
                localTime: active.localTime,
                quality: request.quality
              ) else { return nil }
        let pixelSize = capLongEdge(
            CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            ),
            maxEdge: 1440
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return CoverPreviewResult(
            version: request.version,
            quality: request.quality,
            image: image,
            pixelSize: pixelSize,
            aspect: pixelSize.width / pixelSize.height
        )
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
        quality: CoverPreviewQuality
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

        guard let generator = await sourceGenerator(for: clip, quality: quality) else { return nil }
        let cmTime = CMTime(seconds: localTime, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: cmTime) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func sourceGenerator(
        for clip: ProjectClip,
        quality: CoverPreviewQuality
    ) async -> AVAssetImageGenerator? {
        // Fast and precise decoders are configured once and never have their tolerances mutated
        // while an async image request may be using them.
        let cacheKey = "\(clip.id):\(quality.rawValue)"
        if let cached = sourceGenerators[cacheKey] { return cached }
        guard let url = await sourceURL(for: clip) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        generator.requestedTimeToleranceBefore = quality.tolerance
        generator.requestedTimeToleranceAfter = quality.tolerance
        sourceGenerators[cacheKey] = generator
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
            fontSizePoints: 26,
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
            widthPoints: canvasDisplaySize.width > 0 ? canvasDisplaySize.width * 0.4 : 120,
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
        guard case .text(let text, let x, let y, let fontSizePoints, let rotation) = overlay.kind else { return }
        let duplicate = CoverOverlay.text(
            id: UUID(),
            text: text,
            xNorm: min(0.94, x + 0.04),
            yNorm: min(0.94, y + 0.04),
            fontSizePoints: fontSizePoints,
            rotation: rotation
        )
        coverOverlays.append(duplicate)
        selectedOverlayId = duplicate.id
    }

    // MARK: - Save

    private func saveCover() async {
        guard isCurrentPrecisePreviewReady, let previewResult else {
            errorMessage = "The selected frame is still loading."
            return
        }
        isSaving = true
        errorMessage = nil
        guard let jpeg = renderCompositeJPEG(previewResult: previewResult) else {
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
    private func renderCompositeJPEG(previewResult: CoverPreviewResult) -> Data? {
        // Preview points become output pixels exactly once, at composite time. Because the
        // display rect and source frame share an aspect, width and height produce one scale.
        guard previewResult.version == measuredDisplayVersion,
              canvasDisplaySize.width > 0 else { return nil }
        let displayToPixelScale = previewResult.pixelSize.width / canvasDisplaySize.width
        let view = CoverCompositeView(
            frameImage: previewResult.image,
            canvasSize: previewResult.pixelSize,
            displayToPixelScale: displayToPixelScale,
            overlays: coverOverlays
        )
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(previewResult.pixelSize)
        renderer.scale = 1.0
        guard let uiImage = renderer.uiImage else { return nil }
        return uiImage.jpegData(compressionQuality: 0.9)
    }

    // MARK: - Helpers

    private func updatePreviewContainerSize(_ size: CGSize) {
        previewContainerSize = size
        guard let previewResult else {
            canvasDisplaySize = .zero
            measuredDisplayVersion = nil
            return
        }
        synchronizeDisplayGeometry(for: previewResult, container: size)
    }

    private func synchronizeDisplayGeometry(
        for result: CoverPreviewResult,
        container: CGSize
    ) {
        guard result.version == previewRequestVersion,
              container.width > 0,
              container.height > 0 else {
            canvasDisplaySize = .zero
            measuredDisplayVersion = nil
            return
        }
        let displaySize = aspectFitRect(container: container, contentAspect: result.aspect).size
        guard displaySize.width > 0, displaySize.height > 0 else {
            canvasDisplaySize = .zero
            measuredDisplayVersion = nil
            return
        }
        canvasDisplaySize = displaySize
        measuredDisplayVersion = result.version
    }

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
        case text(String, xNorm: Double, yNorm: Double, fontSizePoints: Double, rotation: Double)
        case photo(UIImage, xNorm: Double, yNorm: Double, widthPoints: Double, rotation: Double, mirrored: Bool)
    }
    var kind: Kind

    static func text(
        id: UUID, text: String, xNorm: Double, yNorm: Double, fontSizePoints: Double, rotation: Double
    ) -> CoverOverlay {
        CoverOverlay(
            id: id,
            kind: .text(text, xNorm: xNorm, yNorm: yNorm, fontSizePoints: fontSizePoints, rotation: rotation)
        )
    }

    static func photo(
        id: UUID, image: UIImage, xNorm: Double, yNorm: Double,
        widthPoints: Double, rotation: Double, mirrored: Bool
    ) -> CoverOverlay {
        CoverOverlay(
            id: id,
            kind: .photo(
                image,
                xNorm: xNorm,
                yNorm: yNorm,
                widthPoints: widthPoints,
                rotation: rotation,
                mirrored: mirrored
            )
        )
    }
}

// MARK: - Interactive overlay canvas

private struct CoverOverlayCanvas: View {
    let overlays: [CoverOverlay]
    let selectedOverlayId: UUID?
    let canvasSize: CGSize
    /// Preview uses 1 point per stored point. Export supplies the single display-to-pixel scale.
    let overlaySizeScale: CGFloat
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
                case .text(let text, let xNorm, let yNorm, let fontSizePoints, let rotation):
                    CoverTextOverlayItemView(
                        text: text,
                        xNorm: xNorm,
                        yNorm: yNorm,
                        fontSizePoints: fontSizePoints,
                        rotation: rotation,
                        canvasSize: canvasSize,
                        overlaySizeScale: overlaySizeScale,
                        gestureOrigin: gestureOrigin,
                        isSelected: selectedOverlayId == overlay.id,
                        showsControls: showsControls,
                        onSelect: { onSelect(overlay.id) },
                        onMove: { x, y in
                            var updated = overlay
                            updated.kind = .text(
                                text, xNorm: x, yNorm: y,
                                fontSizePoints: fontSizePoints, rotation: rotation
                            )
                            onUpdate(updated)
                        },
                        onResize: { newFontSizePoints in
                            var updated = overlay
                            updated.kind = .text(
                                text, xNorm: xNorm, yNorm: yNorm,
                                fontSizePoints: newFontSizePoints, rotation: rotation
                            )
                            onUpdate(updated)
                        },
                        onRotate: { newRotation in
                            var updated = overlay
                            updated.kind = .text(
                                text, xNorm: xNorm, yNorm: yNorm,
                                fontSizePoints: fontSizePoints, rotation: newRotation
                            )
                            onUpdate(updated)
                        },
                        onEditCommit: { newText in
                            var updated = overlay
                            updated.kind = .text(
                                newText, xNorm: xNorm, yNorm: yNorm,
                                fontSizePoints: fontSizePoints, rotation: rotation
                            )
                            onUpdate(updated)
                        },
                        onDelete: { onDelete(overlay.id) },
                        onDuplicate: { onDuplicateText(overlay) }
                    )

                case .photo(let image, let xNorm, let yNorm, let widthPoints, let rotation, let mirrored):
                    CoverPhotoOverlayItemView(
                        image: image,
                        xNorm: xNorm,
                        yNorm: yNorm,
                        widthPoints: widthPoints,
                        rotation: rotation,
                        mirrored: mirrored,
                        canvasSize: canvasSize,
                        overlaySizeScale: overlaySizeScale,
                        gestureOrigin: gestureOrigin,
                        isSelected: selectedOverlayId == overlay.id,
                        showsControls: showsControls,
                        onSelect: { onSelect(overlay.id) },
                        onMove: { x, y in
                            var updated = overlay
                            updated.kind = .photo(
                                image, xNorm: x, yNorm: y,
                                widthPoints: widthPoints, rotation: rotation, mirrored: mirrored
                            )
                            onUpdate(updated)
                        },
                        onResize: { newWidthPoints in
                            var updated = overlay
                            updated.kind = .photo(
                                image, xNorm: xNorm, yNorm: yNorm,
                                widthPoints: newWidthPoints, rotation: rotation, mirrored: mirrored
                            )
                            onUpdate(updated)
                        },
                        onRotate: { newRotation in
                            var updated = overlay
                            updated.kind = .photo(
                                image, xNorm: xNorm, yNorm: yNorm,
                                widthPoints: widthPoints, rotation: newRotation, mirrored: mirrored
                            )
                            onUpdate(updated)
                        },
                        onMirror: {
                            var updated = overlay
                            updated.kind = .photo(
                                image, xNorm: xNorm, yNorm: yNorm,
                                widthPoints: widthPoints, rotation: rotation, mirrored: !mirrored
                            )
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
    let displayToPixelScale: CGFloat
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
                overlaySizeScale: displayToPixelScale,
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
    /// Absolute size in preview display points; independent of the fitted canvas dimensions.
    let fontSizePoints: Double
    let rotation: Double
    let canvasSize: CGSize
    let overlaySizeScale: CGFloat
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
    @State private var sizeDeltaPoints: Double = 0
    @State private var rotationDelta: Double = 0
    @State private var rotationGrabAngle: Double?
    @State private var isEditing = false
    @State private var editDraft = ""
    @FocusState private var editFieldFocused: Bool

    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    private var liveFontSizePoints: Double {
        min(78, max(13, fontSizePoints + sizeDeltaPoints))
    }
    private var renderedFontSize: CGFloat {
        CGFloat(liveFontSizePoints) * overlaySizeScale
    }
    private var liveRotation: Double { rotation + rotationDelta }

    private var basePosition: CGPoint {
        CGPoint(x: xNorm * canvasSize.width, y: yNorm * canvasSize.height)
    }

    var body: some View {
        Group {
            if isEditing {
                TextField("Text", text: $editDraft)
                    .font(.system(size: renderedFontSize, weight: .heavy))
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
                    .font(.system(size: renderedFontSize, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(
                        color: .black.opacity(0.65),
                        radius: 10 * overlaySizeScale,
                        y: 2 * overlaySizeScale
                    )
                    .fixedSize()
                    .padding(6 * overlaySizeScale)
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
                // Preserve the old handle sensitivity: 120pt horizontal movement changed a
                // 26pt default by one full base size.
                sizeDeltaPoints = Double(value.translation.width) * 26.0 / 120.0
            }
            .onEnded { _ in
                onResize(liveFontSizePoints)
                sizeDeltaPoints = 0
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
    /// Absolute box width in preview display points; never derived from the current canvas rect.
    let widthPoints: Double
    let rotation: Double
    let mirrored: Bool
    let canvasSize: CGSize
    let overlaySizeScale: CGFloat
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
    @State private var widthDeltaPoints: Double = 0
    @State private var rotationDelta: Double = 0
    @State private var rotationGrabAngle: Double?

    private let destructive = Color(red: 1.0, green: 0.329, blue: 0.439)

    private var liveWidthPoints: Double {
        min(480, max(24, widthPoints + widthDeltaPoints))
    }
    private var liveRotation: Double { rotation + rotationDelta }

    private var boxSize: CGSize {
        let width = CGFloat(liveWidthPoints) * overlaySizeScale
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
                widthDeltaPoints = Double(value.translation.width)
            }
            .onEnded { _ in
                onResize(liveWidthPoints)
                widthDeltaPoints = 0
            }
    }
}
