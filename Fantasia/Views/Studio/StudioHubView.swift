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

    // "+" tile → media picker (D-08). Plan 10 builds the real MediaPickerSheet; until then this
    // presents a lightweight placeholder so the hub's own navigation/state wiring is already
    // correct and only the sheet's content needs swapping in.
    @State private var showMediaPicker = false

    // Tap a project tile → open it, then push the Editor. Plan 11 builds the real EditorView;
    // until then this pushes a placeholder so the hub → editor link (must_haves) already works.
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
            mediaPickerPlaceholder
        }
        .navigationDestination(item: $openedProjectId) { projectId in
            editorPlaceholder(projectId: projectId)
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
                        Task {
                            await projectManager.openProject(id: project.id)
                            openedProjectId = project.id
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

    // MARK: - Forward-compat placeholders (replaced by Plans 10/11 — see their own file scope)

    private var mediaPickerPlaceholder: some View {
        VStack(spacing: 12) {
            Text("Add Media")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("The Generations/Uploads picker lands in a follow-up plan.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private func editorPlaceholder(projectId: String) -> some View {
        ZStack {
            Color(red: 0.039, green: 0.039, blue: 0.051).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("Editor")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Project \(projectId)")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
