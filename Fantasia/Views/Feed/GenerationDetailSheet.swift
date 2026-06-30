// GenerationDetailSheet.swift
// Fantasia
// Bottom sheet with full metadata, download, share, and report actions.
// Opened from Feed card prompt tap or Library thumbnail tap (D-29).
// GAL-03 (download), GAL-04 (share), GAL-05 (metadata view).

import SwiftUI
import Photos
import AVFoundation

struct GenerationDetailSheet: View {
    let item: GenerationItem
    @Binding var isPresented: Bool
    @Environment(AuthManager.self) private var authManager

    @State private var showPlayer = false
    @State private var showShare = false
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var isReporting = false
    @State private var tmpShareUrl: URL? = nil
    @State private var thumbnail: UIImage? = nil

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        // ProfileCreditSheet drag handle pattern (PATTERNS.md)
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Thumbnail + play button (D-29)
                    if item.isImage, let urlString = item.completedMediaUrl, let imageUrl = URL(string: urlString) {
                        Button {
                            showPlayer = true
                        } label: {
                            AsyncImage(url: imageUrl) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Color.white.opacity(0.05)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    } else if let urlString = item.videoUrl, let videoUrl = URL(string: urlString) {
                        Button {
                            showPlayer = true
                        } label: {
                            ZStack {
                                Group {
                                    if let thumb = thumbnail {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Color.white.opacity(0.05)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                        .buttonStyle(.plain)
                        .task { await generateThumbnail(from: videoUrl) }
                    } else {
                        // In-progress or failed — no thumbnail
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.05))
                            .frame(height: 120)
                            .overlay {
                                Image(systemName: item.status == .failed ? "exclamationmark.triangle" : "clock")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                            }
                    }

                    // Full prompt text (D-29 — not truncated)
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

                    // Parameters (D-29: model + media-type-specific fields)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Parameters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        paramRow("Model", value: item.model.contains("mini") ? "Seedance Mini" : "Seedance Fast")
                        if item.isImage {
                            // Image: only resolution (width x height) — no duration/aspect/audio
                            if let w = item.params.width, let h = item.params.height {
                                paramRow("Resolution", value: "\(w) × \(h)")
                            }
                        } else {
                            // Video: existing params display
                            paramRow("Resolution", value: item.params.resolution ?? "—")
                            paramRow("Duration", value: item.params.duration.map { "\($0)s" } ?? "—")
                            paramRow("Aspect Ratio", value: item.params.aspectRatio ?? "—")
                            paramRow("Audio", value: (item.params.audioEnabled ?? true) ? "On" : "Off")
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

                    // Generation date (D-29)
                    if item.status == .completed {
                        Text("Generated \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Actions (D-29: Download, Share, Report)
                    // D-30: Delete is on the card, NOT here
                    VStack(spacing: 10) {
                        // Download (GAL-03) — primary button. Save-to-Photos deferred for images (08-CONTEXT.md).
                        if item.status == .completed, !item.isImage, let urlString = item.videoUrl {
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

                        if item.status == .completed, let urlString = item.completedMediaUrl {
                            // Share (GAL-04) — secondary button
                            Button {
                                Task { await prepareAndShare(urlString: urlString) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Share")
                                }
                                .frame(maxWidth: .infinity).frame(height: 52)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                                .foregroundStyle(.white)
                            }
                        }

                        // Report (MOD-03, D-29)
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
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        // Full-screen viewer when thumbnail tapped (D-29)
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url)
            }
        }
        // Share sheet (GAL-04) — present ActivityViewController with local file URL
        .sheet(isPresented: $showShare) {
            if let url = tmpShareUrl {
                ActivityViewController(activityItems: [url])
            }
        }
        // Error alert for failed save
        .alert("Save Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .background(Color(red: 0.09, green: 0.085, blue: 0.105))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden) // We draw our own capsule
    }

    // Helper: parameter row label + value pair
    private func paramRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.subheadline)
            Spacer()
            Text(value).foregroundStyle(.primary).font(.subheadline.weight(.medium))
        }
    }

    // GAL-03: Download to camera roll (PHPhotoLibrary addOnly)
    // RESEARCH.md Pattern 8 — requestAuthorization(for: .addOnly) NOT .readWrite (Pitfall 6)
    // NSPhotoLibraryAddUsageDescription already in project.yml (added Plan 06)
    private func saveToPhotos(urlString: String) async {
        guard let videoUrl = URL(string: urlString) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            // Download to temp file
            let (tmpUrl, _) = try await URLSession.shared.download(from: videoUrl)
            let destUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(item.id).mp4")
            try? FileManager.default.removeItem(at: destUrl)
            try FileManager.default.moveItem(at: tmpUrl, to: destUrl)

            // Request addOnly permission (RESEARCH.md Pitfall 6)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "Photo library access denied. Allow access in Settings."
                return
            }
            // RESEARCH.md Pattern 8: performChanges (not UISaveVideoAtPathToSavedPhotosAlbum)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destUrl)
            }
        } catch {
            saveError = "Could not save video: \(error.localizedDescription)"
        }
    }

    // GAL-04: Share via UIActivityViewController (wrapped in ActivityViewController)
    private func prepareAndShare(urlString: String) async {
        guard let mediaUrl = URL(string: urlString) else { return }
        do {
            let (tmpUrl, _) = try await URLSession.shared.download(from: mediaUrl)
            // Preserve correct file extension so Share Sheet recipients (Messages, Files, etc.)
            // recognize the content type — images must not be saved with a .mp4 extension.
            let ext = item.isImage ? (mediaUrl.pathExtension.isEmpty ? "jpg" : mediaUrl.pathExtension) : "mp4"
            let destUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(item.id)-share.\(ext)")
            try? FileManager.default.removeItem(at: destUrl)
            try FileManager.default.moveItem(at: tmpUrl, to: destUrl)
            tmpShareUrl = destUrl
            showShare = true
        } catch {
            print("[GenerationDetailSheet] share download error: \(error)")
        }
    }

    // Extract first-frame thumbnail from remote video URL using AVAssetImageGenerator
    private func generateThumbnail(from url: URL) async {
        let asset = AVURLAsset(url: url)
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

    // MOD-03: Report generation via POST /api/reports
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
