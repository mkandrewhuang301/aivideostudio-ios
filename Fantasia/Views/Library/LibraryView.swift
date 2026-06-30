// LibraryView.swift
// Fantasia
// Library tab — completed generations grouped by day, newest first.
// Each day section: date + weekday header with divider line, then 2-column masonry grid
// at native aspect ratios. Only status == .completed items appear here.

import SwiftUI

struct LibraryView: View {
    @Environment(GenerationManager.self) private var generationManager
    @Environment(AuthManager.self) private var authManager

    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private let columnSpacing: CGFloat = 4
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
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: 20,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(groupedByDay, id: \.date) { group in
                            Section {
                                masonryGrid(items: group.items)
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
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedItem) { item in
            GenerationDetailSheet(
                item: item,
                isPresented: Binding(
                    get: { selectedItem != nil },
                    set: { if !$0 { selectedItem = nil } }
                )
            )
            .environment(authManager)
        }
    }

    // MARK: - Day header: "June 29  Sunday ─────"

    private func dayHeader(for date: Date) -> some View {
        HStack(spacing: 8) {
            Text(dateString(for: date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(weekdayString(for: date))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.horizontal, sectionHPad)
        .padding(.vertical, 8)
        .background(Color(red: 0.09, green: 0.085, blue: 0.105))
    }

    // MARK: - 2-column masonry within a day

    private func masonryGrid(items: [GenerationItem]) -> some View {
        let leftItems  = items.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let rightItems = items.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)

        return HStack(alignment: .top, spacing: columnSpacing) {
            column(items: leftItems)
            column(items: rightItems)
        }
    }

    private func column(items: [GenerationItem]) -> some View {
        VStack(spacing: columnSpacing) {
            ForEach(items) { item in
                LibraryThumbnailView(item: item, ratio: nativeRatio(item)) {
                    selectedItem = item
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Helpers

    private func nativeRatio(_ item: GenerationItem) -> CGFloat {
        let parts = (item.params.aspectRatio ?? "16:9").split(separator: ":").compactMap { Double($0) }
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
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            let f = DateFormatter()
            f.dateFormat = "EEEE"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.09, green: 0.085, blue: 0.105).ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.13), .clear],
                           center: .init(x: 0.1, y: 0.0),
                           startRadius: 0, endRadius: 340)
            .ignoresSafeArea()
        }
    }
}
