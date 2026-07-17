// ExplainerFormatSheet.swift
// Fantasia
// Server-driven input sheet for the Explainer format. This is a standalone view tree with a
// plain SwiftUI TextField; it deliberately does not share the Generate composer implementation.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

private let explainerAccent = Color(red: 0.545, green: 0.427, blue: 0.839)
// Selected-state accent for the style grid (mockup's teal, distinct from the purple brand accent
// used for the fallback tile gradients and the aspect-ratio pill fill).
private let explainerSelectedTeal = Color(red: 0.369, green: 0.918, blue: 0.831)

// Distinct placeholder gradient per style id, used only until real per-style thumb art
// (`formats/style-thumbs/{id}.jpg`) exists server-side. Six identical purple tiles was the bug
// this fixes — AsyncImage still wins once real art lands, this is fallback-only.
private let explainerStylePlaceholders: [String: [Color]] = [
    "pixel-art": [Color(red: 0.976, green: 0.451, blue: 0.086), Color(red: 0.996, green: 0.729, blue: 0.153)],
    "claymation": [Color(red: 0.867, green: 0.435, blue: 0.404), Color(red: 0.937, green: 0.663, blue: 0.443)],
    "flat-vector": [Color(red: 0.204, green: 0.596, blue: 0.859), Color(red: 0.298, green: 0.796, blue: 0.643)],
    "doodle-chalkboard": [Color(red: 0.169, green: 0.180, blue: 0.204), Color(red: 0.412, green: 0.427, blue: 0.451)],
    "3d-cartoon": [Color(red: 0.945, green: 0.353, blue: 0.588), Color(red: 0.702, green: 0.427, blue: 0.937)],
    "mixed-media": [Color(red: 0.545, green: 0.427, blue: 0.839), Color(red: 0.357, green: 0.561, blue: 0.851)],
]

struct ExplainerFormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager

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
                    promptSection
                    styleGridSection
                    aspectRatioSection
                    optionsSection
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
                sectionCaption("Style")

                if format.styleGrid.count > 6 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(
                            rows: [GridItem(.fixed(76), spacing: 10), GridItem(.fixed(76), spacing: 10)],
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
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay {
                        styleTileArt(style)
                            .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 13))

                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 13))

                Text(style.label)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }
            .frame(width: width, height: 76)
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? explainerSelectedTeal : theme.surfaceBorder, lineWidth: isSelected ? 2.5 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(explainerSelectedTeal, in: Circle())
                        .padding(5)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Prompt and sources

    /// One fused bordered card: TextField on top, attach/link chips inside the same card's bottom
    /// padding. Previously a separate heading + detached-field + detached-chips arrangement —
    /// the mockup shows a single container.
    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .trailing) {
                TextField(
                    "",
                    text: $promptText,
                    prompt: Text("What should it explain?")
                        .foregroundStyle(theme.textTertiary),
                    axis: .vertical
                )
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1...4)
                .padding(.trailing, enhanceAvailable ? 36 : 0)

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
                    .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Source link")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chipButton(
                        title: "Attach files",
                        systemImage: "plus",
                        isDisabled: isSubmitting || attachedItems.count >= 3
                    ) {
                        showsAttachmentSource = true
                    }
                    .accessibilityLabel("Attach files")

                    chipButton(
                        title: "Link",
                        systemImage: "link",
                        isDisabled: isSubmitting
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
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceBorder, lineWidth: 1)
        )
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
                .background(theme.surfaceStrong, in: Capsule())
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
            .background(theme.surfaceStrong, in: Capsule())
            .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isSubmitting)
        .accessibilityLabel("Remove \(item.fileName)")
    }

    // MARK: - Aspect ratio

    /// Its own full-width labeled pill row (was previously a cramped mini-cell squeezed into the
    /// voice/duration row). Renders whatever `format.aspectRatios` ships — currently 9:16/16:9.
    private var aspectRatioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCaption("Aspect Ratio")
            HStack(spacing: 8) {
                ForEach(format.aspectRatios, id: \.self) { ratio in
                    aspectPill(ratio)
                }
            }
        }
    }

    private func aspectPill(_ ratio: String) -> some View {
        let isSelected = selectedAspectRatio == ratio
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selectedAspectRatio = ratio
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: aspectIcon(for: ratio))
                    .font(.system(size: 13, weight: .semibold))
                Text(ratio)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(isSelected ? .white : theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12).fill(explainerAccent)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Aspect ratio, \(ratio) \(aspectOrientation(for: ratio))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Voice, duration options

    /// 2-up row: duration wheel LEFT (wider ~1.15:1), voice chevron field RIGHT.
    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionCaption("Options")
            GeometryReader { geometry in
                let spacing: CGFloat = 10
                let totalRatio: CGFloat = 1.15 + 1.0
                let availableWidth = geometry.size.width - spacing
                let durationWidth = availableWidth * (1.15 / totalRatio)
                let voiceWidth = availableWidth * (1.0 / totalRatio)

                HStack(alignment: .top, spacing: spacing) {
                    durationControl
                        .frame(width: durationWidth)

                    voiceControl
                        .frame(width: voiceWidth)
                }
            }
            .frame(height: 142)
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
                ZStack {
                    // Centered label — layered under the right-aligned credits so it reads as the
                    // bar's primary CTA rather than a left-aligned row item.
                    Group {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Generate")
                                .font(.headline.weight(.bold))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    HStack {
                        Spacer()
                        HStack(spacing: 3) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                            Text("\(selectedTierCredits)")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: selectedTierCredits)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
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

    private func generate() async {
        guard isValid, let selectedStyleId else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceURL = sourceUrlText.trimmingCharacters(in: .whitespacesAndNewlines)
        var localPlaceholderId: String?

        do {
            // D-11: lazy and fail-closed. Nothing is uploaded until Generate is tapped, and a
            // single failed upload prevents the generation request from being sent at all.
            let attachmentIds = try await uploadAttachmentIDs()

            let placeholderId = "local-" + UUID().uuidString
            localPlaceholderId = placeholderId
            generationManager.insertLocalPlaceholder(GenerationItem(
                localPlaceholderId: placeholderId,
                model: "",
                mediaType: .video,
                prompt: trimmedPrompt,
                params: GenerationParams(
                    resolution: nil,
                    duration: selectedDuration,
                    aspectRatio: selectedAspectRatio,
                    audioEnabled: true,
                    hasReference: (!attachmentIds.isEmpty || !trimmedSourceURL.isEmpty) ? true : nil,
                    width: nil,
                    height: nil
                ),
                costCredits: selectedTierCredits,
                referenceUrls: nil,
                createdAt: Date()
            ))

            let submitted = try await APIClient.shared.submitFormatGeneration(
                formatId: format.formatId,
                styleId: selectedStyleId,
                prompt: trimmedPrompt,
                durationSeconds: selectedDuration,
                voiceId: selectedVoiceId,
                music: selectedMusic,
                aspectRatio: selectedAspectRatio,
                attachmentIds: attachmentIds,
                sourceUrl: trimmedSourceURL.isEmpty ? nil : trimmedSourceURL
            )

            generationManager.promoteLocalPlaceholder(
                localId: placeholderId,
                toRealId: submitted.generationId
            )
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
            dismiss()
        } catch ExplainerSubmitError.attachmentUploadFailed {
            if let localPlaceholderId {
                generationManager.removeLocalPlaceholder(id: localPlaceholderId)
            }
            errorMessage = "One of your attachments couldn't be uploaded. Nothing was submitted."
        } catch let apiError as APIError {
            if let localPlaceholderId {
                generationManager.removeLocalPlaceholder(id: localPlaceholderId)
            }
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError,
                      code == "content_policy_violation" {
                errorMessage = "This may not adhere to our community guidelines. Please try again."
            } else if case .unexpectedResponse(_, let code?) = apiError,
                      ["INVALID_FORMAT", "INVALID_STYLE", "INVALID_DURATION", "INVALID_ASPECT_RATIO"].contains(code) {
                errorMessage = "One of these format options is no longer available. Reopen the sheet and try again."
            } else if case .unexpectedResponse(_, let code?) = apiError,
                      ["INVALID_ATTACHMENT", "INVALID_INPUT"].contains(code) {
                errorMessage = "Check the attached sources and link, then try again."
            } else {
                errorMessage = "An error has occurred. Please try again."
            }
        } catch {
            if let localPlaceholderId {
                generationManager.removeLocalPlaceholder(id: localPlaceholderId)
            }
            errorMessage = "An error has occurred. Please try again."
        }
    }

    private func uploadAttachmentIDs() async throws -> [String] {
        var uploadIds: [String] = []
        for index in attachedItems.indices {
            if let existingId = attachedItems[index].uploadId {
                uploadIds.append(existingId)
                continue
            }

            let item = attachedItems[index]
            let response: UploadResponse
            do {
                response = try await APIClient.shared.uploadReferenceMedia(
                    data: item.data,
                    mimeType: item.mimeType,
                    fileName: item.fileName
                )
            } catch {
                throw ExplainerSubmitError.attachmentUploadFailed
            }
            guard let uploadId = response.id else {
                throw ExplainerSubmitError.attachmentUploadFailed
            }
            attachedItems[index].uploadId = uploadId
            uploadIds.append(uploadId)
        }
        return uploadIds
    }

    // MARK: - Helpers

    /// Small uppercase tracked caption used for the STYLE / ASPECT RATIO / OPTIONS section
    /// headers (mockup treatment — dim, not a full-weight heading).
    private func sectionCaption(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(theme.textTertiary)
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

    /// Style tile art: real thumb art via AsyncImage when available, otherwise a per-style
    /// distinct placeholder gradient (`explainerStylePlaceholders`) — never a single repeated
    /// color across all six tiles.
    @ViewBuilder
    private func styleTileArt(_ style: FormatStyle) -> some View {
        if let url = URL(string: style.thumbUrl),
           let scheme = url.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    stylePlaceholder(for: style.id)
                }
            }
        } else {
            stylePlaceholder(for: style.id)
        }
    }

    private func stylePlaceholder(for styleId: String) -> some View {
        let colors = explainerStylePlaceholders[styleId]
            ?? [explainerAccent.opacity(0.8), Color(red: 0.357, green: 0.561, blue: 0.851).opacity(0.75)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
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
    var uploadId: String? = nil
}

private enum ExplainerSubmitError: Error {
    case attachmentUploadFailed
}
