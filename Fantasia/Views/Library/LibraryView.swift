// LibraryView.swift
// Fantasia
// Library tab — completed generations grouped by day, newest first.
// Each day section: date + weekday header with divider line, then a
// 2-column masonry grid at native aspect ratios, fixed column width,
// greedy shortest-column placement. Only status == .completed items appear here.

import SwiftUI

struct LibraryView: View {
    @Environment(GenerationManager.self) private var generationManager
    @Environment(AuthManager.self) private var authManager
    @Environment(ThemeManager.self) private var theme

    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private let tileSpacing: CGFloat = 4
    private let sectionHPad: CGFloat = 12

    // Only completed items, newest first
    private var completedGenerations: [GenerationItem] {
        generationManager.feedGenerations
            .filter { $0.status == .completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // Group by calendar day, newest day first
    private var groupedByDay: [(date: Date, items: [GenerationItem])] {
        let calendar = Calendar.current
        let dict = Dictionary(grouping: completedGenerations) {
            calendar.startOfDay(for: $0.createdAt)
        }
        return dict.keys.sorted(by: >).map { date in
            (date: date, items: dict[date]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        ZStack {
            background

            if completedGenerations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Your completed videos will appear here")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 40)
            } else {
                GeometryReader { geo in
                    let gridWidth = geo.size.width - sectionHPad * 2
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: 20,
                            pinnedViews: [.sectionHeaders]
                        ) {
                            ForEach(groupedByDay, id: \.date) { group in
                                Section {
                                    masonryGrid(items: group.items, width: gridWidth)
                                        .padding(.horizontal, sectionHPad)
                                } header: {
                                    dayHeader(for: group.date)
                                }
                            }
                            // Load-more footer (cursor pagination) — this VStack is lazy, so a
                            // plain onAppear correctly fires only once this row scrolls into view.
                            if generationManager.nextCursor != nil {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 64)
                                    .onAppear { Task { await generationManager.loadNextPage() } }
                            }
                        }
                        .padding(.bottom, 100)
                        // Overscroll seam cover: on rubber-band past the top, the content shifts
                        // down and reveals the page background's radial-gradient tint above the
                        // first pinned header, which reads as a seam against the header's flat
                        // fill. This top-anchored rect extends 600pt above the content and rides
                        // with it during the bounce, showing flat header color instead. As a
                        // background of the whole LazyVStack it draws behind every row/header,
                        // so it can never cover content (unlike the per-header variant — see
                        // dayHeader's NOTE).
                        .background(alignment: .top) {
                            theme.elevatedBackground
                                .frame(height: 600)
                                .offset(y: -600)
                        }
                        // T7: pin the LazyVStack to its exact precomputed total height. Every
                        // section's true height is computable synchronously (dayHeader is now a
                        // fixed 36pt, the footer a fixed 64pt, tile heights come from known aspect
                        // ratios + colWidth) — with a constant contentSize the scroll indicator is
                        // stable and long-press-draggable, laziness inside is preserved.
                        .frame(height: totalContentHeight(gridWidth: gridWidth), alignment: .top)
                    }
                    .scrollIndicators(.visible)
                    // Brackets an active scroll drag with isInteracting so
                    // GenerationManager.mergeLatest() buffers new items instead of
                    // prepending mid-scroll (ported from the old FeedView pattern).
                    // minimumDistance MUST stay >= 20: a 0-distance DragGesture on a
                    // ScrollView (even .simultaneousGesture) engages on touch-down and wins
                    // gesture arbitration on a quick flick FROM REST, so the scroll view never
                    // claims the flick and the list doesn't move (works fine mid-deceleration
                    // because content touches aren't delayed then). 20pt is the stable scroll
                    // threshold — the scroll view claims scroll-intent movement first, and this
                    // still fires during any genuine scroll so buffering is preserved for the
                    // case that matters. See GenerationManager.isInteracting doc comment.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { _ in generationManager.isInteracting = true }
                            .onEnded { _ in generationManager.isInteracting = false }
                    )
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Presigned video/image URLs are 24h TTL and re-signed on every fetch — refresh so
            // URLs for older items don't go stale mid-session (unlike Home/Feed/Generate,
            // Library is where users browse multi-day-old content). refreshIfStale() only
            // actually re-fetches if the cached list is >60s old — well under the 24h TTL, so
            // switching back to this tab repeatedly within a minute doesn't re-fetch every time.
            Task {
                await generationManager.refreshIfStale()
                await prefetchImages()
            }
        }
        .sheet(item: $selectedItem) { item in
            GenerationDetailPagerView(
                items: completedGenerations,
                currentId: item.id,
                isPresented: Binding(
                    get: { selectedItem != nil },
                    set: { if !$0 { selectedItem = nil } }
                )
            )
        }
    }

    private func handleDelete(item: GenerationItem) async {
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
        } catch {
            print("[LibraryView] delete error: \(error)")
        }
    }

    // MARK: - Day header: "June 29  Sunday ─────"

    private func dayHeader(for date: Date) -> some View {
        HStack(spacing: 8) {
            Text(dateString(for: date))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(weekdayString(for: date))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(theme.textSecondary)
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
        }
        .padding(.horizontal, sectionHPad)
        .frame(height: 36)
        .background(theme.elevatedBackground)
        // NOTE: do NOT hang an oversized overscroll-cover rect off this header. A previous fix
        // did exactly that (600pt rect offset upward as each header's background) and, because
        // later LazyVStack siblings draw on top of earlier ones, every day header painted over
        // the entire section above it — hiding "Today"'s header and grid, and hiding grid cells
        // until the next header pinned into the overlay layer. The overscroll cover now lives on
        // the LazyVStack itself (see body), where a background can never occlude content.
    }

    // T7: exact total content height for the LazyVStack — see the .frame(height:) call site in
    // body for why this must be exact (a content-derived height reintroduces the scroll
    // indicator jitter this fix removes; an under/over-estimate clips or gaps the grid).
    private func totalContentHeight(gridWidth: CGFloat) -> CGFloat {
        let colWidth = (gridWidth - tileSpacing) / 2
        var h: CGFloat = 0
        let groups = groupedByDay
        for group in groups {
            let (left, right) = distributeToColumns(group.items, colWidth: colWidth)
            h += 36  // header
            h += max(columnHeight(left, colWidth: colWidth), columnHeight(right, colWidth: colWidth))
        }
        h += 20 * CGFloat(max(0, groups.count - 1))          // LazyVStack spacing between sections
        // Confirmed (2026-07-12): spacing ALSO applies between a section's header and its grid
        // content, since `Section {} header: {}` still produces separate LazyVStack children.
        h += 20 * CGFloat(groups.count)                       // spacing between each header and its own content
        if generationManager.nextCursor != nil { h += 64 + 20 } // footer + its preceding spacing
        h += 100  // existing .padding(.bottom, 100)
        return h
    }

    // MARK: - 2-column masonry (fixed column width, native-ratio heights)

    private func masonryGrid(items: [GenerationItem], width: CGFloat) -> some View {
        let colWidth = (width - tileSpacing) / 2
        let (left, right) = distributeToColumns(items, colWidth: colWidth)
        let gridHeight = max(columnHeight(left, colWidth: colWidth),
                             columnHeight(right, colWidth: colWidth))
        return HStack(alignment: .top, spacing: tileSpacing) {
            masonryColumn(left, colWidth: colWidth)
            masonryColumn(right, colWidth: colWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Pin an explicit, precomputed height so each LazyVStack section is a fixed-height row.
        // Without this the grid's height is content-derived, so LazyVStack reserves an ESTIMATED
        // height for not-yet-realized sections and corrects it to the true height on realization.
        // That correction changes the ScrollView's contentSize, which makes the scroll indicator
        // visibly jump. The jump is worst for a lone tall tile (a singleton 9:16 section is one
        // ~330pt row whose realized height deviates most from the estimate). All inputs are known
        // synchronously (aspect ratios + colWidth), so the height below exactly matches the tiles
        // masonryColumn lays out — no clipping, no gap.
        .frame(height: gridHeight, alignment: .top)
    }

    // Rendered height of one column: stacked tile heights plus the inter-tile spacing between
    // them (n tiles => n-1 gaps). Mirrors masonryColumn's VStack(spacing: tileSpacing) exactly.
    private func columnHeight(_ items: [GenerationItem], colWidth: CGFloat) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let tiles = items.reduce(CGFloat(0)) { $0 + tileHeight($1, colWidth: colWidth) }
        return tiles + tileSpacing * CGFloat(items.count - 1)
    }

    private func masonryColumn(_ items: [GenerationItem], colWidth: CGFloat) -> some View {
        VStack(spacing: tileSpacing) {
            ForEach(items) { item in
                LibraryThumbnailView(
                    item: item,
                    onTap: { selectedItem = item },
                    onNameAsReference: { generationManager.pendingNameAsReference = item },
                    // T12 follow-up: confirmation now happens inside the cell itself (anchored
                    // to the pressed tile) — by the time this fires the user has already
                    // confirmed, so this just performs the delete.
                    onRequestDelete: { Task { await handleDelete(item: item) } }
                )
                .frame(width: colWidth, height: tileHeight(item, colWidth: colWidth))
            }
        }
        // Fixed width so a short/empty column can't stretch or center its tiles.
        .frame(width: colWidth, alignment: .top)
    }

    // Greedy shortest-column placement in strict newest-first order: each item
    // goes into whichever column is currently shorter. Tie-break sends the
    // first (newest) item left, guaranteeing the newest item is top-left.
    private func distributeToColumns(
        _ items: [GenerationItem], colWidth: CGFloat
    ) -> ([GenerationItem], [GenerationItem]) {
        var left: [GenerationItem] = [], right: [GenerationItem] = []
        var leftH: CGFloat = 0, rightH: CGFloat = 0
        for item in items {
            let h = tileHeight(item, colWidth: colWidth) + tileSpacing
            if leftH <= rightH { left.append(item); leftH += h }
            else { right.append(item); rightH += h }
        }
        return (left, right)
    }

    private func tileHeight(_ item: GenerationItem, colWidth: CGFloat) -> CGFloat {
        colWidth / clampedRatio(item)
    }

    // Clamp so a malformed/extreme aspect string can't produce a degenerate tile.
    private func clampedRatio(_ item: GenerationItem) -> CGFloat {
        min(max(nativeRatio(item), 9.0 / 21.0), 21.0 / 9.0)
    }


    // MARK: - Helpers

    private func nativeRatio(_ item: GenerationItem) -> CGFloat {
        let fallback = item.isImage ? "1:1" : "16:9"
        let parts = (item.params.aspectRatio ?? fallback).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return 1 }
        return CGFloat(parts[0] / parts[1])
    }

    private func dateString(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }

    private func weekdayString(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    // MARK: - Prefetch

    // Perf: warms the same "-grid" downscaled cache key that LibraryThumbnailView's grid cells
    // read (see that file) — must match its key/downscale exactly, or this prefetch silently
    // warms a cache entry nothing reads and grid cells still cold-load one at a time on scroll.
    // Concurrency capped at 4 in-flight downloads — an uncapped group fires every item's
    // download+decode at once, which spikes memory on large libraries right as a completion
    // reflow is already stressing the main thread (see GenerationCardView/LibraryThumbnailView).
    private static let prefetchConcurrency = 4

    private func prefetchImages() async {
        let items = completedGenerations.filter { $0.isImage }
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            func addNext() {
                guard let item = iterator.next() else { return }
                let gridKey = item.id + "-grid"
                group.addTask {
                    guard await ThumbnailCache.shared.image(for: gridKey) == nil,
                          let urlString = item.completedMediaUrl,
                          let url = URL(string: urlString) else { return }
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else { return }
                    let thumb = image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
                    ThumbnailCache.shared[gridKey] = thumb
                }
            }
            for _ in 0..<Self.prefetchConcurrency { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    private var background: some View {
        ZStack {
            theme.elevatedBackground.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.13), .clear],
                           center: .init(x: 0.1, y: 0.0),
                           startRadius: 0, endRadius: 340)
            .ignoresSafeArea()
        }
    }
}
