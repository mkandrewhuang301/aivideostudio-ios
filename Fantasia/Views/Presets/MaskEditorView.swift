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

/// Mask-visibility color, Preview-markup style (2026-07-11 polish, Item 6; single-color 2026-07-12).
/// Color is purely cosmetic feedback so the paint reads against any photo — it never affects the
/// exported mask (`MediaPrepService.alphaMaskPNG` thresholds on stroke COVERAGE, not hue/alpha
/// value). Fixed to magenta only (not user-selectable): a color picker implied different colors
/// could mean different edit instructions to the model, which isn't true — gpt-image-2's mask
/// param is alpha-only (verified against OpenAI's API reference), so there is exactly one prompt
/// and one mask region regardless of paint color. Magenta is the rarest hue in real photo content
/// (skin/sky/foliage/most objects), so it stays visible against the widest range of photos without
/// the ambiguity a multi-color palette invited.
enum MaskPalette {
    static let color: UIColor = .magenta
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
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    // The (possibly downsized) source image actually displayed + painted over + uploaded — its
    // `.size` IS the "source pixel size" the exported mask must exactly match (Pitfall 2/7).
    @State private var sourceImage: UIImage?
    @State private var isLoadingSource = false
    @State private var loadError: String?

    // PencilKit is a class (reference type) — a plain @State holding the instance is the
    // standard SwiftUI+PencilKit idiom; mutations happen through the reference, not a Binding.
    @State private var canvasView = PKCanvasView()
    @State private var hasStrokes = false

    // Tool row state (Item 3): pen width is user-adjustable; color is fixed (MaskPalette doc
    // comment) — not a per-user choice. Defaults: pen selected, width 20.
    @State private var penWidth: CGFloat = 20
    @State private var isErasing = false
    private static let penSizes: [CGFloat] = [12, 20, 34]

    @State private var text: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    // Standalone modal's OWN plain TextField (NOT GenerateView's frozen composer) — a focus flag
    // drives the down-chevron dismiss affordance below.
    @FocusState private var isTextFocused: Bool

    // Item 4: live cost for the Generate button. Own instance (like HomeView/GenerationDetailSheet)
    // — the registry has a bundled/snapshot fallback so a cost is available immediately.
    @State private var registry = PresetRegistryManager()

    /// The magic-editor preset's flat credit cost, or nil until the registry provides one.
    private var magicEditorCost: Int? {
        guard let cost = registry.presets.first(where: { $0.presetId == "magic-editor" })?.cost else { return nil }
        if case .flat(let credits) = cost { return credits }
        return nil
    }

    private var trimmedPrompt: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Generate requires BOTH a painted region AND a non-empty description (prompt is required).
    private var canGenerate: Bool { hasStrokes && !trimmedPrompt.isEmpty && !isSubmitting }

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
        .task {
            // Warm the backend as soon as the editor opens — overlaps a cold Railway boot with the
            // time the user spends painting the mask + typing the prompt, so Generate's own network
            // round trip isn't racing a sleeping instance (same pattern as PresetInputSheet.swift).
            await APIClient.shared.pingHealth()
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
            ZStack(alignment: .top) {
                // Two-finger pinch/pan zoom; the image + mask live in ONE container so they scale
                // 1:1 together (user-requested). One finger is left free to draw. The canvas keeps
                // a FIXED coordinate space (its own bounds never change — the outer scroll view's
                // transform does the scaling), so mask export in submit() stays zoom-independent
                // and unchanged.
                ZoomableMaskCanvas(
                    canvasView: canvasView,
                    image: image,
                    penWidth: penWidth,
                    maskColor: MaskPalette.color,
                    isErasing: isErasing
                ) { changed in
                    hasStrokes = changed
                }

                if !hasStrokes {
                    hintPill
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // While the keyboard is up, the whole upper (image) area above the text box becomes
                // a dismiss zone: a tap OR a small downward swipe anywhere here dismisses instead of
                // painting (same flick-to-dismiss feel as the Generate composer). Only present when
                // focused, so it never interferes with painting/zoom once the keyboard is down.
                if isTextFocused {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { isTextFocused = false }
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    if value.translation.height > 14 && abs(value.translation.width) < 80 {
                                        isTextFocused = false
                                    }
                                }
                        )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasStrokes)
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
                prompt: Text("Describe the change").foregroundStyle(theme.textTertiary),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1...3)
            .focused($isTextFocused)
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))

            // Generate — full width; credit cost shown INSIDE the button, centered next to the
            // label (user-requested). Cost hidden until the registry provides one (never "0").
            Button {
                Task { await submit(sourceImage: sourceImage) }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        HStack(spacing: 7) {
                            Text("Generate")
                                .font(.subheadline.weight(.semibold))
                            if let magicEditorCost {
                                HStack(spacing: 3) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("\(magicEditorCost)")
                                        .font(.subheadline.weight(.bold))
                                }
                                .opacity(0.92)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background {
                    if canGenerate {
                        Capsule().fill(LinearGradient.brandPrimary)
                    } else {
                        Capsule().fill(theme.surfaceStrong)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canGenerate)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
        // Small downward swipe over the controls dismisses the keyboard — same feel as the Generate
        // composer's flick-to-dismiss (replicated locally; this never touches GenerateView's frozen
        // keyboard machinery). simultaneousGesture so button taps still register.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height > 14 && abs(value.translation.width) < 70 {
                        isTextFocused = false
                    }
                }
        )
    }

    // MARK: - Tool row: Pen/Eraser toggle, size dots, Undo/Clear (color is fixed, no picker)

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
                            penWidth == size ? Color(MaskPalette.color) : theme.surfaceBorder,
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
    // Internal (not private), not for any external caller — kept package-visible so
    // FantasiaTests/MaskEditorExportTests.swift can assert its output's ACTUAL pixel dimensions
    // (the same UIGraphicsImageRenderer scale bug fixed here also existed in this function; a
    // test needs real access, not just a same-file exemption, to catch a regression).
    static func prepareSourceImage(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return image }
        let longest = max(w, h)
        let factor: CGFloat = longest > maxDimension ? maxDimension / longest : 1
        var newW = (w * factor / 16).rounded(.down) * 16
        var newH = (h * factor / 16).rounded(.down) * 16
        newW = max(newW, 16)
        newH = max(newH, 16)
        // BUG FIX (2026-07-12): same UIGraphicsImageRenderer(size:) screen-scale default bug as
        // MediaPrepService.alphaMaskPNG — without format.scale = 1, this produced an image whose
        // REAL pixel buffer was newW*scale x newH*scale (2x/3x too large) even though .size
        // (points) correctly reported newW x newH. Every downstream consumer of this image's
        // .size (canvas fitting, mask export sizing) was therefore internally consistent with
        // itself, but the ACTUAL uploaded photo (sourceImage.jpegData(...) in submit(), which
        // encodes at the real pixel buffer, not .size) was silently 2-3x larger than intended —
        // blowing past gpt-image-2's max-dimension constraint this function exists to enforce,
        // and no longer dimension-matched to the mask once alphaMaskPNG's own scale got fixed.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: newW, height: newH), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: newW, height: newH))
        }
    }

    // MARK: - Submit (D-10/D-11 pattern, mirrors PresetInputSheet.generate())

    private func submit(sourceImage: UIImage?) async {
        // Prompt + a painted region are required.
        guard let sourceImage, hasStrokes, !trimmedPrompt.isEmpty, !isSubmitting else { return }

        // Render the mask + source synchronously (local, fast) BEFORE going optimistic. Export reads
        // the canvas's FIXED bounds — unaffected by zoom (the outer scroll view scales the container,
        // not the canvas), so the mask matches exactly what was painted at any zoom.
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
        // JPEG, not PNG: the source is a photo, and PNG's lossless compression runs several MB at
        // 2048px for photographic content vs. a few hundred KB as JPEG — that upload was the
        // dominant cost in the submit-to-Generate-feed delay. OpenAI's /v1/images/edits accepts
        // JPEG for the base "image" param (only the mask needs PNG's alpha channel, unaffected
        // here). Backend (openaiImageService.generateImageEditWithMask) reads the real
        // content-type back off R2 instead of assuming PNG, so this stays correct end-to-end.
        guard let sourceData = sourceImage.jpegData(compressionQuality: 0.9) else {
            errorMessage = "Couldn't prepare this image. Try again."
            return
        }

        // Catch the most common pre-dispatch failure (no credits) WHILE the modal is still up, so we
        // show it here instead of flashing a card that immediately vanishes.
        if let cost = magicEditorCost, creditManager.creditsBalance < cost {
            errorMessage = "Insufficient credits."
            return
        }

        let promptText = trimmedPrompt
        isSubmitting = true
        defer { isSubmitting = false }

        // Drop a pending "Edit" card into the feed (behind the still-open modal). The modal stays
        // OPEN through the whole network round-trip — this is deliberate: doing the uploads/submit
        // after closing tears down this Task mid-flight (CancellationError), which used to hit the
        // catch and silently remove the card (the "loads then disappears" bug). On success we
        // promote to the real id + post .generationSubmitted; presenters close the modal (no
        // self-dismiss → no double-dismiss bounce). On failure the modal is still up, so the user
        // sees WHY instead of the card just vanishing.
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: "gpt-image-2",
            mediaType: .image,
            prompt: promptText,   // shows in the pending "Edit" card
            params: GenerationParams(
                resolution: nil,
                duration: nil,
                aspectRatio: nil,
                audioEnabled: nil,
                hasReference: true,
                width: nil,
                height: nil,
                presetId: "magic-editor",
                presetInputUploadIds: nil   // upload ids not known yet; the server row carries them
            ),
            costCredits: magicEditorCost ?? 0,
            referenceUrls: nil,
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            async let sourceUploadTask = APIClient.shared.uploadReferenceMedia(
                data: sourceData, mimeType: "image/jpeg", fileName: "magic-editor-source.jpg"
            )
            async let maskUploadTask = APIClient.shared.uploadReferenceMedia(
                data: maskData, mimeType: "image/png", fileName: "magic-editor-mask.png"
            )
            let (sourceUpload, maskUpload) = try await (sourceUploadTask, maskUploadTask)
            // Make the user-facing source immediately available to feed/detail preset cards.
            // Do not insert the painted alpha mask: the backend marks it kind=mask and excludes
            // it from the user's reference library by design.
            if let sourceUploadId = sourceUpload.id {
                mediaLibrary.insert(ReferenceUploadItem(
                    id: sourceUploadId,
                    url: sourceUpload.url,
                    mimeType: "image/jpeg",
                    displayName: nil
                ))
            }

            // D-11: only preset_id + upload ids + mask_upload_id are sent — the server's
            // presetResolver owns model/media_type/prompt expansion for the magic-editor preset.
            let body = GenerationRequestBody(
                prompt: promptText,
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
            let submitted = try await APIClient.shared.submitGeneration(body: body)
            // Promote (NOT remove-and-hope) so the pending card stays put and polling updates it in
            // place through to completion, robust to read-replica lag.
            generationManager.promoteLocalPlaceholder(localId: placeholderId, toRealId: submitted.generationId)
            generationManager.startPolling(forceRefresh: true)
            // Close the modal → Generate feed. Presenter-driven (no self-dismiss → no bounce).
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
            await creditManager.fetchBalance()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                errorMessage = "This may not adhere to our community guidelines. Please try again."
            } else {
                print("[MaskEditorView] submit rejected: \(apiError)")
                errorMessage = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            errorMessage = "An error has occurred. Please try again."
        }
    }
}

// MARK: - Zoomable mask canvas (image + PencilKit mask in one zoomable container)

/// Two-finger pinch/pan zoom with the source image and the PencilKit mask living in ONE container,
/// so they scale 1:1 together (Photos-markup style, user-requested). One finger is left free to
/// draw. The OUTER `UIScrollView` owns zooming (its transform scales the container); the
/// `PKCanvasView` keeps a FIXED coordinate space — its own `bounds` never change with zoom — so
/// `MaskEditorView.submit()`'s mask export (which reads `canvasView.bounds`) stays correct at any
/// zoom level, unchanged. `drawingPolicy = .anyInput` allows finger drawing; pen color is cosmetic
/// visibility only (see `MaskPalette`) — the exported mask thresholds on stroke coverage, not hue.
private struct ZoomableMaskCanvas: UIViewRepresentable {
    let canvasView: PKCanvasView
    let image: UIImage
    var penWidth: CGFloat
    var maskColor: UIColor
    var isErasing: Bool
    var maxZoom: CGFloat = 4.0
    var onStrokesChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = LayoutReportingScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maxZoom
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        // Two fingers to pan/zoom → one finger stays free for drawing on the canvas.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2

        let container = UIView()
        container.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        container.addSubview(imageView)

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.isScrollEnabled = false          // outer scroll view owns scrolling/zooming
        canvasView.delegate = context.coordinator
        container.addSubview(canvasView)

        scrollView.addSubview(container)

        let c = context.coordinator
        c.scrollView = scrollView
        c.container = container
        c.imageView = imageView
        c.canvasView = canvasView
        c.imageSize = image.size
        scrollView.onLayout = { [weak c] in c?.layoutContent() }

        applyTool(to: canvasView)
        return scrollView
    }

    // Re-applied on every SwiftUI update so Pen/Eraser toggle, size dots, and color-well selections
    // (plain @State on MaskEditorView) propagate to the stored PKCanvasView reference.
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        applyTool(to: canvasView)
    }

    private func applyTool(to canvasView: PKCanvasView) {
        canvasView.tool = isErasing
            ? PKEraserTool(.vector)
            : PKInkingTool(.pen, color: maskColor.withAlphaComponent(0.85), width: penWidth)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onStrokesChanged) }

    final class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate {
        weak var scrollView: UIScrollView?
        weak var container: UIView?
        weak var imageView: UIImageView?
        weak var canvasView: PKCanvasView?
        var imageSize: CGSize = .zero
        private var configured = false
        let onChange: (Bool) -> Void

        init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

        // Fit the container to the image's aspect inside the scroll view ONCE (bounds are zero
        // until SwiftUI lays the view out). After that, only re-center on zoom. The canvas frame is
        // pinned to this fitted size and never changes — that fixed size is what submit() exports.
        func layoutContent() {
            guard let scrollView, let container, let imageView, let canvasView else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0, imageSize.width > 0 else { return }
            if !configured {
                let fitted = AVMakeRect(aspectRatio: imageSize, insideRect: CGRect(origin: .zero, size: bounds)).size
                container.frame = CGRect(origin: .zero, size: fitted)
                imageView.frame = container.bounds
                canvasView.frame = container.bounds
                scrollView.contentSize = fitted
                scrollView.zoomScale = 1
                configured = true
            }
            centerContent()
        }

        // Center the (possibly-zoomed) content within the scroll view via symmetric insets.
        func centerContent() {
            guard let scrollView, let container else { return }
            let boundsSize = scrollView.bounds.size
            let contentSize = container.frame.size   // reflects the current zoom transform
            let insetX = max(0, (boundsSize.width - contentSize.width) / 2)
            let insetY = max(0, (boundsSize.height - contentSize.height) / 2)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { container }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onChange(!canvasView.drawing.strokes.isEmpty)
        }
    }
}

/// UIScrollView that reports each layout pass — `makeUIView` runs before SwiftUI assigns a real
/// frame, so the fit/centering math must run in `layoutSubviews` (the one hook guaranteed to fire
/// with a valid bounds), mirroring the app's existing `ZoomPanScrollView`.
private final class LayoutReportingScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
