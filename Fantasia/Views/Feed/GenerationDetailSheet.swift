// GenerationDetailSheet.swift
// Fantasia
// Bottom sheet with full image/video preview, metadata, and generation actions.
// Opened from Feed card prompt tap, Library thumbnail tap, or GenerateView card detail.

import SwiftUI
import Photos
import AVFoundation

struct GenerationDetailSheet: View {
    let item: GenerationItem
    @Binding var isPresented: Bool
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme

    @State private var showPlayer = false
    @State private var showShare = false
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isPreparingShare = false
    @State private var saveError: String? = nil
    @State private var shareError: String? = nil
    @State private var isReporting = false
    @State private var tmpShareUrl: URL? = nil
    @State private var thumbnail: UIImage? = nil
    @State private var cachedImage: UIImage? = nil

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
                        .contextMenu { nameAsReferenceMenuItem }
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
                        .contextMenu { nameAsReferenceMenuItem }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        paramRow("Model", value: ModelCatalog.displayName(for: item.model))
                        if item.isImage {
                            if let w = item.params.width, let h = item.params.height {
                                paramRow("Resolution", value: "\(w) × \(h)")
                            }
                            paramRow("Aspect Ratio", value: item.params.aspectRatio ?? "—")
                        } else {
                            paramRow("Resolution", value: item.params.resolution ?? "—")
                            paramRow("Duration", value: item.params.duration.map { "\($0)s" } ?? "—")
                            paramRow("Aspect Ratio", value: item.params.aspectRatio ?? "—")
                            paramRow("Audio", value: (item.params.audioEnabled ?? true) ? "On" : "Off")
                        }
                        if item.costCredits > 0 {
                            paramRow("Credits used", value: "\(item.costCredits)")
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
                        VStack(spacing: 10) {
                            // Remix + Regenerate + Reference row
                            HStack(spacing: 10) {
                                actionButton("arrow.2.squarepath", "Remix", role: .normal) {
                                    handleRemix()
                                }
                                actionButton("arrow.clockwise", "Regen", role: .normal) {
                                    handleRegenerate()
                                }
                                actionButton("paperclip", "Reference", role: .normal) {
                                    handleReference()
                                }
                            }

                            // Download (image or video)
                            if let urlString = item.isImage ? item.completedMediaUrl : item.videoUrl {
                                Button {
                                    Task { await saveToPhotos(urlString: urlString) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSaving ? "clock" : "arrow.down.to.line")
                                        Text(isSaving ? "Saving..." : "Save to Photos")
                                            .font(.body.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .background(accent, in: RoundedRectangle(cornerRadius: 12))
                                    .foregroundStyle(.white)
                                }
                                .disabled(isSaving)
                            }

                            // Share
                            if let urlString = item.completedMediaUrl {
                                Button {
                                    Task { await prepareAndShare(urlString: urlString) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isPreparingShare ? "clock" : "square.and.arrow.up")
                                        Text(isPreparingShare ? "Preparing…" : "Share")
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
                                    .foregroundStyle(theme.textPrimary)
                                }
                                .disabled(isPreparingShare)
                            }

                            // Delete
                            actionButton("trash", "Delete", role: .destructive) {
                                showDeleteAlert = true
                            }

                            // Report
                            Button {
                                Task { await reportGeneration() }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "flag")
                                    Text(isReporting ? "Reported" : "Report")
                                }
                                .frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(isReporting ? .secondary : Color.red.opacity(0.8))
                            }
                            .disabled(isReporting)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url, generationId: item.id)
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = tmpShareUrl {
                ActivityViewController(activityItems: [url])
                    .presentationDetents([.medium])
                    .ignoresSafeArea()
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
        .nameAsReferenceAlert()
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Action helpers

    private enum ButtonRole { case normal, destructive }

    @ViewBuilder
    private func actionButton(_ icon: String, _ label: String, role: ButtonRole, action: @escaping () -> Void) -> some View {
        let fg: Color = role == .destructive ? .red.opacity(0.85) : theme.textPrimary.opacity(0.8)
        let bg: Color = role == .destructive ? .red.opacity(0.08) : theme.surface
        let border: Color = role == .destructive ? .red.opacity(0.2) : theme.surfaceBorder

        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium))
                Text(label).font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(bg, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
    }

    @ViewBuilder
    private var nameAsReferenceMenuItem: some View {
        if item.status == .completed {
            Button("Name as reference", systemImage: "tag") {
                generationManager.pendingNameAsReference = item
            }
        }
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
        if let cached = await ThumbnailCache.shared.image(for: item.id) { cachedImage = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        ThumbnailCache.shared[item.id] = image
        cachedImage = image
    }

    private func paramRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            Spacer()
            Text(value).foregroundStyle(.primary).font(.subheadline.weight(.medium))
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
            tmpShareUrl = destUrl
            showShare = true
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
