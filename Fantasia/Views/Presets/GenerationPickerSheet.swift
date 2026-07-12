// GenerationPickerSheet.swift
// Fantasia
// Lets a preset slot be filled from a past generation instead of only Photo Library / Camera /
// Files (2026-07-12 user request — the composer already supports referencing past generations
// via @-mention/"Reference", presets never did). Filtered to completed generations matching the
// slot's expected media type (mirrors the same rule the other 3 sources already apply via
// PresetInputSheet.activeSlotKind), any preset/composer origin (not restricted to plain
// generations — user-confirmed 2026-07-12), paginated via GenerationManager.loadNextPage() same
// as Library.
//
// This view only SELECTS a generation — it does not upload anything itself. The caller
// (PresetInputSheet.handleGenerationPicked) downloads the generation's own presigned media URL
// and feeds those bytes into the EXACT SAME handlePickedMedia(data:isVideo:forSlot:) pipeline
// Photos/Camera/Files already use. This is deliberate, not an inefficiency: Motion Transfer-style
// per-second presets physically TRIM a too-long video client-side before upload (see
// PresetInputSheet's pendingTrim/finishVideoSlot), not just cap its billed duration — a
// server-side R2 object copy (the /api/uploads/from-generation endpoint used by "Name as
// Reference" elsewhere) can't perform that trim. Routing through handlePickedMedia keeps every
// source's cap/trim/re-encode behavior identical instead of introducing a second, divergent path
// for exactly one source. The download re-uses the same "no naming" default every other source
// already has (handlePickedMedia never sets a display_name) — no separate decision needed.

import SwiftUI

struct GenerationPickerSheet: View {
    let mediaKind: String   // "image" | "video" — matches PresetSlot.kind exactly
    let onSelect: (GenerationItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager

    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    private var matchingGenerations: [GenerationItem] {
        generationManager.generations.filter { item in
            item.status == .completed
                && !(item.completedMediaUrl ?? "").isEmpty
                && (mediaKind == "video" ? !item.isImage : item.isImage)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if matchingGenerations.isEmpty && !generationManager.isLoading {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(matchingGenerations) { item in
                            cell(for: item)
                        }
                    }
                    .padding(3)

                    if generationManager.nextCursor != nil {
                        ProgressView()
                            .padding(.vertical, 20)
                            .onAppear { Task { await generationManager.loadNextPage() } }
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("My Generations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            // Same cached-list-first pattern GenerationManager already uses everywhere else —
            // startPolling() no-ops if the list is already fresh, so this is cheap on repeat opens.
            generationManager.startPolling()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: mediaKind == "video" ? "video.slash" : "photo.on.rectangle.angled")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Text(mediaKind == "video" ? "No completed videos yet" : "No completed images yet")
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func cell(for item: GenerationItem) -> some View {
        Button {
            onSelect(item)
            dismiss()
        } label: {
            ZStack {
                if item.isImage, let urlString = item.completedMediaUrl, let url = URL(string: urlString) {
                    CachedThumbnailImage(cacheKey: "preset-picker-\(item.id)", url: url)
                } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                    CachedVideoFrameThumbnail(cacheKey: "preset-picker-\(item.id)", videoURL: url)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if !item.isImage {
                    Image(systemName: "video.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
