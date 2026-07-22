// ProjectTileView.swift
// Fantasia
// Studio hub grid tiles (Phase 13, Plan 09): the constant "+" tile (top-left, D-06) and the
// per-project tile (thumbnail + title + relative date). Mirrors HomeView's heroCard/showsCard
// skeleton (Color.clear.aspectRatio(...).overlay{...}.clipShape(...).clipped().contentShape
// (Rectangle()).onTapGesture) per 13-PATTERNS.md, and reuses the same long-press →
// ScrollFriendlyContextMenu → onRequestDelete wiring LibraryThumbnailView already uses for D-04.

import SwiftUI
import Photos

/// Always the first grid cell (D-06). Fixed portrait shape, gray `theme.surface` fill, dotted
/// accent-purple border, centered "+" glyph — no label, no thumbnail.
struct AddProjectTile: View {
    @Environment(ThemeManager.self) private var theme
    var onTap: () -> Void

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .background(theme.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(accent.opacity(0.55))
            }
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 44, height: 44)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .accessibilityLabel("Start a new project")
    }
}

/// One saved project. Thumbnail is the project's first-frame poster (`ProjectSummary.thumbnailUrl`
/// — server-presigned, or nil while a project has no clips yet). Bottom gradient + title + relative
/// date matches `HomeView`'s heroCard/showsCard overlay pattern exactly (13-UI-SPEC.md Studio Hub).
struct ProjectTileView: View {
    let project: ProjectSummary
    var onTap: () -> Void
    var onRequestDelete: () -> Void = {}
    var onRetryExport: () -> Void = {}

    @Environment(ThemeManager.self) private var theme
    @State private var isMediaPreviewActive = false

    // Pass touches through the UIKit card interaction only when a real SwiftUI export control is
    // present underneath. The old always-on 86x48 hole made the top-right of every Draft card
    // completely untappable, which made opening a project appear to require a second tap.
    private var exportActionsHitAreaSize: CGSize {
        guard let status = project.lastExport?.status else { return .zero }
        switch status {
        case .completed:
            return CGSize(width: 86, height: 48)
        case .failed, .quarantined, .refunded:
            return CGSize(width: 48, height: 48)
        case .pending, .processing, .deleted:
            return .zero
        }
    }

    private var displayTitle: String {
        guard let title = project.title, !title.isEmpty else { return "Untitled Project" }
        return title
    }

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Edited " + formatter.localizedString(for: project.updatedAt, relativeTo: Date())
    }

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay {
                thumbnail
                    .allowsHitTesting(false)
                    .opacity(isMediaPreviewActive ? 0 : 1)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayTitle)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(relativeDate)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .allowsHitTesting(false)
                .opacity(isMediaPreviewActive ? 0 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()
            .contentShape(Rectangle())
            // Long-press → Delete, UIKit-backed (ScrollFriendlyContextMenu) so fast scroll flicks
            // in the hub's LazyVGrid are never eaten — same component LibraryThumbnailView uses.
            .overlay {
                ScrollFriendlyContextMenu(
                    menu: {
                        UIMenu(children: [
                            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                                onRequestDelete()
                            }
                        ])
                    },
                    onTap: onTap,
                    onPreviewingChanged: { active in isMediaPreviewActive = active },
                    previewCornerRadius: 16,
                    passthroughTopTrailingSize: exportActionsHitAreaSize
                )
            }
            .overlay(alignment: .topLeading) {
                exportStatusBadge
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                exportActions
                    .padding(8)
            }
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var thumbnail: some View {
        // 13-24 K7: image must never propose its own size — Color.clear fills the fixed 9:16
        // shell; the processed thumbnail lives in an overlay and is clipped to that shell.
        Color.clear
            .overlay {
                ZStack {
                    theme.surfaceStrong
                    if let urlString = project.thumbnailUrl, let url = URL(string: urlString) {
                        LetterboxThumbnailView(
                            url: url,
                            cacheKey: "project-cover-\(project.id)-\(url.lastPathComponent)"
                        ) {
                            theme.surfaceStrong
                        }
                    } else {
                        Image(systemName: "film")
                            .foregroundStyle(.white.opacity(0.35))
                            .font(.system(size: 22))
                    }
                }
            }
            .clipped()
    }

    private var exportStatusBadge: some View {
        HStack(spacing: 5) {
            if project.lastExport?.status == .pending || project.lastExport?.status == .processing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
            Text(exportStatusText)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.62), in: Capsule())
    }

    @ViewBuilder
    private var exportActions: some View {
        if let export = project.lastExport, export.status == .completed {
            StudioExportActionButtons(generationId: export.generationId)
        } else if let export = project.lastExport,
                  export.status == .failed || export.status == .quarantined || export.status == .refunded {
            Button(action: onRetryExport) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry export")
        }
    }

    private var exportStatusText: String {
        guard let status = project.lastExport?.status else { return "Draft" }
        switch status {
        case .pending, .processing:
            return "Rendering…"
        case .completed:
            return "Exported"
        case .failed, .quarantined, .refunded:
            return "Export failed"
        case .deleted:
            return "Draft"
        }
    }
}

/// Native terminal actions for Studio exports. The generation is refreshed by id immediately
/// before each action so an expired presigned URL is never used.
struct StudioExportActionButtons: View {
    let generationId: String

    @State private var isSaving = false
    @State private var isSharing = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 6) {
            actionButton(
                systemImage: isSaving ? "clock" : "arrow.down.to.line",
                accessibilityLabel: isSaving ? "Saving export" : "Save export to Photos",
                disabled: isSaving || isSharing
            ) {
                Task { await saveToPhotos() }
            }
            actionButton(
                systemImage: isSharing ? "clock" : "square.and.arrow.up",
                accessibilityLabel: isSharing ? "Preparing export" : "Share export",
                disabled: isSaving || isSharing
            ) {
                Task { await prepareAndShare() }
            }
        }
        .alert("Export action failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func actionButton(
        systemImage: String,
        accessibilityLabel: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.62), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    @MainActor
    private func saveToPhotos() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let localURL = try await refreshedLocalVideo()
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw StudioExportActionError.photoAccessDenied
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func prepareAndShare() async {
        guard !isSharing else { return }
        isSharing = true
        defer { isSharing = false }
        do {
            let cachedURL = try await refreshedLocalVideo()
            let shareURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fantasia-studio-export-\(generationId).mp4")
            try? FileManager.default.removeItem(at: shareURL)
            try FileManager.default.copyItem(at: cachedURL, to: shareURL)
            presentActivityViewController(items: [
                ShareableMedia(url: shareURL, isVideo: true, thumbnail: nil)
            ])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshedLocalVideo() async throws -> URL {
        let generation = try await APIClient.shared.fetchGeneration(id: generationId)
        guard generation.status == .completed,
              let urlString = generation.completedMediaUrl,
              let remoteURL = URL(string: urlString) else {
            throw StudioExportActionError.mediaUnavailable
        }
        return try await VideoCache.shared.ensureCached(id: generation.id, remoteURL: remoteURL)
    }
}

private enum StudioExportActionError: LocalizedError {
    case photoAccessDenied
    case mediaUnavailable

    var errorDescription: String? {
        switch self {
        case .photoAccessDenied:
            return "Photo library access was denied. Allow access in Settings and try again."
        case .mediaUnavailable:
            return "This export is not available yet. Try again in a moment."
        }
    }
}
