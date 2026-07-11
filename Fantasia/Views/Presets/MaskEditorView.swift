// MaskEditorView.swift
// Fantasia
// Magic Editor (09.2-10, SC4): a PencilKit mask-drawing screen. The user paints over a region of
// a source image; on Generate, the painted strokes are exported as an alpha-mask PNG (painted =
// transparent = "edit this", everywhere else = opaque = "preserve") at the source's exact pixel
// size, both source + mask are uploaded as references, and a preset_id="magic-editor" generation
// is submitted — the backend's inline OpenAI gpt-image-2 mask-edit path (09.2-08) does the rest.
//
// Two entry points, one view (RESEARCH Open Question 4):
//   - `.url(...)`  — from GenerationDetailSheet's "Edit" action on a completed image; the source
//                    is that generation's own completed media URL.
//   - `.pick`      — from the Home "Magic Editor" card; the user picks a photo from their library
//                    first, then paints.
//
// CRITICAL (CLAUDE.md keyboard/composer freeze): this is a brand-new, standalone modal, exactly
// like PresetInputSheet. It does NOT import or modify GenerateView / HighlightingTextView /
// KeyboardHeightReader or any of their frozen keyboard-avoidance internals. The optional text
// field below is a plain SwiftUI TextField.

import SwiftUI
import PhotosUI
import PencilKit
import AVFoundation
import UIKit

/// Preset mask-visibility swatches, Preview-markup style (2026-07-11 polish, Item 6). Color is
/// purely cosmetic feedback so the paint reads against any photo (dark image needs a bright
/// mask) — it never affects the exported mask. `MediaPrepService.alphaMaskPNG` thresholds on
/// stroke COVERAGE, not hue/alpha value, so swapping colors here is safe by construction.
enum MaskPalette {
    static let colors: [UIColor] = [
        .magenta,
        .systemRed,
        .systemBlue,
        .systemGreen,
        .systemYellow,
        .white
    ]
}

struct MaskEditorView: View {
    enum Source {
        case url(String)   // detail-sheet entry — an existing generation's completed media URL
        case pick           // Home entry — user picks a photo from their library first
    }

    let source: Source

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager

    // The (possibly downsized) source image actually displayed + painted over + uploaded — its
    // `.size` IS the "source pixel size" the exported mask must exactly match (Pitfall 2/7).
    @State private var sourceImage: UIImage?
    @State private var isLoadingSource = false
    @State private var loadError: String?

    // PencilKit is a class (reference type) — a plain @State holding the instance is the
    // standard SwiftUI+PencilKit idiom; mutations happen through the reference, not a Binding.
    @State private var canvasView = PKCanvasView()
    @State private var hasStrokes = false

    // Tool row state (Items 3/6): pen width + color are user-adjustable, visibility-only —
    // see MaskPalette doc comment. Defaults: pen selected, first swatch, width 20.
    @State private var penWidth: CGFloat = 20
    @State private var maskColorIndex: Int = 0
    @State private var isErasing = false
    @State private var showColorPalette = false
    private var maskColor: UIColor { MaskPalette.colors[maskColorIndex] }
    private static let penSizes: [CGFloat] = [12, 20, 34]

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    // Item 4: live cost for the Generate button. Own instance (like HomeView/GenerationDetailSheet)
    // — the registry has a bundled/snapshot fallback so a cost is available immediately.
    @State private var registry = PresetRegistryManager()

    /// The magic-editor preset's flat credit cost, or nil until the registry provides one.
    private var magicEditorCost: Int? {
        guard let cost = registry.presets.first(where: { $0.presetId == "magic-editor" })?.cost else { return nil }
        if case .flat(let credits) = cost { return credits }
        return nil
    }

    // Home "pick a source photo" mode only.
    @State private var showPhotosPicker = false
    @State private var selectedPickerItem: PhotosPickerItem?

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()

            if let sourceImage {
                editorContent(sourceImage)
            } else if isLoadingSource {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: theme.textPrimary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                closeButton
            }
            .padding(.top, 8)
            .padding(.trailing, 18)
        }
        .task {
            if case .url(let urlString) = source {
                await loadSourceFromURL(urlString)
            }
        }
        .task { await registry.loadIfNeeded() }
        .photosPicker(isPresented: $showPhotosPicker, selection: $selectedPickerItem, matching: .images)
        .onChange(of: selectedPickerItem) { _, newValue in
            Task { await loadSourceFromPicker(newValue) }
        }
        .alert("Couldn't load image", isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
        .alert("Couldn't complete that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text("Magic Editor")
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Choose a photo, paint over what you want to change, and describe the edit.")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                showPhotosPicker = true
            } label: {
                Text("Choose Photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 190, height: 48)
                    .background { Capsule().fill(LinearGradient.brandPrimary) }
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 6)
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorContent(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // AVMakeRect gives the EXACT `.scaledToFit()` frame (accounting for letterboxing
                // when the container's aspect ratio differs from the image's) — the canvas must
                // sit exactly on top of that fitted rect, not the full container, or painted
                // strokes would register at the wrong on-screen position relative to the image.
                let fitRect = AVMakeRect(
                    aspectRatio: image.size,
                    insideRect: CGRect(origin: .zero, size: geo.size)
                )
                ZStack(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    MaskCanvasRepresentable(
                        canvasView: canvasView,
                        penWidth: penWidth,
                        maskColor: maskColor,
                        isErasing: isErasing
                    ) { changed in
                        hasStrokes = changed
                    }
                    .frame(width: fitRect.width, height: fitRect.height)
                    .position(x: fitRect.midX, y: fitRect.midY)

                    if !hasStrokes {
                        hintPill
                            .padding(.top, 10)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: hasStrokes)
            }
            .padding(.top, 56)
            .padding(.horizontal, 12)

            controlsBar
        }
    }

    // First-use discoverability pill (Item 6.4): tells the user to paint, auto-hides on first
    // stroke. allowsHitTesting(false) so it never blocks painting underneath it.
    private var hintPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 12, weight: .semibold))
            Text("Draw over what you want to change")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var controlsBar: some View {
        VStack(spacing: 12) {
            toolRow

            TextField(
                "",
                text: $text,
                prompt: Text("Describe the change (optional)").foregroundStyle(theme.textTertiary),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1...3)
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))

            // Live cost (Item 4) — magic-editor is a flat-cost preset; mirrors PresetInputSheet's
            // "✦ N credits" label. Hidden until the registry has a cost (never show "0 credits").
            if let magicEditorCost {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                    Text("\(magicEditorCost)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("credits")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }

            Button {
                Task { await submit(sourceImage: sourceImage) }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Generate")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background {
                    if hasStrokes && !isSubmitting {
                        Capsule().fill(LinearGradient.brandPrimary)
                    } else {
                        Capsule().fill(theme.surfaceStrong)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!hasStrokes || isSubmitting)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Tool row (Item 6): Pen/Eraser toggle, size dots, color well, Undo/Clear

    private var toolRow: some View {
        HStack(spacing: 10) {
            toolChip(systemImage: "pencil.tip", isSelected: !isErasing, accessibilityLabel: "Pen") {
                isErasing = false
            }
            toolChip(systemImage: "eraser", isSelected: isErasing, accessibilityLabel: "Eraser") {
                isErasing = true
            }

            Spacer(minLength: 2)

            HStack(spacing: 8) {
                ForEach(Self.penSizes, id: \.self) { size in
                    sizeDot(size)
                }
            }

            Spacer(minLength: 2)

            colorWellButton

            Spacer(minLength: 2)

            Button {
                canvasView.undoManager?.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .disabled(canvasView.undoManager?.canUndo != true)
            .accessibilityLabel("Undo")

            Button {
                canvasView.drawing = PKDrawing()
                hasStrokes = false
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .disabled(!hasStrokes)
            .accessibilityLabel("Clear")
        }
        .foregroundStyle(theme.textPrimary)
        .buttonStyle(PressableButtonStyle())
    }

    private func toolChip(
        systemImage: String,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? .white : theme.textPrimary)
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(LinearGradient.brandPrimary)
                    } else {
                        Circle().fill(theme.surface)
                    }
                }
                .overlay(Circle().stroke(theme.surfaceBorder, lineWidth: isSelected ? 0 : 0.75))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func sizeDot(_ size: CGFloat) -> some View {
        let diameter = min(max(size * 0.55, 10), 22)
        return Button {
            penWidth = size
        } label: {
            ZStack {
                Circle()
                    .fill(theme.surface)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle().stroke(
                            penWidth == size ? Color(maskColor) : theme.surfaceBorder,
                            lineWidth: penWidth == size ? 1.5 : 0.75
                        )
                    )
                Circle()
                    .fill(theme.textPrimary)
                    .frame(width: diameter, height: diameter)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Pen size \(Int(size))")
    }

    // Preview-markup-style color well: a filled circle showing the current mask color; tapping
    // opens a small popover palette. Color is visibility-only (MaskPalette doc comment) — never
    // sent to the server, never affects the exported mask.
    private var colorWellButton: some View {
        Button {
            showColorPalette = true
        } label: {
            Circle()
                .fill(Color(maskColor))
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Mask color")
        .popover(isPresented: $showColorPalette, arrowEdge: .bottom) {
            colorPalettePopover
        }
    }

    private var colorPalettePopover: some View {
        HStack(spacing: 14) {
            ForEach(Array(MaskPalette.colors.enumerated()), id: \.offset) { index, color in
                Button {
                    maskColorIndex = index
                    showColorPalette = false
                } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Circle().stroke(theme.textPrimary, lineWidth: maskColorIndex == index ? 2 : 0)
                        )
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Source loading

    private func loadSourceFromURL(_ urlString: String) async {
        guard let url = URL(string: urlString) else {
            loadError = "Invalid image URL."
            return
        }
        isLoadingSource = true
        defer { isLoadingSource = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                loadError = "Couldn't read this image."
                return
            }
            sourceImage = Self.prepareSourceImage(image)
        } catch {
            loadError = "Couldn't load this image."
        }
    }

    private func loadSourceFromPicker(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingSource = true
        defer { isLoadingSource = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            loadError = "Couldn't read the selected photo."
            selectedPickerItem = nil
            return
        }
        sourceImage = Self.prepareSourceImage(image)
        selectedPickerItem = nil
    }

    /// Downsizes to satisfy gpt-image-2's output-size constraints (RESEARCH Pitfall 7: each edge
    /// a multiple of 16; clamp the longest edge) and normalizes EXIF orientation to canonical
    /// `.up` (drawing into a fresh `UIGraphicsImageRenderer` context applies `imageOrientation`
    /// automatically — Photos/camera images are frequently NOT `.up`). The returned image's
    /// `.size` becomes the single source of truth for "source pixel size", used identically by
    /// both on-screen display (AVMakeRect in `editorContent`) and mask export (`submit` below) —
    /// they must never diverge, or painted strokes would misalign with the uploaded source.
    private static func prepareSourceImage(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return image }
        let longest = max(w, h)
        let factor: CGFloat = longest > maxDimension ? maxDimension / longest : 1
        var newW = (w * factor / 16).rounded(.down) * 16
        var newH = (h * factor / 16).rounded(.down) * 16
        newW = max(newW, 16)
        newH = max(newH, 16)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH))
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
        }
    }

    // MARK: - Submit (D-10/D-11 pattern, mirrors PresetInputSheet.generate())

    private func submit(sourceImage: UIImage?) async {
        guard let sourceImage, hasStrokes, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        // The canvas's own bounds are the on-screen FITTED frame (points) — see editorContent's
        // AVMakeRect. Scale maps points → the source's exact pixel size (Pitfall 2: mismatched
        // dims → undefined behavior), since the fitted frame preserves the source's aspect ratio.
        let sourcePixelSize = sourceImage.size
        let canvasBoundsSize = canvasView.bounds.size
        guard canvasBoundsSize.width > 0, canvasBoundsSize.height > 0, sourcePixelSize.width > 0 else {
            errorMessage = "Please paint a region before generating."
            return
        }
        let scale = sourcePixelSize.width / canvasBoundsSize.width
        let strokeImage = canvasView.drawing.image(
            from: CGRect(origin: .zero, size: canvasBoundsSize),
            scale: scale
        )
        let maskData = MediaPrepService.alphaMaskPNG(strokeImage: strokeImage, sourcePixelSize: sourcePixelSize)
        guard let sourceData = sourceImage.pngData() else {
            errorMessage = "Couldn't prepare this image. Try again."
            return
        }

        let sourceUpload: UploadResponse
        let maskUpload: UploadResponse
        do {
            async let sourceUploadTask = APIClient.shared.uploadReferenceMedia(
                data: sourceData, mimeType: "image/png", fileName: "magic-editor-source.png"
            )
            async let maskUploadTask = APIClient.shared.uploadReferenceMedia(
                data: maskData, mimeType: "image/png", fileName: "magic-editor-mask.png"
            )
            (sourceUpload, maskUpload) = try await (sourceUploadTask, maskUploadTask)
        } catch {
            errorMessage = "Couldn't upload this image. Try again."
            return
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // D-11: only preset_id + slot upload ids + mask_upload_id are sent — the server's
        // presetResolver owns model/media_type/prompt expansion for the magic-editor preset,
        // exactly like every other preset submission.
        let body = GenerationRequestBody(
            prompt: trimmedText,
            model: "",
            mediaType: "image",
            duration: nil,
            resolution: nil,
            aspectRatio: nil,
            audioEnabled: nil,
            imageAspectRatio: nil,
            imageQuality: nil,
            referenceImages: nil,
            referenceVideos: nil,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: nil,
            referenceVideoGenerationIds: nil,
            presetId: "magic-editor",
            presetInputUploadIds: [sourceUpload.id],
            maskUploadId: maskUpload.id
        )

        // Optimistic UI (mirrors PresetInputSheet.generate()): drop a pending placeholder into
        // GenerationManager immediately — the run then rides the existing pending-card machinery
        // in the Generate feed, no tab switch required.
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: "gpt-image-2",
            mediaType: .image,
            prompt: nil,
            params: GenerationParams(
                resolution: nil,
                duration: nil,
                aspectRatio: nil,
                audioEnabled: nil,
                hasReference: true,
                width: nil,
                height: nil,
                presetId: "magic-editor",
                presetInputUploadIds: [sourceUpload.id]
            ),
            costCredits: magicEditorCost ?? 0,
            referenceUrls: nil,
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            generationManager.removeLocalPlaceholder(id: placeholderId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            dismiss()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                errorMessage = "This may not adhere to our community guidelines. Please try again."
            } else {
                errorMessage = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            errorMessage = "An error has occurred. Please try again."
        }
    }
}

// MARK: - PencilKit canvas (UIViewRepresentable)

/// A thin `PKCanvasView` wrapper. `drawingPolicy = .anyInput` allows finger drawing (not every
/// user has an Apple Pencil); a crisp, semi-transparent pen tool lets the user see what they've
/// painted against the source image underneath (visible feedback, not opaque cover — color is
/// cosmetic, see `MaskPalette`). Undo/eraser come for free via `PKCanvasView`/PencilKit (RESEARCH
/// "Don't Hand-Roll": PencilKit gives pressure/eraser/undo for free).
private struct MaskCanvasRepresentable: UIViewRepresentable {
    let canvasView: PKCanvasView
    var penWidth: CGFloat
    var maskColor: UIColor
    var isErasing: Bool
    var onStrokesChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = context.coordinator
        applyTool(to: canvasView)
        return canvasView
    }

    // Re-applied on every SwiftUI update so Pen/Eraser toggle, size dots, and color-well
    // selections (all plain @State on MaskEditorView) propagate to the stored PKCanvasView
    // reference — the idiom for a UIViewRepresentable backed by a reference-type view.
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        applyTool(to: uiView)
    }

    private func applyTool(to canvasView: PKCanvasView) {
        canvasView.tool = isErasing
            ? PKEraserTool(.vector)
            : PKInkingTool(.pen, color: maskColor.withAlphaComponent(0.55), width: penWidth)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onStrokesChanged)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: (Bool) -> Void
        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange(!canvasView.drawing.strokes.isEmpty)
        }
    }
}
