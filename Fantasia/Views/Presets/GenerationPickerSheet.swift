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
    // "Load more until we have at least this many matches (or run out of history)" — without a
    // target like this, a single auto-fetch that happens to land on a page skewed toward the
    // OTHER media type would leave the grid looking stuck with too few results and no visible way
    // to trigger another fetch (see isAutoPaginating doc comment below).
    private let minimumDesiredCount = 15

    @State private var isAutoPaginating = false

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
                if matchingGenerations.isEmpty && !generationManager.isLoading && !isAutoPaginating {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(matchingGenerations) { item in
                            cell(for: item)
                                .onAppear {
                                    // Standard infinite-scroll trigger: fires as this cell scrolls
                                    // into view, which (unlike a static trailing view) genuinely
                                    // re-fires as the user scrolls further, since LazyVGrid
                                    // recycles cells based on scroll position.
                                    if item.id == matchingGenerations.last?.id {
                                        Task { await loadMoreIfNeeded() }
                                    }
                                }
                        }
                    }
                    .padding(3)

                    // Tied to an ACTUAL fetch in flight, not just "more raw history could exist"
                    // (nextCursor != nil is true even once matching content is exhausted, since
                    // there can be plenty of non-matching-type history left) — otherwise this
                    // would sit permanently visible once loadMoreIfNeeded's bounded attempts run
                    // out on an account with very little of the requested media type, which is
                    // exactly the misleading "always loading, nothing happens" look being fixed.
                    if generationManager.isLoading || isAutoPaginating {
                        ProgressView()
                            .padding(.vertical, 20)
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
            // FIX (2026-07-12): this used to call generationManager.startPolling() — wrong tool.
            // startPolling() is for screens watching an ACTIVE job's status live (Generate feed):
            // if any job anywhere in the account is pending/processing, it starts a recurring
            // fetch every 3s for as long as this sheet is open, and each of those fetches
            // unconditionally resets nextCursor back to page 1's value (GenerationManager.refresh()
            // always re-fetches page 1). That fights with and undoes this picker's own
            // loadNextPage() progress in a loop — the reported "keeps loading, stuck at a few
            // images" bug. refreshIfStale() is the one-shot version Library already uses for
            // exactly this "browse a list, don't continuously poll it" case.
            await generationManager.refreshIfStale()
            await loadMoreIfNeeded()
        }
    }

    // Keeps fetching pages while the filtered result set is thin and more history exists,
    // bounded so an account with very little of the requested media type (e.g. almost all video,
    // slot wants images) can't spin through its entire history in one burst. isAutoPaginating
    // gates emptyState so a legitimately-empty FIRST page (e.g. account's very first images are
    // several pages back) doesn't flash "No completed images yet" before this loop has had a
    // chance to look further.
    private func loadMoreIfNeeded() async {
        guard !isAutoPaginating else { return }
        isAutoPaginating = true
        defer { isAutoPaginating = false }
        var attempts = 0
        while matchingGenerations.count < minimumDesiredCount,
              generationManager.nextCursor != nil,
              attempts < 10 {
            await generationManager.loadNextPage()
            attempts += 1
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
