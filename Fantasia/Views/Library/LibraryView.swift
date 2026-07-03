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

    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private let tileSpacing: CGFloat = 4
    private let sectionHPad: CGFloat = 12

    // Only completed items, newest first
    private var completedGenerations: [GenerationItem] {
        generationManager.generations
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
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 100)
                    }
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

    // MARK: - Day header: "June 29  Sunday ─────"

    private func dayHeader(for date: Date) -> some View {
        HStack(spacing: 8) {
            Text(dateString(for: date))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text(weekdayString(for: date))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.horizontal, sectionHPad)
        .padding(.vertical, 8)
        .background(Color(red: 0.13, green: 0.125, blue: 0.15))
    }

    // MARK: - 2-column masonry (fixed column width, native-ratio heights)

    private func masonryGrid(items: [GenerationItem], width: CGFloat) -> some View {
        let colWidth = (width - tileSpacing) / 2
        let (left, right) = distributeToColumns(items, colWidth: colWidth)
        return HStack(alignment: .top, spacing: tileSpacing) {
            masonryColumn(left, colWidth: colWidth)
            masonryColumn(right, colWidth: colWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func masonryColumn(_ items: [GenerationItem], colWidth: CGFloat) -> some View {
        VStack(spacing: tileSpacing) {
            ForEach(items) { item in
                LibraryThumbnailView(item: item) { selectedItem = item }
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
            Color(red: 0.13, green: 0.125, blue: 0.15).ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.13), .clear],
                           center: .init(x: 0.1, y: 0.0),
                           startRadius: 0, endRadius: 340)
            .ignoresSafeArea()
        }
    }
}
