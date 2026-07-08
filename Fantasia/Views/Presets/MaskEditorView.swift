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

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

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
                    .background(accent, in: Capsule())
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
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    MaskCanvasRepresentable(canvasView: canvasView) { changed in
                        hasStrokes = changed
                    }
                    .frame(width: fitRect.width, height: fitRect.height)
                    .position(x: fitRect.midX, y: fitRect.midY)
                }
            }
            .padding(.top, 56)
            .padding(.horizontal, 12)

            controlsBar
        }
    }

    private var controlsBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                Button {
                    canvasView.undoManager?.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(canvasView.undoManager?.canUndo != true)

                Button {
                    canvasView.drawing = PKDrawing()
                    hasStrokes = false
                } label: {
                    Label("Clear", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(!hasStrokes)

                Spacer()
            }
            .foregroundStyle(theme.textPrimary)

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
                .background((hasStrokes && !isSubmitting) ? accent : theme.surfaceStrong, in: Capsule())
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
            costCredits: 0,
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
/// user has an Apple Pencil); a semi-transparent marker tool lets the user see what they've
/// painted against the source image underneath. Undo comes for free via `PKCanvasView`'s own
/// `undoManager` (RESEARCH "Don't Hand-Roll": PencilKit gives pressure/eraser/undo for free).
private struct MaskCanvasRepresentable: UIViewRepresentable {
    let canvasView: PKCanvasView
    var onStrokesChanged: (Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.marker, color: UIColor(red: 0.545, green: 0.427, blue: 0.839, alpha: 0.55), width: 44)
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

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
