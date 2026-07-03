// FeedView.swift
// Fantasia
// dead code: not referenced by MainTabView or anywhere else — GenerateView + LibraryView
// are the only two tabs. Kept only because GenerationCardView/GenerationDetailSheet, which
// this file also exercises, are still used elsewhere.
// D-01: Feed tab (replaces Home tab — tab index 0)
// D-02: unified vertical list, newest on top — in-progress and completed together, no sections
// D-03: polls GET /api/generations every 3s while active jobs exist; push notification triggers immediate refresh
// D-36: low-credit confirmation before Regenerate dispatch
// D-37: delete with animation
// GEN-10: push notification receipt triggers immediate feed refresh

import SwiftUI

struct FeedView: View {
    @Environment(GenerationManager.self) private var generationManager
    @Environment(AuthManager.self) private var authManager
    @Environment(CreditManager.self) private var creditManager   // D-36: credit pre-flight check
    @Environment(ThemeManager.self) private var theme

    @State private var selectedItem: GenerationItem? = nil
    @State private var showDetailSheet = false

    // D-36: Low-credits confirmation before Regenerate dispatch
    @State private var confirmRegenerate: GenerationItem? = nil
    @State private var showLowCreditsAlert = false

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        ZStack {
            background

            // D-40: Feed tab empty state — none needed; dark background shows when empty
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(generationManager.generations) { item in
                        GenerationCardView(
                            item: item,
                            onTapDetail: {
                                selectedItem = item
                                showDetailSheet = true
                            },
                            onRemix: { handleRemix(item: item) },
                            onRegenerate: { Task { await handleRegenerate(item: item) } },
                            onReference: { handleReference(item: item) },
                            onNameAsReference: {},
                            onDelete: { Task { await handleDelete(item: item) } }
                        )
                    }
                    // Load more trigger (cursor pagination)
                    if generationManager.nextCursor != nil {
                        ProgressView()
                            .onAppear { Task { await generationManager.loadNextPage() } }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 100)  // tab bar clearance
            }
            // Brackets the touch-down → touch-up window with isInteracting so
            // GenerationManager.mergeLatest() buffers new items instead of
            // prepending mid-touch (see GenerationManager.isInteracting doc comment).
            // minimumDistance: 0 + simultaneousGesture fires alongside card buttons
            // rather than stealing their taps.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in generationManager.isInteracting = true }
                    .onEnded { _ in generationManager.isInteracting = false }
            )
        }
        .navigationTitle("Feed")
        .navigationBarTitleDisplayMode(.inline)
        // D-03: start polling on appear, stop on disappear
        .onAppear { generationManager.startPolling() }
        .onDisappear { generationManager.stopPolling() }
        // GEN-10: immediate refresh when push notification signals generation complete
        .onReceive(NotificationCenter.default.publisher(for: .generationCompleted)) { _ in
            Task { await generationManager.refresh() }
        }
        // Detail sheet
        .sheet(item: $selectedItem) { item in
            GenerationDetailSheet(item: item, isPresented: $showDetailSheet)
                .environment(authManager)
                .environment(generationManager)
                .environment(theme)
        }
        // D-36: Low-credits alert for Regenerate
        // Shown when creditsBalance < estimatedCost(for: item); user may still proceed
        .alert("Low credits", isPresented: $showLowCreditsAlert) {
            Button("Cancel", role: .cancel) {
                confirmRegenerate = nil
            }
            Button("Generate Anyway") {
                guard let item = confirmRegenerate else { return }
                Task { await dispatchRegenerate(item: item) }
                confirmRegenerate = nil
            }
        } message: {
            if let item = confirmRegenerate {
                let est = estimatedCost(for: item)
                Text("You have \(creditManager.creditsBalance) credits but this will use approximately \(est). Continue?")
            }
        }
    }

    private var background: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.13), .clear],
                           center: .init(x: 0.1, y: 0.0),
                           startRadius: 0, endRadius: 340)
            .ignoresSafeArea()
        }
    }

    // D-35: Remix — sets pendingRemix on GenerationManager, then switches to Generate tab via notification
    // MainTabView observes .remixGenerationRequested and switches to tab 2
    private func handleRemix(item: GenerationItem) {
        generationManager.pendingRemix = item
        NotificationCenter.default.post(name: .remixGenerationRequested, object: nil)
    }

    // Reference — attach this generation's own output as a reference input,
    // then switch to Generate tab via notification (mirrors handleRemix above).
    private func handleReference(item: GenerationItem) {
        generationManager.pendingReference = item
        NotificationCenter.default.post(name: .referenceGenerationRequested, object: nil)
    }

    // D-36: Regenerate — check credit balance first; show confirmation if low
    // Backend still enforces credits server-side; this alert is a UX pre-flight only
    private func handleRegenerate(item: GenerationItem) async {
        let cost = estimatedCost(for: item)
        if creditManager.creditsBalance < cost {
            confirmRegenerate = item
            showLowCreditsAlert = true
            return
        }
        await dispatchRegenerate(item: item)
    }

    // Credit estimate: rough ratePerSecond approximation matching GenerationOptionsPanel's formula
    // D-36: UX pre-flight only — backend enforces credits atomically (CLAUDE.md Rule 1)
    // Image items return 0 here; image cost shown separately in the generate flow.
    private func estimatedCost(for item: GenerationItem) -> Int {
        guard !item.isImage else { return 0 }
        let ratePerSecond: Int = item.model.contains("mini") ? 5 : 10
        return (item.params.duration ?? 0) * ratePerSecond
    }

    // Actual API dispatch (shared by direct path and confirmed-despite-low-credits path)
    private func dispatchRegenerate(item: GenerationItem) async {
        guard let prompt = item.prompt else { return }
        let body = GenerationRequestBody(
            prompt: prompt,
            model: item.model,
            mediaType: item.isImage ? "image" : "video",
            duration: item.params.duration,
            resolution: item.params.resolution,
            aspectRatio: item.isImage ? nil : item.params.aspectRatio,
            audioEnabled: item.params.audioEnabled,
            imageAspectRatio: item.isImage ? item.params.aspectRatio : nil,
            imageQuality: nil,
            referenceImages: nil,
            referenceVideos: nil,
            referenceUploadIds: nil
        )
        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            await generationManager.refresh()
        } catch {
            print("[FeedView] regenerate error: \(error)")
        }
    }

    // D-37: Delete — card removed from local state after successful API call (with spring animation)
    private func handleDelete(item: GenerationItem) async {
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
        } catch {
            print("[FeedView] delete error: \(error)")
        }
    }
}

extension Notification.Name {
    static let remixGenerationRequested = Notification.Name("remixGenerationRequested")
    static let referenceGenerationRequested = Notification.Name("referenceGenerationRequested")
}
