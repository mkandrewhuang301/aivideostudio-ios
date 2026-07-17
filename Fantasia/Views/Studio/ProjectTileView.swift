// ProjectTileView.swift
// Fantasia
// Studio hub grid tiles (Phase 13, Plan 09): the constant "+" tile (top-left, D-06) and the
// per-project tile (thumbnail + title + relative date). Mirrors HomeView's heroCard/showsCard
// skeleton (Color.clear.aspectRatio(...).overlay{...}.clipShape(...).clipped().contentShape
// (Rectangle()).onTapGesture) per 13-PATTERNS.md, and reuses the same long-press →
// ScrollFriendlyContextMenu → onRequestDelete wiring LibraryThumbnailView already uses for D-04.

import SwiftUI

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

    @Environment(ThemeManager.self) private var theme
    @State private var isMediaPreviewActive = false

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
                    previewCornerRadius: 16
                )
            }
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
}
