// StudioHubView.swift
// Fantasia
// Phase 13, Plan 09: the Studio project hub (D-06) — entered exclusively via the Home "Edit
// Studio" hero card. A full-width New Project banner sits above a 2-column grid of the user's
// saved projects newest-first.
// Uses the app-scoped ProjectManager shared with Home, the media picker, and the editor. That
// lets the last persisted project snapshot paint before this screen's first frame and prevents a
// second loading cycle when entering Studio from Home.
//
// NOT forced dark (13-UI-SPEC.md) — this is a browsing surface, follows ThemeManager like every
// other grid screen. The Editor itself (Plan 11+) is the forced-dark canvas, not this hub.

import SwiftUI

struct StudioHubView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(ProjectManager.self) private var projectManager
    @Environment(GenerationManager.self) private var generationManager

    // "+" tile → media picker (D-08), wired to the real MediaPickerSheet (Plan 10).
    @State private var showMediaPicker = false
    @State private var isCreatingProject = false

    // Tap a project tile → open it (cache-first when a snapshot exists; otherwise await the
    // network GET before pushing EditorView).
    @State private var openedProjectId: String?

    // Long-press → Delete → the reused confirmationDialog pattern (D-04), verbatim copy from
    // LibraryThumbnailView/GenerationCardView's existing dialog.
    @State private var projectPendingDelete: ProjectSummary?

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    newProjectBanner
                    projectsLabel
                    stateContent
                }
                .padding(.bottom, 112)
            }
            .refreshable {
                await projectManager.refreshProjects()
                trackActiveStudioExports()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await projectManager.loadProjects()
            trackActiveStudioExports()
            projectManager.reconcileStudioExports(generationManager.generations)
        }
        .onChange(of: generationManager.generations) { _, generations in
            projectManager.reconcileStudioExports(generations)
        }
        .sheet(isPresented: $showMediaPicker) {
            MediaPickerSheet { picked in
                Task { await createProject(from: picked) }
            }
            .environment(projectManager)
        }
        // Item 1 (Andrew review, 2026-07-17): was `.navigationDestination(item:)` (side-push);
        // Andrew wants the editor to slide up from the bottom instead. EditorView already exits
        // via `@Environment(\.dismiss)` (topBar close button) and presents all its own sub-sheets
        // (add-audio, caption style, export status, fullscreen player) via `.sheet`/
        // `.fullScreenCover`, which nest fine on top of an outer `.fullScreenCover` — no changes
        // needed there.
        // `String` isn't `Identifiable`, so `.fullScreenCover(item:)` doesn't apply here (unlike
        // `.navigationDestination(item:)`, which only needs `Hashable`) — driven off an
        // isPresented Binding derived from the same optional instead.
        .fullScreenCover(isPresented: Binding(
            get: { openedProjectId != nil },
            set: { if !$0 { openedProjectId = nil } }
        )) {
            if let projectId = openedProjectId {
                editorDestination(projectId: projectId)
                    .environment(projectManager)
            }
        }
        // D-04: VERBATIM copy from the existing LibraryThumbnailView/GenerationCardView delete
        // confirmation ("Delete this video?" → here "Delete this project?" / "This cannot be
        // undone." / Delete (destructive) / Cancel).
        .confirmationDialog(
            "Delete this project?",
            isPresented: Binding(
                get: { projectPendingDelete != nil },
                set: { if !$0 { projectPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let project = projectPendingDelete {
                    Task { try? await projectManager.deleteProject(id: project.id) }
                }
                projectPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { projectPendingDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Page chrome (Cast sibling treatment)

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Studio")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Text("Your edits, all in one place.")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 3)
    }

    private var newProjectBanner: some View {
        Button { showMediaPicker = true } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Project")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text("Start from a video, photo, or generation")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 34, height: 34)
                    .background(theme.surfaceStrong, in: Circle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.surface)
                    .overlay {
                        LinearGradient(
                            colors: [accent.opacity(theme.isLight ? 0.22 : 0.38), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accent.opacity(0.30), lineWidth: 1)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .accessibilityHint("Opens the media picker")
    }

    private var projectsLabel: some View {
        Text("PROJECTS")
            .font(.system(size: 10, weight: .heavy))
            .tracking(1.3)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
    }

    // MARK: - States (loading / error / empty / populated)

    @ViewBuilder
    private var stateContent: some View {
        if projectManager.isLoading && !projectManager.hasLoadedOnce {
            loadingGrid
        } else if let error = projectManager.loadError, projectManager.projects.isEmpty {
            errorState(error)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if projectManager.projects.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "film.stack")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
                .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))

            Text("No projects yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            Text("Combine videos, photos, and generations into your next edit.")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)

            Button { showMediaPicker = true } label: {
                Text("New Project")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 40)
                    .background(accent, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, 5)
            .accessibilityHint("Opens the media picker")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 26)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    accent.opacity(0.40),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(projectManager.projects) { project in
                ProjectTileView(
                    project: project,
                    onTap: {
                        if projectManager.openProjectFromCache(id: project.id) {
                            openedProjectId = project.id
                        } else {
                            Task {
                                await projectManager.openProject(id: project.id)
                                openedProjectId = project.id
                            }
                        }
                    },
                    onRequestDelete: { projectPendingDelete = project },
                    onRetryExport: { retryExport(project) }
                )
            }
        }
        .padding(.horizontal, 14)
    }

    private var loadingGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(0..<6, id: \.self) { _ in
                ShimmerProjectTile()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load your projects")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Pull to refresh or try again.")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    // MARK: - "+" tile → new project creation (D-08)

    /// Resolves the picker's ordered selection into a new project: the first item becomes
    /// createProject's firstClip (single-clip create call, per ProjectManager.createProject's
    /// signature), any remaining items are appended via importClip/uploadClip afterward. Then
    /// pushes straight into the Editor exactly like tapping an existing tile.
    private func createProject(from picked: [PickedMedia]) async {
        guard let first = picked.first, !isCreatingProject else { return }
        isCreatingProject = true
        defer { isCreatingProject = false }
        do {
            let created: EditProject
            switch first {
            case .generation(let id, _):
                created = try await projectManager.createProject(firstClipGenerationId: id)
            case .upload(let url, let mediaType):
                created = try await projectManager.createProject(firstClipUploadURL: url, firstClipMediaType: mediaType)
            }
            for item in picked.dropFirst() {
                switch item {
                case .generation(let id, _):
                    try await projectManager.importClip(generationId: id)
                case .upload(let url, let mediaType):
                    try await projectManager.uploadClip(fileURL: url, mediaType: mediaType)
                }
            }
            openedProjectId = created.id
        } catch {
            print("[StudioHubView] createProject error: \(error)")
        }
    }

    private func trackActiveStudioExports() {
        var foundActiveExport = false
        for project in projectManager.projects {
            guard let export = project.lastExport,
                  export.status == .pending || export.status == .processing else { continue }
            foundActiveExport = true
            generationManager.registerPendingExport(
                id: export.generationId,
                projectId: project.id,
                aspectRatio: project.aspectRatio
            )
        }
        if foundActiveExport { generationManager.startPolling(forceRefresh: true) }
    }

    private func retryExport(_ project: ProjectSummary) {
        Task {
            do {
                let generationId = try await projectManager.exportProject(id: project.id)
                generationManager.registerPendingExport(
                    id: generationId,
                    projectId: project.id,
                    aspectRatio: project.aspectRatio
                )
                generationManager.startPolling(forceRefresh: true)
            } catch {
                print("[StudioHubView] retry export error: \(error)")
            }
        }
    }

    // MARK: - Editor destination (Plan 11's real EditorView)

    /// `openProjectFromCache` or `openProject` populates `loadedProject` before (or as) this
    /// destination is pushed — the ProgressView branch only covers the rare case where a pull-
    /// to-refresh or delete raced the navigation and cleared it out from under us.
    @ViewBuilder
    private func editorDestination(projectId: String) -> some View {
        if let loaded = projectManager.loadedProject, loaded.id == projectId {
            EditorView(project: loaded)
        } else {
            ZStack {
                Color(red: 0.039, green: 0.039, blue: 0.051).ignoresSafeArea()
                ProgressView().tint(.white)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Loading-state tile — same pulsing gradient recipe as GenerationCardView's shimmerView,
/// scoped to a private tile shape here since that view's implementation is private to Feed.
private struct ShimmerProjectTile: View {
    @Environment(ThemeManager.self) private var theme
    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .background(theme.surface)
            .overlay {
                LinearGradient(
                    colors: [Color.clear, Color.white.opacity(0.08), Color.clear],
                    startPoint: .init(x: shimmerOffset, y: 0),
                    endPoint: .init(x: shimmerOffset + 0.5, y: 1)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1.5
                }
            }
    }
}
