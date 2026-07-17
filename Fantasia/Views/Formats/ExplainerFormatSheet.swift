// ExplainerFormatSheet.swift
// Fantasia
// Server-driven input sheet for the Explainer format. This is a standalone view tree with a
// plain SwiftUI TextField; it deliberately does not share the Generate composer implementation.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private let explainerAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

struct ExplainerFormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme

    let format: Format

    @State private var promptText = ""
    @State private var selectedStyleId: String?
    @State private var selectedDuration: Int
    @State private var selectedAspectRatio: String
    @AppStorage("explainerVoiceId") private var selectedVoiceId = ""
    @AppStorage("explainerMusic") private var selectedMusic = "auto"

    @State private var attachedItems: [ExplainerAttachedItem] = []
    @State private var sourceUrlText = ""
    @State private var showsSourceURL = false
    @State private var showsAttachmentSource = false
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var photoSelections: [PhotosPickerItem] = []

    @State private var showsVoicePicker = false
    @State private var showsMusicPicker = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    // Prompt Intelligence is an optional sibling initiative. Keep the affordance absent until
    // APIClient exposes a stable enhance method; the Explainer flow must never depend on it.
    private let enhanceAvailable = false

    init(format: Format) {
        self.format = format
        _selectedStyleId = State(initialValue: format.styleGrid.first?.id)
        _selectedDuration = State(
            initialValue: format.durationTiers.contains(where: { $0.seconds == 30 })
                ? 30
                : (format.durationTiers.first?.seconds ?? 30)
        )
        _selectedAspectRatio = State(initialValue: format.defaultAspectRatio)
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    headerSection
                    styleGridSection
                    promptSection
                    choicesRow
                    musicRow
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 150)
            }

            HStack {
                Spacer()
                closeButton
            }
            .padding(.top, 14)
            .padding(.trailing, 18)

            VStack(spacing: 0) {
                Spacer()
                generateBar
            }
        }
        .confirmationDialog("Attach source material", isPresented: $showsAttachmentSource) {
            Button("Photo Library") { showsPhotoPicker = true }
            Button("Files or PDF") { showsFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showsPhotoPicker,
            selection: $photoSelections,
            maxSelectionCount: max(1, 3 - attachedItems.count),
            matching: .images
        )
        .onChange(of: photoSelections) { _, selections in
            guard !selections.isEmpty else { return }
            Task { await addPhotoSelections(selections) }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await addImportedFiles(urls) }
            case .failure:
                errorMessage = "Couldn't read those files. Try again."
            }
        }
        .sheet(isPresented: $showsVoicePicker) {
            voicePickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        }
        .sheet(isPresented: $showsMusicPicker) {
            musicPickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        }
        .alert("Couldn't complete that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
        .onAppear {
            normalizeRememberedChoices()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Capsule()
                .fill(theme.textTertiary.opacity(0.55))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

            Text(format.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(theme.textPrimary)

            Text(format.sheet.description)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(theme.surfaceStrong.opacity(0.9), in: Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Close")
    }

    // MARK: - Style

    @ViewBuilder
    private var styleGridSection: some View {
        if !format.styleGrid.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Style")

                if format.styleGrid.count > 6 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(
                            rows: [GridItem(.fixed(126), spacing: 10), GridItem(.fixed(126), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(format.styleGrid) { style in
                                styleCell(style, width: 132)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                        ],
                        spacing: 12
                    ) {
                        ForEach(format.styleGrid) { style in
                            styleCell(style)
                        }
                    }
                }
            }
        }
    }

    private func styleCell(_ style: FormatStyle, width: CGFloat? = nil) -> some View {
        let isSelected = selectedStyleId == style.id
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selectedStyleId = style.id
            }
        } label: {
            VStack(spacing: 6) {
                Color.clear
                    .frame(height: 96)
                    .overlay {
                        formatImage(
                            rawURL: style.thumbUrl,
                            fallbackIcon: "paintpalette.fill"
                        )
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? explainerAccent : theme.surfaceBorder, lineWidth: isSelected ? 2.5 : 1)
                    )

                Text(style.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: width)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Prompt and sources

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("What should it explain?")

            ZStack(alignment: .trailing) {
                TextField(
                    "",
                    text: $promptText,
                    prompt: Text("Describe a topic, angle, or key facts…")
                        .foregroundStyle(theme.textTertiary),
                    axis: .vertical
                )
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...4)
                .padding(12)
                .padding(.trailing, enhanceAvailable ? 42 : 0)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(theme.surfaceBorder, lineWidth: 1)
                )

                if enhanceAvailable {
                    Button(action: improvePrompt) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(explainerAccent)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Improve prompt")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipButton(
                        title: "Attach files",
                        systemImage: "plus",
                        isDisabled: attachedItems.count >= 3
                    ) {
                        showsAttachmentSource = true
                    }
                    .accessibilityLabel("Attach files")

                    chipButton(
                        title: "Link",
                        systemImage: "link",
                        isDisabled: false
                    ) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            showsSourceURL.toggle()
                            if !showsSourceURL { sourceUrlText = "" }
                        }
                    }
                    .accessibilityLabel("Add a link")

                    ForEach(attachedItems) { item in
                        attachmentChip(item)
                    }
                }
            }

            if showsSourceURL {
                TextField("https://example.com/article", text: $sourceUrlText)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.subheadline)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
                .accessibilityLabel("Source link")
            }
        }
    }

    private func chipButton(
        title: String,
        systemImage: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDisabled ? theme.textTertiary : theme.textPrimary)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isDisabled)
    }

    private func attachmentChip(_ item: ExplainerAttachedItem) -> some View {
        Button {
            attachedItems.removeAll { $0.id == item.id }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if let thumbnail = item.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(explainerAccent)
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(item.fileName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 96)

                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(minHeight: 44)
            .background(theme.surface, in: Capsule())
            .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Remove \(item.fileName)")
    }

    // MARK: - Voice, duration, aspect

    private var choicesRow: some View {
        HStack(alignment: .top, spacing: 8) {
            voiceControl
                .frame(maxWidth: .infinity)

            durationControl
                .frame(width: 100)

            aspectControl
                .frame(width: 96)
        }
    }

    private var voiceControl: some View {
        Button { showsVoicePicker = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                controlLabel("VOICE")
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(selectedVoiceLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: 12)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Voice, \(selectedVoiceLabel)")
        .accessibilityHint("Opens voice choices")
    }

    private var durationControl: some View {
        VStack(spacing: 0) {
            controlLabel("DURATION")
                .padding(.top, 10)

            Picker("Duration", selection: $selectedDuration) {
                ForEach(format.durationTiers, id: \.seconds) { tier in
                    Text("\(tier.seconds)s").tag(tier.seconds)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(height: 110)
            .clipped()
            .accessibilityLabel("Duration")
            .accessibilityValue("\(selectedDuration) seconds")
            .accessibilityAdjustableAction(adjustDuration)
        }
        .frame(height: 142)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
    }

    private var aspectControl: some View {
        VStack(spacing: 8) {
            controlLabel("ASPECT")
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(format.aspectRatios, id: \.self) { ratio in
                        aspectButton(ratio)
                    }
                }
                .padding(.horizontal, 4)
            }

            Text(selectedAspectRatio)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .padding(.bottom, 8)
        }
        .frame(height: 142)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
    }

    private func aspectButton(_ ratio: String) -> some View {
        let isSelected = selectedAspectRatio == ratio
        return Button {
            selectedAspectRatio = ratio
        } label: {
            Image(systemName: aspectIcon(for: ratio))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSelected ? .white : theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(isSelected ? explainerAccent : theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Aspect ratio, \(ratio) \(aspectOrientation(for: ratio))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Music

    private var musicRow: some View {
        Button { showsMusicPicker = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    controlLabel("MUSIC")
                    Text(musicDisplayName(selectedMusic))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 64)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Music, \(musicDisplayName(selectedMusic))")
        .accessibilityHint("Opens music choices")
    }

    private var voicePickerSheet: some View {
        NavigationStack {
            List(format.voices) { voice in
                Button {
                    selectedVoiceId = voice.id
                    showsVoicePicker = false
                } label: {
                    HStack {
                        Text(voice.label)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if voice.id == selectedVoiceId {
                            Image(systemName: "checkmark")
                                .foregroundStyle(explainerAccent)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var musicPickerSheet: some View {
        NavigationStack {
            List(format.musicMoods, id: \.self) { mood in
                Button {
                    selectedMusic = mood
                    showsMusicPicker = false
                } label: {
                    HStack {
                        Text(musicDisplayName(mood))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if mood == selectedMusic {
                            Image(systemName: "checkmark")
                                .foregroundStyle(explainerAccent)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Generate

    private var generateBar: some View {
        VStack(spacing: 8) {
            if isSubmitting {
                Text(format.sheet.preparingLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }

            Button {
                Task { await generate() }
            } label: {
                HStack(spacing: 10) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    }
                    Text("Generate")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                        Text("\(selectedTierCredits)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: selectedTierCredits)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background {
                    if isValid && !isSubmitting {
                        Capsule().fill(LinearGradient.brandPrimary)
                    } else {
                        Capsule().fill(theme.surfaceStrong)
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isValid || isSubmitting)
            .accessibilityLabel("Generate, \(selectedTierCredits) credits")
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var isValid: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedStyleId != nil
    }

    private var selectedTierCredits: Int {
        format.durationTiers.first { $0.seconds == selectedDuration }?.credits ?? 0
    }

    /// Task 2 wires this action to attachment upload, format submission, and feed refresh. Keeping
    /// the state transition here establishes the complete locked submitting visual for Task 1.
    private func generate() async {
        guard isValid else { return }
        isSubmitting = true
        await Task.yield()
        isSubmitting = false
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.textPrimary)
    }

    private func controlLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(theme.textTertiary)
    }

    private var selectedVoiceLabel: String {
        format.voices.first { $0.id == selectedVoiceId }?.label
            ?? format.voices.first { $0.id == format.voiceDefault }?.label
            ?? format.voices.first?.label
            ?? selectedVoiceId
    }

    private func normalizeRememberedChoices() {
        if !format.voices.contains(where: { $0.id == selectedVoiceId }) {
            selectedVoiceId = format.voiceDefault
        }
        if !format.musicMoods.contains(selectedMusic) {
            selectedMusic = format.musicMoods.contains("auto") ? "auto" : (format.musicMoods.first ?? "auto")
        }
        if !format.aspectRatios.contains(selectedAspectRatio) {
            selectedAspectRatio = format.defaultAspectRatio
        }
    }

    private func musicDisplayName(_ mood: String) -> String {
        switch mood {
        case "auto": return "Auto (from topic)"
        case "none": return "None"
        default: return mood.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func aspectIcon(for ratio: String) -> String {
        guard let separator = ratio.firstIndex(of: ":"),
              let width = Double(ratio[..<separator]),
              let height = Double(ratio[ratio.index(after: separator)...]) else {
            return "rectangle"
        }
        if width == height { return "square" }
        return width < height ? "rectangle.portrait" : "rectangle"
    }

    private func aspectOrientation(for ratio: String) -> String {
        guard let separator = ratio.firstIndex(of: ":"),
              let width = Double(ratio[..<separator]),
              let height = Double(ratio[ratio.index(after: separator)...]) else {
            return ""
        }
        if width == height { return "square" }
        return width < height ? "portrait" : "landscape"
    }

    private func adjustDuration(_ direction: AccessibilityAdjustmentDirection) {
        let durations = format.durationTiers.map(\.seconds)
        guard let currentIndex = durations.firstIndex(of: selectedDuration) else { return }
        switch direction {
        case .increment where currentIndex < durations.count - 1:
            selectedDuration = durations[currentIndex + 1]
        case .decrement where currentIndex > 0:
            selectedDuration = durations[currentIndex - 1]
        default:
            break
        }
    }

    private func improvePrompt() {
        // Unreachable while enhanceAvailable is false. The optional sibling feature owns the API.
    }

    @ViewBuilder
    private func formatImage(rawURL: String?, fallbackIcon: String) -> some View {
        if let rawURL,
           let url = URL(string: rawURL),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    formatImageFallback(icon: fallbackIcon)
                }
            }
        } else {
            formatImageFallback(icon: fallbackIcon)
        }
    }

    private func formatImageFallback(icon: String) -> some View {
        LinearGradient(
            colors: [explainerAccent.opacity(0.8), Color(red: 0.357, green: 0.561, blue: 0.851).opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private func addPhotoSelections(_ selections: [PhotosPickerItem]) async {
        defer { photoSelections = [] }
        for selection in selections where attachedItems.count < 3 {
            guard let data = try? await selection.loadTransferable(type: Data.self),
                  let attachment = makeImageAttachment(data: data, suggestedName: "Source image") else {
                errorMessage = "Couldn't read one of those images. Try a different file."
                continue
            }
            attachedItems.append(attachment)
        }
    }

    private func addImportedFiles(_ urls: [URL]) async {
        for url in urls where attachedItems.count < 3 {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url) else {
                errorMessage = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if contentType?.conforms(to: .pdf) == true {
                attachedItems.append(ExplainerAttachedItem(
                    data: data,
                    mimeType: "application/pdf",
                    fileName: safeDisplayName(url.deletingPathExtension().lastPathComponent, extension: "pdf"),
                    thumbnail: nil
                ))
            } else if let attachment = makeImageAttachment(data: data, suggestedName: url.deletingPathExtension().lastPathComponent) {
                attachedItems.append(attachment)
            } else {
                errorMessage = "\(url.lastPathComponent) isn't a supported image or PDF."
            }
        }
    }

    private func makeImageAttachment(data: Data, suggestedName: String) -> ExplainerAttachedItem? {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let thumbnail = image.preparingThumbnail(of: CGSize(width: 80, height: 80)) ?? image
        return ExplainerAttachedItem(
            data: jpeg,
            mimeType: "image/jpeg",
            fileName: safeDisplayName(suggestedName, extension: "jpg"),
            thumbnail: thumbnail
        )
    }

    private func safeDisplayName(_ raw: String, extension fileExtension: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Source" : cleaned
        return "\(String(base.prefix(48))).\(fileExtension)"
    }
}

private struct ExplainerAttachedItem: Identifiable {
    let id = UUID()
    let data: Data
    let mimeType: String
    let fileName: String
    let thumbnail: UIImage?
}
