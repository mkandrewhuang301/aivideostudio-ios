// LibraryView.swift
// Fantasia
// D-04: Library tab — 2-column grid of completed generations only (status == .completed)
// D-05: Tap thumbnail → opens GenerationDetailSheet (same popup as Feed)
// D-39: Empty state "Your completed videos will appear here" when no completed items

import SwiftUI

struct LibraryView: View {
    @Environment(GenerationManager.self) private var generationManager
    @Environment(AuthManager.self) private var authManager

    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    // Only show completed (non-deleted, non-quarantined, non-failed) items
    private var completedGenerations: [GenerationItem] {
        generationManager.generations.filter { $0.status == .completed }
    }

    // 2-column grid — fixed adaptive columns (D-04, D-08)
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        ZStack {
            background

            if completedGenerations.isEmpty {
                // D-39: Library empty state
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
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(completedGenerations) { item in
                            LibraryThumbnailView(item: item) {
                                selectedItem = item
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .padding(.bottom, 100)  // tab bar clearance
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        // D-05: Detail sheet — tapping any thumbnail opens GenerationDetailSheet (Plan 09)
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
