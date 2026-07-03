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

    var body: some View {
        TabView(selection: $currentId) {
            ForEach(items) { item in
                GenerationDetailSheet(item: item, isPresented: $isPresented)
                    .environment(authManager)
                    .environment(generationManager)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(red: 0.09, green: 0.085, blue: 0.105))
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
