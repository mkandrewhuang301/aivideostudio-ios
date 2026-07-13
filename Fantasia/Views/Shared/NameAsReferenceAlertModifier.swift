// NameAsReferenceAlertModifier.swift
// Fantasia
// HIG-standard rename alert for "Name as reference" (Photos-style "Rename Album"), driven by
// GenerationManager.pendingNameAsReference so any surface can trigger it in place — no tab
// switch, no bottom sheet. Apply wherever a "Name as reference" trigger can fire while that
// screen is the front-most presentation (MainTabView for the tab content, plus any sheet/
// fullScreenCover hosted above it, since .alert only presents over its own host).

import SwiftUI

struct NameAsReferenceAlertModifier: ViewModifier {
    @Environment(GenerationManager.self) private var generationManager
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    @State private var name = ""
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .alert("Name this reference", isPresented: Binding(
                get: { generationManager.pendingNameAsReference != nil },
                set: { if !$0 { dismiss() } }
            )) {
                TextField(placeholder, text: $name)
                    .autocorrectionDisabled()
                Button("Save") { save() }
                Button("Cancel", role: .cancel) { dismiss() }
            } message: {
                Text("Use @name in prompts to reference this media.")
            }
            .alert("Couldn't Save Reference", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private var placeholder: String {
        generationManager.pendingNameAsReference?.isImage == true ? "Image" : "Video"
    }

    private func save() {
        guard let item = generationManager.pendingNameAsReference else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        dismiss()
        Task {
            let succeeded = await mediaLibrary.saveGenerationAsReference(item: item, name: trimmed)
            if !succeeded {
                errorMessage = "Couldn't save this as a reference."
            }
        }
    }

    private func dismiss() {
        generationManager.pendingNameAsReference = nil
        name = ""
    }
}

extension View {
    func nameAsReferenceAlert() -> some View {
        modifier(NameAsReferenceAlertModifier())
    }
}
