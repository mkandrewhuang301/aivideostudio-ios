// VideoExplainerFormatSheet.swift
// Fantasia
// Native upload flow for the server-driven Video Explainer format.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CoreTransferable
import AVFoundation

private let videoExplainerAccent = Color(red: 0.18, green: 0.71, blue: 0.82)

private enum VideoExplainerMode: String, CaseIterable, Identifiable {
    case episode
    case theme

    var id: String { rawValue }
    var title: String { self == .episode ? "Whole video" : "Focused story" }
    var subtitle: String {
        self == .episode
            ? "Retell the main arc in order"
            : "Follow one event, person, or theme"
    }
}

private struct VideoExplainerSource {
    let url: URL
    let displayName: String
    let mimeType: String
    let durationSeconds: Double
    let sizeBytes: Int64
}

private struct TransferableVideo: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.fileURL)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-explainer-photo-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return TransferableVideo(fileURL: destination)
        }
    }
}

struct VideoExplainerFormatSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager

    let format: Format

    @State private var source: VideoExplainerSource?
    @State private var mode: VideoExplainerMode = .episode
    @State private var themePrompt = ""
    @State private var selectedDuration: Int
    @State private var selectedAspectRatio: String
    @AppStorage("videoExplainerVoiceId") private var selectedVoiceId = ""
    @State private var includeMusic = true
    @State private var showsFileImporter = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showsVoicePicker = false
    @State private var isReadingVideo = false
    @State private var isSubmitting = false
    @State private var submissionStage = ""
    @State private var errorMessage: String?

    init(format: Format) {
        self.format = format
        let durations = format.outputDurations.isEmpty ? [30, 60, 90] : format.outputDurations
        _selectedDuration = State(initialValue: durations.contains(60) ? 60 : (durations.first ?? 60))
        _selectedAspectRatio = State(initialValue: format.defaultAspectRatio)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    hero
                    uploadSection
                    modeSection
                    if mode == .theme { themeSection }
                    durationSection
                    aspectSection
                    narratorSection
                    musicSection
                    rightsNote
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 130)
            }
        }
        .safeAreaInset(edge: .bottom) { submitBar }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                if case .failure = result { errorMessage = "That video couldn't be opened." }
                return
            }
            Task { await prepareVideo(at: url, needsSecurityScope: true, alreadyOwned: false) }
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task { await loadPhotoSelection(selection) }
        }
        .sheet(isPresented: $showsVoicePicker) { voicePicker }
        .alert("Video Explainer", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isSubmitting)
        .onAppear {
            if !format.voices.contains(where: { $0.id == selectedVoiceId }) {
                selectedVoiceId = format.voiceDefault.isEmpty ? (format.voices.first?.id ?? "Kore") : format.voiceDefault
            }
        }
        .onDisappear { removeLocalSource() }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [videoExplainerAccent.opacity(0.9), Color(red: 0.24, green: 0.33, blue: 0.72)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 66, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.15))
                    .padding(24)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(format.title)
                    .font(.system(size: 29, weight: .heavy))
                    .foregroundStyle(.white)
                Text(format.sheet.description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 12)
    }

    private var uploadSection: some View {
        section("Source video", detail: "10 seconds–60 minutes · MP4, MOV, MPEG, or WebM") {
            if let source {
                HStack(spacing: 13) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(videoExplainerAccent.opacity(0.16))
                        Image(systemName: "film.fill")
                            .font(.title2)
                            .foregroundStyle(videoExplainerAccent)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Text("\(formattedDuration(source.durationSeconds)) · \(ByteCountFormatter.string(fromByteCount: source.sizeBytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Button {
                        removeLocalSource()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(theme.textTertiary)
                    }
                    .accessibilityLabel("Remove source video")
                }
                .padding(13)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
            } else if isReadingVideo {
                HStack(spacing: 12) {
                    ProgressView().tint(videoExplainerAccent)
                    Text("Reading video…").foregroundStyle(theme.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 82)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
            } else {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoSelection, matching: .videos) {
                        uploadChoice(icon: "photo.on.rectangle", title: "Photo Library")
                    }
                    Button { showsFileImporter = true } label: {
                        uploadChoice(icon: "folder", title: "Browse Files")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var modeSection: some View {
        section("Story", detail: nil) {
            VStack(spacing: 10) {
                ForEach(VideoExplainerMode.allCases) { option in
                    Button { mode = option } label: {
                        HStack(spacing: 12) {
                            Image(systemName: mode == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(mode == option ? videoExplainerAccent : theme.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.subheadline.weight(.semibold))
                                Text(option.subtitle).font(.caption).foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                        }
                        .foregroundStyle(theme.textPrimary)
                        .padding(14)
                        .background(mode == option ? videoExplainerAccent.opacity(0.12) : theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(mode == option ? videoExplainerAccent.opacity(0.7) : theme.surfaceBorder)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var themeSection: some View {
        section("What should the story follow?", detail: "Example: John gets saved, or every time the plan goes wrong") {
            TextEditor(text: $themePrompt)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(10)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder)
                }
                .accessibilityLabel("Focused story description")
        }
    }

    private var durationSection: some View {
        let durations = format.outputDurations.isEmpty ? [30, 60, 90] : format.outputDurations
        return section("Finished length", detail: "Narration and selected footage are timed together") {
            HStack(spacing: 10) {
                ForEach(durations, id: \.self) { seconds in
                    optionPill(title: "\(seconds)s", selected: selectedDuration == seconds) {
                        selectedDuration = seconds
                    }
                }
            }
        }
    }

    private var aspectSection: some View {
        section("Frame", detail: nil) {
            HStack(spacing: 10) {
                ForEach(format.aspectRatios, id: \.self) { ratio in
                    optionPill(
                        title: ratio == "9:16" ? "Vertical  9:16" : "Wide  16:9",
                        selected: selectedAspectRatio == ratio
                    ) { selectedAspectRatio = ratio }
                }
            }
        }
    }

    private var narratorSection: some View {
        section("Narrator", detail: "Choose the voice that tells the story") {
            Button { showsVoicePicker = true } label: {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(videoExplainerAccent)
                    Text(selectedVoice?.label ?? "Choose a voice")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(15)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder) }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens narrator voice choices")
        }
    }

    private var musicSection: some View {
        Toggle(isOn: $includeMusic) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Background music")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Mixed quietly under narration")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .tint(videoExplainerAccent)
        .padding(15)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var rightsNote: some View {
        Label("Only upload video you own or have permission to edit.", systemImage: "checkmark.shield")
            .font(.caption)
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var submitBar: some View {
        VStack(spacing: 8) {
            if let source {
                Text("Estimated from \(formattedDuration(source.durationSeconds)) of source video")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
            }
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 10) {
                    if isSubmitting { ProgressView().tint(.white) }
                    Text(isSubmitting ? submissionStage : "Create Video Explainer")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                    Text("\(estimatedCost)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background {
                    if isValid && !isSubmitting {
                        LinearGradient(
                            colors: [videoExplainerAccent, Color(red: 0.24, green: 0.33, blue: 0.72)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else {
                        LinearGradient(colors: [theme.surfaceStrong, theme.surfaceStrong], startPoint: .leading, endPoint: .trailing)
                    }
                }
                .clipShape(Capsule())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!isValid || isSubmitting)
            .accessibilityLabel("Create Video Explainer, estimated \(estimatedCost) credits")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(theme.elevatedBackground.shadow(color: .black.opacity(0.14), radius: 12, y: -4))
    }

    private var voicePicker: some View {
        NavigationStack {
            List(format.voices) { voice in
                Button {
                    selectedVoiceId = voice.id
                    showsVoicePicker = false
                } label: {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(videoExplainerAccent)
                        Text(voice.label)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if voice.id == selectedVoiceId {
                            Image(systemName: "checkmark").foregroundStyle(videoExplainerAccent)
                        }
                    }
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Narrator voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsVoicePicker = false }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(theme.background)
    }

    private var selectedVoice: FormatVoice? {
        format.voices.first { $0.id == selectedVoiceId }
    }

    private var isValid: Bool {
        source != nil
            && selectedVoice != nil
            && (mode == .episode || !themePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var estimatedCost: Int {
        guard let source else { return format.pricing?.minimumCredits ?? 149 }
        let pricing = format.pricing ?? FormatPricing(
            sourceMinuteCredits: 8,
            outputSecondCredits: 1,
            minimumCredits: 149
        )
        return max(
            pricing.minimumCredits,
            Int(ceil(source.durationSeconds / 60 * Double(pricing.sourceMinuteCredits)
                     + Double(selectedDuration * pricing.outputSecondCredits)))
        )
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        detail: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func uploadChoice(icon: String, title: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(videoExplainerAccent)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(theme.surfaceBorder) }
    }

    private func optionPill(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.white : theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? videoExplainerAccent : theme.surface)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(selected ? videoExplainerAccent : theme.surfaceBorder) }
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadPhotoSelection(_ selection: PhotosPickerItem) async {
        isReadingVideo = true
        defer {
            isReadingVideo = false
            photoSelection = nil
        }
        do {
            guard let imported = try await selection.loadTransferable(type: TransferableVideo.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            await prepareVideo(at: imported.fileURL, needsSecurityScope: false, alreadyOwned: true)
        } catch {
            errorMessage = "That video couldn't be imported. Try Browse Files instead."
        }
    }

    @MainActor
    private func prepareVideo(at url: URL, needsSecurityScope: Bool, alreadyOwned: Bool) async {
        isReadingVideo = true
        defer { isReadingVideo = false }
        let accessed = needsSecurityScope ? url.startAccessingSecurityScopedResource() : false
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        var ownedURL = url
        do {
            if !alreadyOwned {
                let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
                ownedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("video-explainer-source-\(UUID().uuidString).\(ext)")
                try FileManager.default.copyItem(at: url, to: ownedURL)
            }

            let asset = AVURLAsset(url: ownedURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 10, duration <= 60 * 60 else {
                throw VideoExplainerInputError.unsupportedDuration
            }
            let values = try ownedURL.resourceValues(forKeys: [.fileSizeKey])
            let mimeType = UTType(filenameExtension: ownedURL.pathExtension)?.preferredMIMEType ?? "video/mp4"
            guard ["video/mp4", "video/quicktime", "video/mpeg", "video/webm"].contains(mimeType) else {
                throw VideoExplainerInputError.unsupportedFormat
            }

            removeLocalSource()
            source = VideoExplainerSource(
                url: ownedURL,
                displayName: url.lastPathComponent,
                mimeType: mimeType,
                durationSeconds: duration,
                sizeBytes: Int64(values.fileSize ?? 0)
            )
        } catch VideoExplainerInputError.unsupportedDuration {
            if alreadyOwned || ownedURL != url { try? FileManager.default.removeItem(at: ownedURL) }
            errorMessage = "Choose a video between 10 seconds and 60 minutes."
        } catch VideoExplainerInputError.unsupportedFormat {
            if alreadyOwned || ownedURL != url { try? FileManager.default.removeItem(at: ownedURL) }
            errorMessage = "Choose an MP4, MOV, MPEG, or WebM video."
        } catch {
            if alreadyOwned || ownedURL != url { try? FileManager.default.removeItem(at: ownedURL) }
            errorMessage = "That video couldn't be read."
        }
    }

    @MainActor
    private func submit() async {
        guard isValid, let source else { return }
        isSubmitting = true
        var placeholderId: String?
        defer { isSubmitting = false }

        let trimmedTheme = themePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = mode == .theme ? trimmedTheme : "Episode summary"
        do {
            let localId = "local-" + UUID().uuidString
            placeholderId = localId
            generationManager.insertLocalPlaceholder(GenerationItem(
                localPlaceholderId: localId,
                model: "",
                mediaType: .video,
                prompt: prompt,
                params: GenerationParams(
                    resolution: nil,
                    duration: selectedDuration,
                    aspectRatio: selectedAspectRatio,
                    audioEnabled: true,
                    hasReference: true,
                    width: nil,
                    height: nil,
                    stageLabel: "Uploading video…",
                    sourceDurationSeconds: source.durationSeconds
                ),
                costCredits: estimatedCost,
                referenceUrls: nil,
                createdAt: Date()
            ))

            submissionStage = "Uploading video…"
            let upload = try await APIClient.shared.uploadVideoSummarySource(
                fileURL: source.url,
                mimeType: source.mimeType,
                fileName: source.displayName
            )
            submissionStage = "Starting explainer…"
            let submitted = try await APIClient.shared.submitVideoSummary(
                uploadId: upload.id,
                mode: mode.rawValue,
                prompt: mode == .theme ? trimmedTheme : nil,
                outputDurationSeconds: selectedDuration,
                aspectRatio: selectedAspectRatio,
                voiceId: selectedVoiceId,
                includeMusic: includeMusic
            )

            generationManager.promoteLocalPlaceholder(localId: localId, toRealId: submitted.generationId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
            removeLocalSource()
            dismiss()
        } catch let apiError as APIError {
            if let placeholderId { generationManager.removeLocalPlaceholder(id: placeholderId) }
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "You don't have enough credits for this source length."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "SOURCE_DURATION_UNSUPPORTED" {
                errorMessage = "Choose a video between 10 seconds and 60 minutes."
            } else {
                errorMessage = "The explainer couldn't be submitted. Please try again."
            }
        } catch {
            if let placeholderId { generationManager.removeLocalPlaceholder(id: placeholderId) }
            errorMessage = "The video upload didn't finish. Check your connection and try again."
        }
    }

    private func removeLocalSource() {
        guard let source else { return }
        try? FileManager.default.removeItem(at: source.url)
        self.source = nil
    }

    private func formattedDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }
}

private enum VideoExplainerInputError: Error {
    case unsupportedDuration
    case unsupportedFormat
}
