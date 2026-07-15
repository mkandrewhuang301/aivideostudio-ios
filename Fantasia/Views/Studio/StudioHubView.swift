// StudioHubView.swift
// Fantasia
// Phase 13, Plan 09: the Studio project hub (D-06) — entered exclusively via the Home "Edit
// Studio" hero card. 2-column grid: "+" tile first, then the user's saved projects newest-first.
// Owns its own ProjectManager instance (mirrors HomeView's locally-scoped
// `@State private var registry = PresetRegistryManager()`) and passes it down to whatever this
// hub navigates into (media picker / editor), so every Edit Studio screen in this presentation
// shares one observable store.
//
// NOT forced dark (13-UI-SPEC.md) — this is a browsing surface, follows ThemeManager like every
// other grid screen. The Editor itself (Plan 11+) is the forced-dark canvas, not this hub.

import SwiftUI

struct StudioHubView: View {
    @Environment(ThemeManager.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var projectManager = ProjectManager()

    // "+" tile → media picker (D-08), wired to the real MediaPickerSheet (Plan 10).
    @State private var showMediaPicker = false
    @State private var isCreatingProject = false

    // Tap a project tile → open it (cache-first when a snapshot exists; otherwise await the
    // network GET before pushing EditorView).
    @State private var openedProjectId: String?

    // Long-press → Delete → the reused confirmationDialog pattern (D-04), verbatim copy from
    // LibraryThumbnailView/GenerationCardView's existing dialog.
    @State private var projectPendingDelete: ProjectSummary?

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            ScrollView {
                stateContent
            }
            .refreshable { await projectManager.refreshProjects() }
        }
        .navigationTitle("Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(theme.textPrimary)
                }
                .accessibilityLabel("Close Studio")
            }
        }
        .task {
            projectManager.hydrateFromSnapshot()
            await projectManager.loadProjects()
        }
        .sheet(isPresented: $showMediaPicker) {
            MediaPickerSheet { picked in
                Task { await createProject(from: picked) }
            }
            .environment(projectManager)
        }
        .navigationDestination(item: $openedProjectId) { projectId in
            editorDestination(projectId: projectId)
                .environment(projectManager)
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
                    Text("No projects yet — tap + to start your first edit.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                }
                grid
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            AddProjectTile { showMediaPicker = true }
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
                    onRequestDelete: { projectPendingDelete = project }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
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
