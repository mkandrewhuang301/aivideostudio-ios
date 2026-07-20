// GenerationDetailPagerView.swift
// Fantasia
// Wraps GenerationDetailSheet in a horizontal TabView so Library/Generate detail taps can
// swipe between neighboring generations. Horizontal paging is orthogonal to the sheet's
// internal vertical ScrollView, so both gestures coexist without conflict.

import SwiftUI

struct GenerationDetailPagerView: View {
    let items: [GenerationItem]
    @State var currentId: String
    @Binding var isPresented: Bool
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme

    // Windowed paging (2026-07-19): the sheet used to build its TabView over the ENTIRE feed,
    // which made the pull-up feel slow on large libraries. Only pages near the current one are
    // materialized; the window re-centers as the user swipes toward either edge.
    @State private var windowStart: Int = 0
    @State private var windowEnd: Int = 0
    private let windowRadius = 10

    private var windowedItems: [GenerationItem] {
        guard !items.isEmpty, windowStart <= windowEnd else { return [] }
        return Array(items[windowStart...windowEnd])
    }

    var body: some View {
        TabView(selection: $currentId) {
            ForEach(windowedItems) { item in
                GenerationDetailSheet(item: item, isPresented: $isPresented)
                    .environment(authManager)
                    .environment(generationManager)
                    .environment(theme)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(theme.background)
        // T10 fix: was applied per-page inside GenerationDetailSheet — the pager pre-instantiates
        // neighboring pages, so 3+ .nameAsReferenceAlert() modifiers on the same presented sheet
        // all tried to present at once and UIKit silently rejected the duplicates. One host here,
        // shared across all pages via generationManager.pendingNameAsReference.
        .nameAsReferenceAlert()
        // T16: the sheet's own UIKit presentation background (pure black/white depending on
        // system scheme) peeks through the bottom safe-area strip below content's
        // .background(theme.background), which doesn't extend into the safe area itself.
        .presentationBackground(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear { centerWindow(on: currentId, expandingOnly: false) }
        .onChange(of: currentId) { _, newId in centerWindow(on: newId, expandingOnly: true) }
    }

    private func centerWindow(on id: String, expandingOnly: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if !expandingOnly || idx - windowStart < 3 {
            windowStart = max(0, idx - windowRadius)
        }
        if !expandingOnly || windowEnd - idx < 3 {
            windowEnd = min(items.count - 1, idx + windowRadius)
        }
    }
}
