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

    var body: some View {
        TabView(selection: $currentId) {
            ForEach(items) { item in
                GenerationDetailSheet(item: item, isPresented: $isPresented)
                    .environment(authManager)
                    .environment(generationManager)
                    .environment(theme)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
