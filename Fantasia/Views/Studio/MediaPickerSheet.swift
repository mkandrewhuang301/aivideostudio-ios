// MediaPickerSheet.swift
// Fantasia
// Phase 13, Plan 10: the shared "Add Media" picker (D-08/D-09) — a segmented Generations/Uploads
// sheet reused VERBATIM at both the Studio hub "+" (new project, plan 09) and the in-editor
// timeline "+" (append clip, plan 12). Returns the ordered picked items to its caller via
// `onAdd`; the CALLER performs the actual import network calls (createProject /
// importClipFromGeneration / uploadClip on ProjectManager, plan 08) — this sheet has zero
// backend-mutation awareness of its own, beyond MediaPrepService's local HEVC transcode for the
// Uploads tab (D-08's deliberate deviation from the sketch's generations-only picker).
//
// 13-UI-SPEC.md "Media Picker" section: native Picker(.segmented) accent-purple tint, 2 tabs.
// Generations = 3-col 9:16 grid sourced from GenerationManager, duration badge bottom-right,
// checkmark + accent-outline overlay on pick, multi-select. Uploads = native PhotosPicker
// (photo/video) + Files document picker, HEVC-transcoded via MediaPrepService exactly like the
// existing upload flow elsewhere in the app (PresetInputSheet's slot pickers). CTA "Add {N}"
// disabled/gray at N=0, accent-filled at N>=1.

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Shared accent purple reserved for this phase's primary CTAs (13-UI-SPEC Color contract) —
/// same literal already used elsewhere in the app (GenerationCardView, PresetInputSheet).
private let studioAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

/// One picked media item, in the order the user picked it. The caller resolves this into the
/// actual import call:
///   `.generation` → `ProjectManager.importClip(generationId:)` / `createProject(firstClipGenerationId:)`
///   `.upload`     → `ProjectManager.uploadClip(fileURL:mediaType:)` / `createProject(firstClipUploadURL:)`
/// `.upload`'s `url` always points at a LOCAL file (already HEVC→H.264 transcoded for video by
/// MediaPrepService below) — never a remote URL.
enum PickedMedia: Identifiable, Equatable {
    case generation(id: String, mediaType: String)
    case upload(url: URL, mediaType: String)

    var id: String {
        switch self {
        case .generation(let id, _): return "generation-\(id)"
        case .upload(let url, _): return "upload-\(url.absoluteString)"
        }
    }

    var mediaType: String {
        switch self {
        case .generation(_, let mediaType): return mediaType
        case .upload(_, let mediaType): return mediaType
        }
    }
}

struct MediaPickerSheet: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(\.dismiss) private var dismiss

    /// Fires once, with the full ordered selection, when the user taps "Add {N}" — the sheet
    /// dismisses itself immediately after. The caller performs the actual import network calls.
    var onAdd: ([PickedMedia]) -> Void

    private enum Tab: String, CaseIterable {
        case generations = "Generations"
        case uploads = "Uploads"
    }

    @State private var activeTab: Tab = .generations
    @State private var selected: [PickedMedia] = []

    // Uploads tab state
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isPreparingUpload = false
    @State private var uploadThumbnails: [String: UIImage] = [:]  // keyed by PickedMedia.id

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                Picker("", selection: $activeTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .tint(studioAccent)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                switch activeTab {
                case .generations: generationsTab
                case .uploads: uploadsTab
                }

                addButton
            }
            .background(theme.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .task {
            // One-shot staleness check (mirrors PresetInputSheet's "Add media" sheet) — not
            // startPolling(), which starts a recurring fetch loop that fights with this sheet's
            // own lifecycle.
            await generationManager.refreshIfStale()
        }
        .onChange(of: photosPickerItem) { _, newValue in
            Task { await handlePhotosPickerSelection(newValue) }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .image]
        ) { result in
            Task { await handleImportedFile(result) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Add Media")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Pick from your generations or upload from your device.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
    }

    // MARK: - Generations tab

    private var eligibleGenerations: [GenerationItem] {
        generationManager.generations.filter { $0.status == .completed }
    }

    @ViewBuilder
    private var generationsTab: some View {
        if eligibleGenerations.isEmpty {
            emptyGenerationsState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(eligibleGenerations) { item in
                        GenerationPickerTile(
                            item: item,
                            isSelected: isSelected(.generation(id: item.id, mediaType: item.mediaType.rawValue)),
                            onTap: { toggleGeneration(item) }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyGenerationsState: some View {
        VStack(spacing: 8) {
            Text("No generations yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Generate a video or image first, then come back to add it here.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }

    private func toggleGeneration(_ item: GenerationItem) {
        let media = PickedMedia.generation(id: item.id, mediaType: item.mediaType.rawValue)
        if let index = selected.firstIndex(of: media) {
            selected.remove(at: index)
        } else {
            selected.append(media)
        }
    }

    // MARK: - Uploads tab

    private var selectedUploads: [PickedMedia] {
        selected.filter {
            if case .upload = $0 { return true }
            return false
        }
    }

    private var uploadsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                uploadSourceButtons

                if !selectedUploads.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                        spacing: 6
                    ) {
                        ForEach(selectedUploads) { media in
                            UploadPickerTile(
                                thumbnail: uploadThumbnails[media.id],
                                onRemove: { removeUpload(media) }
                            )
                        }
                    }
                }

                if isPreparingUpload {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(studioAccent)
                        Text("Preparing…")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
    }

    private var uploadSourceButtons: some View {
        VStack(spacing: 10) {
            PhotosPicker(selection: $photosPickerItem, matching: .any(of: [.images, .videos])) {
                uploadSourceRow(icon: "photo.on.rectangle", title: "Photos & Videos")
            }
            Button {
                showFileImporter = true
            } label: {
                uploadSourceRow(icon: "folder", title: "Files")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func uploadSourceRow(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(studioAccent)
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Photos-tab entry point (T-13-26): reads the picked item's raw bytes, then hands off to the
    /// shared `appendUpload` prep pipeline below.
    private func handlePhotosPickerSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isVideo = item.supportedContentTypes.contains(.movie) || item.supportedContentTypes.contains(.mpeg4Movie)
        await appendUpload(data: data, isVideo: isVideo)
        photosPickerItem = nil
    }

    /// Files-tab entry point (T-13-26): reads the security-scoped resource's raw bytes, then
    /// hands off to the shared `appendUpload` prep pipeline below.
    private func handleImportedFile(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let isVideo = contentType?.conforms(to: .movie) ?? false
        await appendUpload(data: data, isVideo: isVideo)
    }

    /// Shared Uploads-tab prep pipeline (T-13-26): writes the picked bytes to a temp file, then
    /// — for video — runs `MediaPrepService.shared.prepareForUpload` (HEVC→H.264 transcode +
    /// thumbnail extraction, reused verbatim per the plan's interface note) before appending an
    /// `.upload` `PickedMedia`. Images need no transcode; they're written straight to a temp file
    /// and thumbnailed in-memory.
    private func appendUpload(data: Data, isVideo: Bool) async {
        isPreparingUpload = true
        defer { isPreparingUpload = false }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(isVideo ? "mov" : "jpg")
        do {
            try data.write(to: tmpURL)
        } catch {
            return
        }

        if isVideo {
            let prepared = await MediaPrepService.shared.prepareForUpload(inputURL: tmpURL, fallbackData: data)
            let media = PickedMedia.upload(url: prepared.url, mediaType: "video")
            selected.append(media)
            if let thumbnail = prepared.thumbnail {
                uploadThumbnails[media.id] = thumbnail
            }
        } else {
            let media = PickedMedia.upload(url: tmpURL, mediaType: "image")
            selected.append(media)
            uploadThumbnails[media.id] = UIImage(data: data)
        }
    }

    private func removeUpload(_ media: PickedMedia) {
        selected.removeAll { $0 == media }
        uploadThumbnails[media.id] = nil
    }

    // MARK: - Shared selection state

    private func isSelected(_ media: PickedMedia) -> Bool {
        selected.contains(media)
    }

    // MARK: - Add {N} CTA

    private var addButton: some View {
        Button {
            onAdd(selected)
            dismiss()
        } label: {
            Text("Add \(selected.count)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected.isEmpty ? theme.textTertiary : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    selected.isEmpty ? theme.surface : studioAccent,
                    in: RoundedRectangle(cornerRadius: 14)
                )
        }
        .disabled(selected.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Generations tab tile

/// 9:16 grid tile for the Generations tab — thumbnail via the app's existing ThumbnailCache/
/// VideoCache (mirrors GenerationCardView's caching conventions), duration badge bottom-right
/// (video only), checkmark + accent-outline overlay when selected.
private struct GenerationPickerTile: View {
    let item: GenerationItem
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !item.isImage, let duration = item.params.duration {
                    Text(formattedDuration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(studioAccent, .white)
                        .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? studioAccent : .clear, lineWidth: 2)
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        if item.isImage {
            guard let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
            let cacheKey = item.id + "-picker"
            if let cached = await ThumbnailCache.shared.image(for: cacheKey) { thumbnail = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let thumb = image.preparingThumbnail(of: CGSize(width: 300, height: 300)) ?? image
            ThumbnailCache.shared[cacheKey] = thumb
            thumbnail = thumb
        } else {
            guard let urlString = item.videoUrl, let url = URL(string: urlString) else { return }
            if let cached = await ThumbnailCache.shared.image(for: item.id) { thumbnail = cached; return }
            let localURL = VideoCache.shared.cachedURL(for: item.id) ?? url
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: localURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            guard let (cgImage, _) = try? await generator.image(at: .zero) else { return }
            let image = UIImage(cgImage: cgImage)
            ThumbnailCache.shared[item.id] = image
            thumbnail = image
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Uploads tab tile

/// 9:16 grid tile for a picked-but-not-yet-imported upload — shows the in-memory prepared
/// thumbnail with a remove ("x") affordance (Uploads has no server-side selection to toggle, so
/// removal is the only interaction, unlike the Generations tile's tap-to-toggle).
private struct UploadPickerTile: View {
    let thumbnail: UIImage?
    let onRemove: () -> Void

    var body: some View {
        Color.black
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .clipped()
    }
}
