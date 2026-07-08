// GenerationDetailSheet.swift
// Fantasia
// Bottom sheet with full image/video preview, metadata, and generation actions.
// Opened from Feed card prompt tap, Library thumbnail tap, or GenerateView card detail.

import SwiftUI
import UIKit
import Photos
import AVFoundation

struct GenerationDetailSheet: View {
    let item: GenerationItem
    @Binding var isPresented: Bool
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme
    @Environment(RatesManager.self) private var ratesManager
    @Environment(CreditManager.self) private var creditManager

    @State private var showPlayer = false
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isPreparingShare = false
    @State private var saveError: String? = nil
    @State private var showSavedToast = false
    @State private var shareError: String? = nil
    @State private var isReporting = false
    @State private var thumbnail: UIImage? = nil
    @State private var cachedImage: UIImage? = nil
    @State private var isFavorite: Bool = false
    // Generic Animate action (09.1-12): turns any completed IMAGE generation into a short video
    // via bytedance/seedance-2.0-mini, using the completed image itself as the reference.
    @State private var showAnimateConfirm = false
    @State private var isAnimating = false
    @State private var animateError: String? = nil
    // Magic Editor entry point (09.2-10, SC4): "Edit" opens MaskEditorView on this image's
    // completed media URL. Bool + stored URL (not fullScreenCover(item:)) since the source is a
    // plain String, not an Identifiable model.
    @State private var editSourceURLString: String?
    @State private var showMaskEditor = false

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 4)

                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Full image/video preview
                    if item.isImage {
                        Group {
                            if let img = cachedImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                            } else {
                                theme.surface
                                    .frame(height: 220)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { showPlayer = true }
                        .task { await loadCachedImage() }
                    } else if let urlString = item.videoUrl, let videoUrl = URL(string: urlString) {
                        ZStack {
                            Group {
                                if let thumb = thumbnail {
                                    Image(uiImage: thumb)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    theme.surface
                                        .frame(height: 220)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { showPlayer = true }
                        .task { await generateThumbnail(from: videoUrl) }
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.surface)
                            .frame(minHeight: 120)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: item.status == .failed ? "exclamationmark.triangle" : "clock")
                                        .font(.system(size: 28))
                                        .foregroundStyle(item.status == .failed ? .orange : .secondary)
                                    if let message = item.failureMessage {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 20)
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                    }

                    // Full prompt text
                    if let prompt = item.prompt, !prompt.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prompt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(prompt)
                                .font(.body)
                                .foregroundStyle(.primary)
                        }
                    }

                    // Parameters
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Parameters")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        // T18: paramRow draws its own trailing hairline; the last visible row
                        // (Credits used when present, else the last param in its branch) passes
                        // showDivider: false so no line dangles after the final row.
                        let hasCredits = item.costCredits > 0
                        VStack(alignment: .leading, spacing: 0) {
                            paramRow("Model", value: ModelCatalog.displayName(for: item.model))
                            if item.isImage {
                                if let w = item.params.width, let h = item.params.height {
                                    paramRow("Resolution", value: "\(w) × \(h)")
                                }
                                paramRow("Aspect Ratio", value: item.params.aspectRatio ?? "—", showDivider: hasCredits)
                            } else {
                                paramRow("Resolution", value: item.params.resolution ?? "—")
                                paramRow("Duration", value: item.params.duration.map { "\($0)s" } ?? "—")
                                paramRow("Aspect Ratio", value: item.params.aspectRatio ?? "—")
                                paramRow("Audio", value: (item.params.audioEnabled ?? true) ? "On" : "Off", showDivider: hasCredits)
                            }
                            if hasCredits {
                                paramRow("Credits used", value: "\(item.costCredits)", showDivider: false)
                            }
                        }
                    }
                    .padding(12)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))

                    if item.status == .completed {
                        Text("Generated \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Actions
                    if item.status == .completed {
                        VStack(spacing: 14) {
                            // Remix + Regenerate + Reference (+ Animate for images) + Favorite row
                            HStack(spacing: 20) {
                                circleActionButton("arrow.2.squarepath", "Remix") {
                                    handleRemix()
                                }
                                circleActionButton("arrow.clockwise", "Regen") {
                                    handleRegenerate()
                                }
                                circleActionButton("paperclip", "Reference") {
                                    handleReference()
                                }
                                if item.isImage {
                                    circleActionButton(isAnimating ? "hourglass" : "wand.and.stars", "Animate") {
                                        showAnimateConfirm = true
                                    }
                                    .disabled(isAnimating)
                                }
                                // Magic Editor (09.2-10, SC4): image items only, deliberately not
                                // on every feed card (Home "Magic Editor" card is the other entry).
                                if item.isImage, let src = item.completedMediaUrl {
                                    circleActionButton("paintbrush.pointed", "Edit") {
                                        editSourceURLString = src
                                        showMaskEditor = true
                                    }
                                }
                                circleActionButton(isFavorite ? "heart.fill" : "heart", isFavorite ? "Favorited" : "Favorite") {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    isFavorite.toggle()                      // optimistic local icon flip
                                    let target = isFavorite
                                    Task {
                                        await generationManager.setFavorite(id: item.id, isFavorite: target)
                                        if let updated = generationManager.generations.first(where: { $0.id == item.id }) {
                                            isFavorite = updated.isFavorite
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)

                            // Download (image or video) — primary CTA
                            if let urlString = item.isImage ? item.completedMediaUrl : item.videoUrl {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { await saveToPhotos(urlString: urlString) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSaving ? "clock" : "arrow.down.to.line")
                                        Text(isSaving ? "Saving..." : "Save to Photos")
                                            .font(.body.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .foregroundStyle(.white)
                                    .background(
                                        LinearGradient(
                                            colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                                                     Color(red: 0.357, green: 0.561, blue: 0.851)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                                    .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .disabled(isSaving)
                            }

                            // Share — secondary
                            if let urlString = item.completedMediaUrl {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { await prepareAndShare(urlString: urlString) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isPreparingShare ? "clock" : "square.and.arrow.up")
                                        Text(isPreparingShare ? "Preparing…" : "Share")
                                            .font(.body.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .foregroundStyle(theme.textPrimary)
                                    // theme.surfaceStrong instead of .ultraThinMaterial — the
                                    // material is nearly invisible on the light background, so
                                    // this didn't read as a button in light mode.
                                    .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 0.5))
                                }
                                .buttonStyle(PressableButtonStyle())
                                .disabled(isPreparingShare)
                            }

                            // Delete — quiet destructive text row
                            Button {
                                showDeleteAlert = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "trash").font(.system(size: 15, weight: .medium))
                                    Text("Delete").font(.subheadline)
                                }
                                .foregroundStyle(Color.red.opacity(0.85))
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .background(Color.red.opacity(theme.isLight ? 0.07 : 0.10), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.12), lineWidth: 0.5))
                            }
                            .buttonStyle(PressableButtonStyle())
                            .disabled(isDeleting)

                            // Report — small, low-emphasis flag beneath Delete (no button chrome)
                            Button {
                                Task { await reportGeneration() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "flag").font(.caption2)
                                    Text(isReporting ? "Reported" : "Report an issue").font(.caption)
                                }
                                .foregroundStyle(theme.textSecondary.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .disabled(isReporting)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved to Photos").font(.subheadline.weight(.medium)).foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 0.5))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url, generationId: item.id)
            }
        }
        // Magic Editor (09.2-10, SC4) — "Edit" action above.
        .fullScreenCover(isPresented: $showMaskEditor) {
            if let urlString = editSourceURLString {
                MaskEditorView(source: .url(urlString))
                    .environment(generationManager)
                    .environment(creditManager)
                    .environment(theme)
            }
        }
        .alert("Delete this \(item.isImage ? "image" : "video")?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { Task { await handleDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Save Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("Share Failed", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
        .confirmationDialog(
            "Animate this photo?",
            isPresented: $showAnimateConfirm,
            titleVisibility: .visible
        ) {
            Button("Animate for \(animateCostCredits) credits") { Task { await handleAnimate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds gentle, natural motion to this image and creates a new \(animateDurationSeconds)s video.")
        }
        .alert("Couldn't Animate", isPresented: Binding(
            get: { animateError != nil },
            set: { if !$0 { animateError = nil } }
        )) {
            Button("OK", role: .cancel) { animateError = nil }
        } message: {
            Text(animateError ?? "")
        }
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { isFavorite = item.isFavorite }
    }

    // MARK: - Action helpers

    @ViewBuilder
    private func circleActionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 54, height: 54)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(theme.surfaceBorder, lineWidth: 0.5))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Generation actions

    private func handleRemix() {
        generationManager.pendingRemix = item
        NotificationCenter.default.post(name: .remixGenerationRequested, object: nil)
        isPresented = false
    }

    private func handleRegenerate() {
        // Pre-fill Generate tab with same settings; user can submit immediately or tweak
        generationManager.pendingRemix = item
        NotificationCenter.default.post(name: .remixGenerationRequested, object: nil)
        isPresented = false
    }

    // Attach this generation's own output as a reference input on the Generate tab.
    private func handleReference() {
        generationManager.pendingReference = item
        NotificationCenter.default.post(name: .referenceGenerationRequested, object: nil)
        isPresented = false
    }

    // Generic Animate action (09.1-12): turns any completed image into a short video via
    // bytedance/seedance-2.0-mini, same model/duration/prompt style as the Animate Old Photo
    // preset — but works on ANY completed image, not just a fresh upload, since it references
    // this generation's own output directly (reference_image_generation_ids) instead of routing
    // through a preset/upload flow. Fixed 5s duration matches Animate Old Photo's max_seconds cap.
    private let animateModel = "bytedance/seedance-2.0-mini"
    private let animateDurationSeconds = 5
    private let animatePrompt =
        "Bring this photo to life with subtle, natural motion — gentle breathing, slight head " +
        "movement, soft ambient background motion — keep the look and colors intact, no audio."

    private var animateCostCredits: Int {
        ratesManager.cost(model: animateModel, durationSeconds: animateDurationSeconds, resolution: "720p", hasVideoReference: false)
    }

    private func handleAnimate() async {
        guard !isAnimating, let sourceUrl = item.completedMediaUrl else { return }
        isAnimating = true
        defer { isAnimating = false }

        let body = GenerationRequestBody(
            prompt: animatePrompt,
            model: animateModel,
            mediaType: "video",
            duration: animateDurationSeconds,
            resolution: "720p",
            aspectRatio: nil,
            audioEnabled: false,
            imageAspectRatio: nil,
            imageQuality: nil,
            referenceImages: [sourceUrl],
            referenceVideos: nil,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: [item.id],
            referenceVideoGenerationIds: nil
        )

        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: animateModel,
            mediaType: .video,
            prompt: animatePrompt,
            params: GenerationParams(
                resolution: "720p",
                duration: animateDurationSeconds,
                aspectRatio: nil,
                audioEnabled: false,
                hasReference: true,
                width: nil,
                height: nil
            ),
            costCredits: animateCostCredits,
            referenceUrls: [GenerationReference(url: sourceUrl, isVideo: false)],
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            generationManager.removeLocalPlaceholder(id: placeholderId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                animateError = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                animateError = "This may not adhere to our community guidelines. Please try again."
            } else {
                animateError = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            animateError = "An error has occurred. Please try again."
        }
    }

    private func handleDelete() async {
        isDeleting = true
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
            isPresented = false
        } catch {
            print("[GenerationDetailSheet] delete error: \(error)")
        }
        isDeleting = false
    }

    // MARK: - Helpers

    private func loadCachedImage() async {
        guard item.isImage, let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        // T20: seed instantly from the already-downscaled grid thumbnail (LibraryThumbnailView's
        // "-grid" cache key), if present, for an instant first paint while the full-res copy
        // loads — instead of a blank/spinner state during sheet presentation.
        if cachedImage == nil, let gridThumb = await ThumbnailCache.shared.image(for: item.id + "-grid") {
            cachedImage = gridThumb
        }
        if let cached = await ThumbnailCache.shared.image(for: item.id) { cachedImage = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        // Perf: UIImage(data:) only decodes lazily on first draw — that decode used to happen
        // on the render path during sheet-presentation animation, which could stall the main
        // thread long enough to eat the initial swipe-to-dismiss touch (T20).
        let prepared = await image.byPreparingForDisplay() ?? image
        ThumbnailCache.shared[item.id] = prepared
        cachedImage = prepared
    }

    private func paramRow(_ label: String, value: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                Text(value).foregroundStyle(.primary).font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 9)
            if showDivider {
                Rectangle().fill(theme.divider).frame(height: 0.5)
            }
        }
    }

    private func saveToPhotos(urlString: String) async {
        guard let mediaUrl = URL(string: urlString) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let (tmpUrl, _) = try await URLSession.shared.download(from: mediaUrl)
            let ext = item.isImage ? (mediaUrl.pathExtension.isEmpty ? "jpg" : mediaUrl.pathExtension) : "mp4"
            let destUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(item.id).\(ext)")
            try? FileManager.default.removeItem(at: destUrl)
            try FileManager.default.moveItem(at: tmpUrl, to: destUrl)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "Photo library access denied. Allow access in Settings."
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                if self.item.isImage {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: destUrl)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destUrl)
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.3)) { showSavedToast = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSavedToast = false }
            }
        } catch {
            saveError = "Could not save \(item.isImage ? "image" : "video"): \(error.localizedDescription)"
        }
    }

    private func prepareAndShare(urlString: String) async {
        guard !isPreparingShare, let mediaUrl = URL(string: urlString) else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        let ext = item.isImage ? (mediaUrl.pathExtension.isEmpty ? "jpg" : mediaUrl.pathExtension) : "mp4"
        let destUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantasia-\(item.isImage ? "image" : "video").\(ext)")
        do {
            try? FileManager.default.removeItem(at: destUrl)
            if item.isImage {
                // No image cache today — download straight from the presigned URL, then move
                // (not copy) the disposable temp download into the share path.
                let (tmpUrl, _) = try await URLSession.shared.download(from: mediaUrl)
                try FileManager.default.moveItem(at: tmpUrl, to: destUrl)
            } else {
                // VideoCache is usually already warm (player/thumbnail generation prefetch it) —
                // this avoids re-downloading the whole video just to share it, and only hits the
                // network on a genuine cache miss. Copy (not move) since the cache still owns it.
                let cachedUrl = try await VideoCache.shared.ensureCached(id: item.id, remoteURL: mediaUrl)
                try FileManager.default.copyItem(at: cachedUrl, to: destUrl)
            }
            // Presented natively via UIKit (not a SwiftUI .sheet) — see presentActivityViewController
            // for why: SwiftUI's sheet sizing either forces full-height or collapses the app-icon
            // grid to "More" under .presentationDetents([.medium]).
            presentActivityViewController(items: [
                ShareableMedia(url: destUrl, isVideo: !item.isImage, thumbnail: thumbnail ?? cachedImage)
            ])
        } catch {
            print("[GenerationDetailSheet] share prepare error: \(error)")
            shareError = "Could not prepare \(item.isImage ? "image" : "video") for sharing: \(error.localizedDescription)"
        }
    }

    private func generateThumbnail(from url: URL) async {
        // Use the cached local file if this generation's video is already on disk (VideoCache
        // is keyed by generation ID, not URL — presigned R2 URLs rotate on every fetch) so this
        // doesn't re-download over the network just to grab a frame. If not cached yet, warm the
        // cache in the background so the full-screen player opened from here is instant too.
        guard let cachedURL = VideoCache.shared.cachedURL(for: item.id) else {
            VideoCache.shared.prefetch(id: item.id, remoteURL: url)
            return await generateThumbnail(from: url, source: url)
        }
        return await generateThumbnail(from: url, source: cachedURL)
    }

    private func generateThumbnail(from url: URL, source: URL) async {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            thumbnail = UIImage(cgImage: cgImage)
        } catch {
            print("[GenerationDetailSheet] thumbnail error: \(error)")
        }
    }

    private func reportGeneration() async {
        guard !isReporting else { return }
        do {
            let body = try JSONEncoder().encode(["generation_id": item.id])
            try await APIClient.shared.authorizedRequestNoContent(path: "api/reports", method: "POST", body: body)
            isReporting = true
        } catch {
            print("[GenerationDetailSheet] report error: \(error)")
        }
    }
}
