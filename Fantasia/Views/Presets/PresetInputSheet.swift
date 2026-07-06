// PresetInputSheet.swift
// Fantasia
// Schema-driven preset input modal (D-10). Renders a Preset's `input_schema` — N media slots,
// an optional free-text field, an optional style grid — plus a live credit-cost label and a
// Generate button. Presented as a `.fullScreenCover`/full sheet from HomeView's onSelectPreset
// closure (wired outside this plan) and, later, from a preset-badged feed card's Remix action
// (Plan 08), prefilled via `prefillSlots`.
//
// CRITICAL (CLAUDE.md keyboard/composer freeze): this is a brand-new, standalone modal. It does
// NOT import or modify GenerateView or any of its frozen text-input/keyboard-avoidance
// internals (its custom highlighting text view, its keyboard-height reader, or its bottom
// inset layout). The optional text field below is a plain SwiftUI TextField. Slot pickers
// reuse the same three input sources as the composer's paperclip menu
// (PhotosPicker / CameraPicker / .fileImporter, D-19) and the same multipart upload endpoint
// (APIClient.uploadReferenceMedia), but every helper here is a fresh, local implementation
// (PresetMediaPrep below) rather than an edit to GenerateView.swift or MediaPrepService.swift —
// this plan's touched-file list is limited to PresetInputSheet.swift + APIClient.swift.
//
// D-11: the server-side expanded template prompt is never constructed or displayed here — the
// client sends only `preset_id` + `preset_input_upload_ids`; POST /api/generations expands the
// real prompt server-side (presetResolver middleware, backend-owned).

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct PresetInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager
    @Environment(RatesManager.self) private var ratesManager

    let preset: Preset

    @State private var slotInputs: [PresetSlotInput?]
    @State private var text: String = ""
    @State private var selectedStyleId: String?
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    // Slot-picker plumbing — one shared picker set, targeted at `activeSlotIndex`.
    @State private var activeSlotIndex: Int?
    @State private var showPhotosPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false
    @State private var selectedPickerItem: PhotosPickerItem?

    // Motion Transfer 30s confirm-trim (D-16/D-17/D-18).
    @State private var pendingTrim: PendingVideoTrim?

    /// - Parameters:
    ///   - preset: the registry row to render.
    ///   - prefillSlots: existing upload ids/urls/thumbnails to preload per slot index — used by
    ///     Remix (Plan 08) to reopen this same sheet prefilled from a prior run's stored inputs,
    ///     never by routing through the composer.
    init(preset: Preset, prefillSlots: [PresetSlotInput?] = []) {
        self.preset = preset
        let count = preset.inputSchema?.slots.count ?? 0
        var initial = Array<PresetSlotInput?>(repeating: nil, count: count)
        for (index, value) in prefillSlots.enumerated() where index < count {
            initial[index] = value
        }
        _slotInputs = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.elevatedBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        slotsSection
                        textSection
                        styleGridSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 140)
                }

                VStack {
                    Spacer()
                    generateBar
                }
            }
            .navigationTitle(preset.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(theme.surface, in: Circle())
                    }
                }
            }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPickerItem,
            matching: activeSlotKind == "video" ? .videos : .images
        )
        .onChange(of: selectedPickerItem) { _, newValue in
            Task { await handlePhotosPickerSelection(newValue) }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker(
                allowsVideo: activeSlotKind == "video",
                onCapture: { data, isVideo in
                    showCameraPicker = false
                    if let index = activeSlotIndex {
                        Task { await handlePickedMedia(data, isVideo: isVideo, forSlot: index) }
                    }
                },
                onCancel: { showCameraPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: activeSlotKind == "video" ? [.movie] : [.image]
        ) { result in
            guard case .success(let url) = result, let index = activeSlotIndex else { return }
            Task { await handleImportedFile(url, forSlot: index) }
        }
        .confirmationDialog(
            "This video is longer than 30 seconds",
            isPresented: Binding(
                get: { pendingTrim != nil },
                set: { if !$0 { cancelTrim() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use first 30 seconds") { confirmTrim() }
            Button("Cancel", role: .cancel) { cancelTrim() }
        } message: {
            Text("Only the first 30 seconds of this video will be used.")
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

    // MARK: - Slots

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array((preset.inputSchema?.slots ?? []).enumerated()), id: \.offset) { index, slot in
                VStack(alignment: .leading, spacing: 8) {
                    Text(slot.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    slotTile(index: index, slot: slot)
                }
            }
        }
    }

    private func slotTile(index: Int, slot: PresetSlot) -> some View {
        let input = index < slotInputs.count ? slotInputs[index] : nil

        return Menu {
            Button {
                activeSlotIndex = index
                showPhotosPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    activeSlotIndex = index
                    showCameraPicker = true
                } label: {
                    Label(slot.kind == "video" ? "Record Video" : "Take Photo", systemImage: "camera")
                }
            }
            Button {
                activeSlotIndex = index
                showFileImporter = true
            } label: {
                Label("Choose File", systemImage: "folder")
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.surfaceBorder, lineWidth: 1)
                    )

                if let thumbnail = input?.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .topTrailing) {
                            if slot.kind == "video", let duration = input?.durationSeconds {
                                Text(durationLabel(duration))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.55), in: Capsule())
                                    .padding(8)
                            }
                        }
                } else if input?.isUploading == true {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: theme.textPrimary))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: slot.kind == "video" ? "video.badge.plus" : "photo.badge.plus")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        Text("Tap to add")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }
            .frame(height: 160)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableButtonStyle())
        // Hit-test containment pattern for scaledToFill media (documented project landmine).
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var activeSlotKind: String? {
        guard let activeSlotIndex,
              let slots = preset.inputSchema?.slots,
              activeSlotIndex < slots.count else { return nil }
        return slots[activeSlotIndex].kind
    }

    // MARK: - Optional text

    @ViewBuilder
    private var textSection: some View {
        if let textSchema = preset.inputSchema?.text {
            VStack(alignment: .leading, spacing: 8) {
                Text(textSchema.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                // Plain SwiftUI TextField — not the composer's custom highlighting text view.
                TextField("", text: $text, prompt: Text(textSchema.label).foregroundStyle(theme.textTertiary), axis: .vertical)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(theme.surfaceBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Optional style grid

    @ViewBuilder
    private var styleGridSection: some View {
        if let styles = preset.inputSchema?.styleGrid, !styles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                    ForEach(styles, id: \.id) { style in
                        Button {
                            selectedStyleId = (selectedStyleId == style.id) ? nil : style.id
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(theme.surface)
                                    .frame(height: 72)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(
                                                selectedStyleId == style.id ? theme.textPrimary : theme.surfaceBorder,
                                                lineWidth: selectedStyleId == style.id ? 2 : 1
                                            )
                                    )
                                Text(style.label)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: - Generate bar

    private var generateBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.545, green: 0.427, blue: 0.839))
                Text("\(displayCost)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(theme.textPrimary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayCost)
                Text("credits")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()

            Button {
                Task { await generate() }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Generate")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(width: 120, height: 44)
                .foregroundStyle(.white)
                .background(
                    (isValid && !isSubmitting) ? Color(red: 0.545, green: 0.427, blue: 0.839) : theme.surfaceStrong,
                    in: Capsule()
                )
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isValid || isSubmitting)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Cost (D-18)

    /// Live credit cost shown before Generate. Flat presets read the registry's static cost.
    /// Per-second presets (Motion Transfer) compute from the picked video's REAL duration,
    /// capped at the registry's `max_seconds` (D-16/D-17) if the user confirmed the trim.
    /// Motion Transfer (media_type == "avatar") reads the authoritative live rate parsed from
    /// GET /rates by RatesManager (Plan 05, D-18) rather than the registry's own snapshot value,
    /// since RatesManager is the single live source of truth the composer itself already uses.
    private var displayCost: Int {
        guard let cost = preset.cost else { return 0 }
        switch cost {
        case .flat(let credits):
            return credits
        case .perSecond(let creditsPerSec, let maxSeconds):
            let rawSeconds = videoSlotDurationSeconds ?? 0
            let cappedSeconds = maxSeconds.map { min(rawSeconds, Double($0)) } ?? rawSeconds
            if preset.mediaType == "avatar" {
                return Int(ceil(cappedSeconds * ratesManager.dreamactorRate))
            }
            return Int(ceil(cappedSeconds * creditsPerSec))
        }
    }

    private var videoSlotDurationSeconds: Double? {
        guard let slots = preset.inputSchema?.slots else { return nil }
        for (index, slot) in slots.enumerated() where slot.kind == "video" {
            if index < slotInputs.count, let duration = slotInputs[index]?.durationSeconds {
                return duration
            }
        }
        return nil
    }

    /// The registry's per-second cap (Motion Transfer's 30s driving-video cap, D-16) — generic
    /// over any future per-second preset that declares `max_seconds`, not hardcoded to 30.
    private var capSecondsForActiveSlot: Double? {
        guard case .perSecond(_, let maxSeconds)? = preset.cost, let maxSeconds else { return nil }
        return Double(maxSeconds)
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard let schema = preset.inputSchema else { return false }
        for index in schema.slots.indices {
            guard index < slotInputs.count,
                  let input = slotInputs[index],
                  input.uploadId != nil,
                  !input.isUploading else { return false }
        }
        if let textSchema = schema.text, textSchema.required,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    // MARK: - Slot media handlers

    private func handlePhotosPickerSelection(_ item: PhotosPickerItem?) async {
        guard let item, let index = activeSlotIndex else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isVideo = item.supportedContentTypes.contains(.movie) || item.supportedContentTypes.contains(.mpeg4Movie)
        await handlePickedMedia(data, isVideo: isVideo, forSlot: index)
        selectedPickerItem = nil
    }

    private func handleImportedFile(_ url: URL, forSlot index: Int) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let isVideo = contentType?.conforms(to: .movie) ?? false
        await handlePickedMedia(data, isVideo: isVideo, forSlot: index)
    }

    /// Shared entry point for all three slot-picker sources (Photos / Camera / Files, D-19).
    private func handlePickedMedia(_ data: Data, isVideo: Bool, forSlot index: Int) async {
        guard let slots = preset.inputSchema?.slots, index < slots.count else { return }
        while slotInputs.count <= index { slotInputs.append(nil) }
        slotInputs[index] = PresetSlotInput(isUploading: true)

        if isVideo {
            guard let written = try? await PresetMediaPrep.shared.writeAndProbeDuration(data) else {
                slotInputs[index] = nil
                errorMessage = "Couldn't read the selected video. Try a different file."
                return
            }

            if let cap = capSecondsForActiveSlot, written.durationSeconds > cap {
                // D-17: don't reject — ask the user to confirm the first-30s trim before we
                // spend CPU re-encoding. Slot stays in its "uploading" placeholder state until
                // confirm/cancel resolves it.
                pendingTrim = PendingVideoTrim(
                    slotIndex: index,
                    url: written.url,
                    fallbackData: data,
                    durationSeconds: written.durationSeconds
                )
                return
            }

            await finishVideoSlot(
                index: index,
                url: written.url,
                fallbackData: data,
                billedDuration: written.durationSeconds,
                capSeconds: nil
            )
        } else {
            let thumbnail = UIImage(data: data)
            guard let response = try? await APIClient.shared.uploadReferenceMedia(
                data: data, mimeType: "image/jpeg", fileName: "preset-input.jpg"
            ) else {
                slotInputs[index] = nil
                errorMessage = "Couldn't upload this image. Try again."
                return
            }
            slotInputs[index] = PresetSlotInput(
                uploadId: response.id,
                url: response.url,
                thumbnail: thumbnail,
                isUploading: false,
                durationSeconds: nil
            )
        }
    }

    private func finishVideoSlot(index: Int, url: URL, fallbackData: Data, billedDuration: Double, capSeconds: Double?) async {
        let prepared = await PresetMediaPrep.shared.prepareVideo(url: url, fallbackData: fallbackData, capSeconds: capSeconds)
        guard let response = try? await APIClient.shared.uploadReferenceMedia(
            data: prepared.data, mimeType: "video/mp4", fileName: "preset-input.mp4"
        ) else {
            slotInputs[index] = nil
            errorMessage = "Couldn't upload this video — it may be too large. Try a shorter or lower-resolution clip."
            return
        }
        slotInputs[index] = PresetSlotInput(
            uploadId: response.id,
            url: response.url,
            thumbnail: prepared.thumbnail,
            isUploading: false,
            durationSeconds: capSeconds ?? billedDuration
        )
    }

    private func confirmTrim() {
        guard let pending = pendingTrim else { return }
        pendingTrim = nil
        Task {
            await finishVideoSlot(
                index: pending.slotIndex,
                url: pending.url,
                fallbackData: pending.fallbackData,
                billedDuration: pending.durationSeconds,
                capSeconds: capSecondsForActiveSlot ?? 30
            )
        }
    }

    private func cancelTrim() {
        guard let pending = pendingTrim else { return }
        slotInputs[pending.slotIndex] = nil
        pendingTrim = nil
    }

    // MARK: - Generate (D-10/D-11)

    private func generate() async {
        guard isValid, let schema = preset.inputSchema else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        let uploadIds: [String] = schema.slots.indices.compactMap { index in
            index < slotInputs.count ? slotInputs[index]?.uploadId : nil
        }

        // D-11: the client never constructs or sends the expanded template — only preset_id +
        // the slot upload ids. The server's presetResolver middleware owns prompt/model/media_type.
        let body = GenerationRequestBody(
            prompt: "",
            model: preset.model ?? "",
            mediaType: preset.mediaType,
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
            presetId: preset.presetId,
            presetInputUploadIds: uploadIds.isEmpty ? nil : uploadIds
        )

        // Optimistic UI (mirrors GenerateView.dispatchGeneration): drop a pending placeholder
        // into GenerationManager immediately — the run then rides the existing pending-card
        // machinery (polling, GenerationCardView) in the Generate feed (D-11), no tab switch.
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: preset.model ?? "",
            mediaType: (preset.mediaType == "image") ? .image : .video,
            prompt: nil,
            params: GenerationParams(
                resolution: nil,
                duration: nil,
                aspectRatio: nil,
                audioEnabled: nil,
                hasReference: uploadIds.isEmpty ? nil : true,
                width: nil,
                height: nil
            ),
            costCredits: displayCost,
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

// MARK: - Slot input state

/// Per-slot fill state. Public (not private) so a future Remix flow (Plan 08) can construct
/// `prefillSlots` from a stored generation's `preset_input_upload_ids` + re-signed URLs.
struct PresetSlotInput {
    var uploadId: String?
    var url: String?
    var thumbnail: UIImage?
    var isUploading: Bool = false
    var durationSeconds: Double?   // video slots only — real AVAsset duration (D-18)
}

private struct PendingVideoTrim {
    let slotIndex: Int
    let url: URL
    let fallbackData: Data
    let durationSeconds: Double
}

// MARK: - Off-main-actor media prep (mirrors MediaPrepService.swift's shape)
//
// A separate small actor rather than an edit to MediaPrepService.swift, which is out of this
// plan's touched-file scope (per orchestrator instructions, only PresetInputSheet.swift +
// APIClient.swift are committed by this plan). Same rationale as that file's own doc comment:
// SwiftUI's `View` protocol infers @MainActor on this struct's methods, so file I/O / duration
// probing / HEVC transcode / thumbnail extraction must happen inside a plain (non-MainActor)
// actor to avoid stuttering the UI while a slot uploads.
private actor PresetMediaPrep {
    static let shared = PresetMediaPrep()

    struct WrittenVideo {
        let url: URL
        let durationSeconds: Double
    }

    func writeAndProbeDuration(_ data: Data) async throws -> WrittenVideo {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
        try data.write(to: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        return WrittenVideo(url: url, durationSeconds: duration)
    }

    struct PreparedVideo {
        let data: Data
        let thumbnail: UIImage?
    }

    /// Optionally trims to the first `capSeconds` (D-16/D-17 confirmed trim), transcodes
    /// HEVC→H.264 if needed, and extracts a poster thumbnail.
    func prepareVideo(url: URL, fallbackData: Data, capSeconds: Double?) async -> PreparedVideo {
        var workingURL = url
        if let capSeconds {
            workingURL = (try? await Self.trim(url: url, toSeconds: capSeconds)) ?? url
        }
        workingURL = (try? await Self.transcodeToH264IfNeeded(url: workingURL)) ?? workingURL
        let finalData = (try? Data(contentsOf: workingURL)) ?? fallbackData
        let thumbnail = Self.extractThumbnail(from: workingURL)
        return PreparedVideo(data: finalData, thumbnail: thumbnail)
    }

    private static func extractThumbnail(from url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init)
    }

    private static func trim(url: URL, toSeconds seconds: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let cap = CMTime(seconds: seconds, preferredTimescale: 600)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return url
        }
        session.outputURL = tmpURL
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, cap))
        try await session.exportAsync()
        return tmpURL
    }

    private static func transcodeToH264IfNeeded(url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { return url }
        let descs = try await track.load(.formatDescriptions)
        let isHEVC = descs.contains {
            CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) == kCMVideoCodecType_HEVC
        }
        guard isHEVC else { return url }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "PresetMediaPrep", code: -1)
        }
        session.outputURL = tmpURL
        session.outputFileType = .mp4
        try await session.exportAsync()
        return tmpURL
    }
}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: self.error ?? NSError(domain: "AVExport", code: -1))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: NSError(domain: "AVExport", code: -1))
                }
            }
        }
    }
}
