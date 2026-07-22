// GenerationDetailSheet.swift
// Fantasia
// Bottom sheet with full image/video preview, metadata, and generation actions.
// Opened from Feed card prompt tap, Library thumbnail tap, or GenerateView card detail.

import SwiftUI
import UIKit
import Photos
import AVFoundation

/// A reference or preset input selected from the detail pull-over for full-screen inspection.
private struct ReferenceMediaPreview: Identifiable {
    let id: String
    let url: URL
    let isVideo: Bool
}

struct GenerationDetailSheet: View {
    let item: GenerationItem
    @Binding var isPresented: Bool
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(ThemeManager.self) private var theme
    @Environment(RatesManager.self) private var ratesManager
    @Environment(CreditManager.self) private var creditManager
    // D-4 (09.2-10 Task 3): needed to re-sign preset_input_upload_ids for the preset Remix fork
    // below, exactly like GenerationCardView's own presetInputThumbnailRow/presentPresetRemixSheet.
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    @State private var showPlayer = false
    @State private var showDeleteAlert = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var isPreparingShare = false
    @State private var saveError: String? = nil
    @State private var showSavedToast = false
    @State private var shareError: String? = nil
    @State private var isReporting = false
    @State private var thumbnail: UIImage? = nil
    @State private var cachedImage: UIImage? = nil
    @State private var isFavorite: Bool = false
    // Generic Animate action (09.1-12): turns any completed IMAGE generation into a short video
    // via bytedance/seedance-2.0-mini, using the completed image itself as the reference.
    @State private var showAnimateConfirm = false
    @State private var isAnimating = false
    @State private var animateError: String? = nil
    @State private var showVideoTranslation = false
    @State private var referencePreview: ReferenceMediaPreview?

    // D-4 (09.2-10 Task 3): preset Remix fork — mirrors GenerationCardView's own
    // presetRegistry/presetForRemix/remixPrefillSlots/matchedPreset exactly, so a preset row's
    // Remix here reopens the prefilled PresetInputSheet instead of dumping the user into
    // the freeform composer with a blank prompt (the backend nulls item.prompt on preset rows —
    // the 9.1 gap left by 09.1-08, which only forked GenerationCardView's own Remix action).
    @State private var presetRegistry = PresetRegistryManager()
    @State private var presetForRemix: Preset?
    @State private var remixPrefillSlots: [PresetSlotInput?] = []
    @State private var isPreparingRemix = false
    @State private var presetInputThumbs: [PresetInputThumbnail] = []
    @State private var magicEditorRemixDraft: MagicEditorRemixDraft?

    private struct PresetInputThumbnail: Identifiable {
        let slotIndex: Int
        let url: String
        let isVideo: Bool

        var id: String { "\(slotIndex)-\(url)" }
    }

    /// The registry row matching this generation's stamped preset_id, if any.
    private var matchedPreset: Preset? {
        guard let presetId = item.params.presetId else { return nil }
        return presetRegistry.presets.first { $0.presetId == presetId }
    }

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 4)

                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(theme.elevatedBackground, in: Circle())
                            .overlay(Circle().stroke(theme.surfaceBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                }
            }
            .padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Full image/video preview
                    if item.isImage {
                        ZStack {
                            theme.surface

                            if let img = cachedImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        // Keep image detail previews square so portrait and landscape outputs
                        // receive a balanced crop instead of the old wide ~16:9 window.
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomLeading) { detailMediaBadges }
                        .contentShape(Rectangle())
                        .onTapGesture { showPlayer = true }
                        .accessibilityLabel("Open image fullscreen")
                        .accessibilityAddTraits(.isButton)
                        .task { await loadCachedImage() }
                    } else if let urlString = item.videoUrl, let videoUrl = URL(string: urlString) {
                        ZStack {
                            theme.surface

                            if let thumb = thumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }

                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                        .onTapGesture { showPlayer = true }
                        .overlay(alignment: .bottomLeading) { detailMediaBadges }
                        .accessibilityLabel("Open video fullscreen")
                        .accessibilityAddTraits(.isButton)
                        .task { await generateThumbnail(from: videoUrl) }
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.surface)
                            .frame(minHeight: 120)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: item.status == .failed ? "exclamationmark.triangle" : "clock")
                                        .font(.system(size: 28))
                                        .foregroundStyle(item.status == .failed ? .orange : .secondary)
                                    if let message = item.failureMessage {
                                        Text(message)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 20)
                                    }
                                }
                                .padding(.vertical, 12)
                            }
                    }

                    if item.isPreset {
                        presetSummaryBox
                    } else if let prompt = item.prompt, !prompt.isEmpty {
                        freeformPromptBox(prompt: prompt)
                    }

                    // Parameters
                    VStack(alignment: .leading, spacing: 0) {
                        // T18: paramRow draws its own trailing hairline; the last visible row
                        // (Credits used when present, else the last param in its branch) passes
                        // showDivider: false so no line dangles after the final row.
                        let hasCredits = item.costCredits > 0
                        // Preset rows are branded, not model-exposed — the underlying model is
                        // an implementation detail (and the backend nulls it for presets, D-G).
                        // Show the preset's own title instead of the raw model name.
                        if item.isVideoTranslation {
                            paramRow("Tool", value: "Translate Video")
                        } else if item.isPreset {
                            paramRow("Preset", value: matchedPreset?.title ?? "Preset")
                        } else {
                            paramRow("Model", value: ModelCatalog.displayName(for: item.model))
                        }
                        if item.isImage {
                            // Aspect ratio removed from the image pullup (2026-07-11) — not
                            // meaningful for faceswap/preset output, which matches the input.
                            if let w = item.params.width, let h = item.params.height {
                                paramRow("Resolution", value: "\(w) × \(h)", showDivider: hasCredits)
                            }
                        } else {
                            if let language = item.params.outputLanguage {
                                paramRow("Language", value: language)
                            }
                            paramRow("Resolution", value: item.params.resolution ?? "—")
                            paramRow("Duration", value: item.params.duration.map { "\($0)s" } ?? "—")
                            paramRow("Aspect", value: item.params.aspectRatio ?? "—")
                            paramRow("Audio", value: (item.params.audioEnabled ?? true) ? "On" : "Off", showDivider: hasCredits)
                        }
                        if hasCredits {
                            paramRow("Credits used", value: "\(item.costCredits)", showDivider: false)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))

                    if item.status == .completed {
                        Text("Generated \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textTertiary)
                    }

                    // Actions
                    if item.status == .completed {
                        VStack(spacing: 14) {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                spacing: 8
                            ) {
                                if item.isImage {
                                    tileActionButton("square.and.pencil", "Edit") {
                                        presentImageEditor()
                                    }
                                } else {
                                    tileActionButton("arrow.2.squarepath", "Remix") {
                                        handleRemix()
                                    }
                                }
                                tileActionButton("paperclip", "Reference") {
                                    handleReference()
                                }
                                if item.isImage {
                                    tileActionButton(isAnimating ? "hourglass" : "wand.and.stars", "Animate") {
                                        showAnimateConfirm = true
                                    }
                                    .disabled(isAnimating)
                                } else {
                                    tileActionButton("captions.bubble", "Translate") {
                                        showVideoTranslation = true
                                    }
                                }
                                tileActionButton(isFavorite ? "heart.fill" : "heart", "Favorite") {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    isFavorite.toggle()                      // optimistic local icon flip
                                    let target = isFavorite
                                    Task {
                                        await generationManager.setFavorite(id: item.id, isFavorite: target)
                                        if let updated = generationManager.generations.first(where: { $0.id == item.id }) {
                                            isFavorite = updated.isFavorite
                                        }
                                    }
                                }
                            }

                            // Download (image or video) — primary CTA
                            if (item.isImage ? item.completedMediaUrl : item.videoUrl) != nil {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { await saveToPhotos() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSaving ? "clock" : "arrow.down.to.line")
                                        Text(isSaving ? "Saving..." : "Save to Photos")
                                            .font(.body.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .foregroundStyle(.white)
                                    .background(
                                        LinearGradient.brandPrimary,
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .disabled(isSaving)
                            }

                            // Share — secondary
                            if item.completedMediaUrl != nil {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { await prepareAndShare() }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: isPreparingShare ? "clock" : "square.and.arrow.up")
                                        Text(isPreparingShare ? "Preparing…" : "Share")
                                            .font(.body.weight(.semibold))
                                    }
                                    .frame(maxWidth: .infinity).frame(height: 52)
                                    .foregroundStyle(theme.textPrimary)
                                    // theme.surfaceStrong instead of .ultraThinMaterial — the
                                    // material is nearly invisible on the light background, so
                                    // this didn't read as a button in light mode.
                                    .background(theme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
                                }
                                .buttonStyle(PressableButtonStyle())
                                .disabled(isPreparingShare)
                            }

                            HStack {
                                Button {
                                    showDeleteAlert = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 13, weight: .medium))
                                        Text("Delete")
                                            .font(.subheadline)
                                    }
                                    .foregroundStyle(Color.red.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .disabled(isDeleting)

                                Spacer()

                                Button {
                                    Task { await reportGeneration() }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "flag")
                                            .font(.caption2)
                                            .foregroundStyle(Color.red.opacity(0.7))
                                        Text(isReporting ? "Reported" : "Report an issue")
                                            .font(.caption)
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isReporting)
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved to Photos").font(.subheadline.weight(.medium)).foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 0.5))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url, generationId: item.id)
            }
        }
        .fullScreenCover(item: $referencePreview) { preview in
            if preview.isVideo {
                FullScreenVideoPlayerView(videoUrl: preview.url, generationId: preview.id)
            } else {
                FullScreenImageView(
                    imageURL: preview.url,
                    cacheKey: preview.id + "-original-v2"
                )
            }
        }
        .fullScreenCover(item: $magicEditorRemixDraft) { draft in
            MaskEditorView(source: .url(draft.sourceURL), initialPrompt: draft.prompt)
        }
        // When Magic Editor (or any in-sheet submit) fires a generation, close this detail sheet so
        // the user lands on the Generate feed's loading card (MainTabView switches to tab 1 on the
        // same notification). Mirrors handleRemix()'s `isPresented = false`.
        .onReceive(NotificationCenter.default.publisher(for: .generationSubmitted)) { _ in
            isPresented = false
        }
        // D-4 (09.2-10 Task 3): schema-driven preset Remix reopens PresetInputSheet prefilled
        // from stored inputs. Magic Editor is presented separately in its mask canvas above.
        .sheet(item: $presetForRemix) { preset in
            PresetInputSheet(
                preset: preset,
                prefillSlots: remixPrefillSlots,
                prefillStyleId: item.params.styleId,
                prefillAspectRatio: item.params.aspectRatio
            )
                .environment(generationManager)
                .environment(creditManager)
                .environment(ratesManager)
                .environment(theme)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showVideoTranslation) {
            VideoTranslationSheet(item: item)
                .environment(generationManager)
                .environment(creditManager)
                .environment(theme)
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        .alert("Delete this \(item.isImage ? "image" : "video")?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { Task { await handleDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Save Failed", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("Share Failed", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "")
        }
        .confirmationDialog(
            "Animate this photo?",
            isPresented: $showAnimateConfirm,
            titleVisibility: .visible
        ) {
            Button("Animate for \(animateCostCredits) credits") { Task { await handleAnimate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds gentle, natural motion to this image and creates a new \(animateDurationSeconds)s video.")
        }
        .alert("Couldn't Animate", isPresented: Binding(
            get: { animateError != nil },
            set: { if !$0 { animateError = nil } }
        )) {
            Button("OK", role: .cancel) { animateError = nil }
        } message: {
            Text(animateError ?? "")
        }
        .background(theme.background)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            isFavorite = item.isFavorite
            loadPresetInputThumbnails()
        }
    }

    // MARK: - Action helpers

    /// Matches GenerationCardView's bottom-left fullscreen treatment. The whole preview owns
    /// the tap, so the visual pill does not introduce a competing gesture recognizer.
    private var detailMediaBadges: some View {
        HStack(spacing: 8) {
            Label("FULLSCREEN", systemImage: "viewfinder")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Color(red: 0.15, green: 0.16, blue: 0.25).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }

            if isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    private func freeformPromptBox(prompt: String) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient.brandPrimary)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 0) {
                Text(prompt)
                    .font(.system(size: 14.5))
                    .lineSpacing(4)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)

                if let references = item.referenceUrls, !references.isEmpty {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, 14)

                    Text("REFERENCES")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(references.enumerated()), id: \.offset) { index, reference in
                                VStack(alignment: .leading, spacing: 4) {
                                    Button {
                                        presentReference(reference, index: index)
                                    } label: {
                                        detailReferenceThumbnail(reference, index: index)
                                    }
                                    .buttonStyle(.plain)
                                    Text(referenceDisplayName(at: index, in: references))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(LinearGradient.brandPrimary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var presetSummaryBox: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient.brandPrimary)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LinearGradient.brandPrimary)
                    Text(matchedPreset?.title ?? "Preset")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                }

                if !presetInputThumbs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(presetInputThumbs) { thumbnail in
                                Button {
                                    presentPresetInput(thumbnail)
                                } label: {
                                    detailPresetThumbnail(thumbnail)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let prompt = magicEditorPrompt {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("PROMPT")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(theme.textTertiary)
                        Text(prompt)
                            .font(.system(size: 14.5))
                            .lineSpacing(3)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(presetSummaryDescription)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.elevatedBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func detailReferenceThumbnail(_ reference: GenerationReference, index: Int) -> some View {
        Group {
            if reference.isVideo {
                ZStack {
                    LinearGradient.brandPrimary
                    Image(systemName: "video.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                CachedThumbnailImage(
                    cacheKey: item.id + "-detail-reference-\(index)",
                    url: URL(string: reference.url)
                )
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.surfaceBorder, lineWidth: 1))
    }

    private func referenceDisplayName(at index: Int, in references: [GenerationReference]) -> String {
        let reference = references[index]
        let ordinal = references.prefix(index + 1).filter { $0.isVideo == reference.isVideo }.count
        return reference.isVideo ? "@Video\(ordinal)" : "@Image\(ordinal)"
    }

    private func detailPresetThumbnail(_ thumbnail: PresetInputThumbnail) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if thumbnail.isVideo {
                    ZStack {
                        LinearGradient.brandPrimary
                        Image(systemName: "video.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                } else {
                    if item.params.presetId == "magic-editor", thumbnail.slotIndex == 0 {
                        MagicEditorInputThumbnail(
                            sourceURL: URL(string: thumbnail.url),
                            maskURL: item.magicEditorMaskUrl.flatMap(URL.init(string:)),
                            cacheKey: item.id + "-detail-preset-input-\(thumbnail.slotIndex)"
                        )
                    } else {
                        CachedThumbnailImage(
                            cacheKey: item.id + "-detail-preset-input-\(thumbnail.slotIndex)",
                            url: URL(string: thumbnail.url)
                        )
                    }
                }
            }
            .frame(width: 52, height: 52)

            if let label = presetSlotLabel(at: thumbnail.slotIndex) {
                Text(label)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .allowsTightening(true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.surfaceBorder, lineWidth: 1))
    }

    private func presetSlotLabel(at index: Int) -> String? {
        guard let slots = matchedPreset?.inputSchema?.slots, slots.indices.contains(index) else { return nil }
        let label = slots[index].label.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.params.presetId == "magic-editor" { return "EDIT" }
        return label.isEmpty ? nil : label.uppercased()
    }

    private func presentPresetInput(_ thumbnail: PresetInputThumbnail) {
        guard let url = URL(string: thumbnail.url) else { return }
        referencePreview = ReferenceMediaPreview(
            id: item.id + "-detail-preset-input-\(thumbnail.slotIndex)",
            url: url,
            isVideo: thumbnail.isVideo
        )
    }

    private func presentReference(_ reference: GenerationReference, index: Int) {
        guard let url = URL(string: reference.url) else { return }
        referencePreview = ReferenceMediaPreview(
            id: item.id + "-detail-reference-\(index)",
            url: url,
            isVideo: reference.isVideo
        )
    }

    private var magicEditorPrompt: String? {
        guard item.params.presetId == "magic-editor",
              let prompt = item.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        return prompt
    }

    private var presetSummaryDescription: String {
        let inputCount = item.params.presetInputUploadIds?.compactMap { $0 }.count ?? 0
        guard inputCount > 0 else { return "The preset writes its own prompt behind the scenes." }
        let noun = inputCount == 1 ? "photo" : "photos"
        return "Made from your \(inputCount) \(noun) — the preset writes its own prompt behind the scenes."
    }

    @ViewBuilder
    private func tileActionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.textPrimary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func loadPresetInputThumbnails() {
        guard item.isPreset, let ids = item.params.presetInputUploadIds, !ids.isEmpty,
              presetInputThumbs.isEmpty else { return }
        Task {
            if let directInputs = item.presetInputUrls {
                let directThumbs = directInputs.enumerated().compactMap { index, input in
                    input.map {
                        PresetInputThumbnail(slotIndex: index, url: $0.url, isVideo: $0.isVideo)
                    }
                }
                if !directThumbs.isEmpty {
                    presetInputThumbs = directThumbs
                    return
                }
            }
            await mediaLibrary.load()
            var map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let requiredIds = Set(ids.compactMap { $0 })
            if !requiredIds.isSubset(of: Set(map.keys)) {
                await mediaLibrary.load(forceRefresh: true)
                map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            presetInputThumbs = ids.enumerated().compactMap { index, id in
                guard let id, let upload = map[id] else { return nil }
                return PresetInputThumbnail(slotIndex: index, url: upload.url, isVideo: upload.isVideo)
            }
        }
    }

    // MARK: - Generation actions

    /// Opens any completed photo generation directly in Magic Editor, using the generated
    /// image as the editable source. Keep the edit prompt blank so the user describes the new
    /// change rather than inheriting the prompt that created the original image.
    private func presentImageEditor() {
        guard item.isImage, let sourceURL = item.completedMediaUrl else { return }
        magicEditorRemixDraft = MagicEditorRemixDraft(sourceURL: sourceURL, prompt: "")
    }

    private func handleRemix() {
        // D-4: preset rows fork into the preset's own prefilled input sheet — never the
        // freeform composer (which would open blank; the backend nulls item.prompt on preset
        // runs). Freeform rows are completely unaffected below.
        if item.params.presetId == "magic-editor" {
            presentMagicEditorRemix()
            return
        }
        if item.isPreset, matchedPreset != nil {
            presentPresetRemixSheet()
            return
        }
        generationManager.pendingRemix = item
        NotificationCenter.default.post(name: .remixGenerationRequested, object: nil)
        isPresented = false
    }

    /// Magic Editor Remix restores the source photo used by the original run instead of opening
    /// the generic preset sheet. The generation-specific URL is preferred because it remains
    /// available even when an older upload has fallen outside the general library's newest page.
    private func presentMagicEditorRemix() {
        guard !isPreparingRemix else { return }

        if let directSource = item.presetInputUrls?.first.flatMap({ $0 }), !directSource.isVideo {
            magicEditorRemixDraft = MagicEditorRemixDraft(
                sourceURL: directSource.url,
                prompt: magicEditorPrompt ?? ""
            )
            return
        }

        if let loadedSource = presetInputThumbs.first(where: { $0.slotIndex == 0 && !$0.isVideo }) {
            magicEditorRemixDraft = MagicEditorRemixDraft(
                sourceURL: loadedSource.url,
                prompt: magicEditorPrompt ?? ""
            )
            return
        }

        guard let ids = item.params.presetInputUploadIds,
              let optionalSourceID = ids.first,
              let sourceID = optionalSourceID else { return }

        isPreparingRemix = true
        Task {
            defer { isPreparingRemix = false }
            await mediaLibrary.load()
            var source = mediaLibrary.items.first { $0.id == sourceID }
            if source == nil {
                await mediaLibrary.load(forceRefresh: true)
                source = mediaLibrary.items.first { $0.id == sourceID }
            }
            guard let source, !source.isVideo else { return }
            magicEditorRemixDraft = MagicEditorRemixDraft(
                sourceURL: source.url,
                prompt: magicEditorPrompt ?? ""
            )
        }
    }

    // MARK: - Preset Remix fork (D-4, 09.2-10 Task 3)
    // Re-signs this row's stored preset_input_upload_ids against the shared MediaLibraryManager
    // cache — same re-signing routine as GenerationCardView.presentPresetRemixSheet(), since
    // presigned URLs rotate per fetch (documented project landmine) and can't be trusted stale.
    private func presentPresetRemixSheet() {
        guard !isPreparingRemix,
              let presetId = item.params.presetId,
              let preset = presetRegistry.presets.first(where: { $0.presetId == presetId }) else { return }
        isPreparingRemix = true
        let ids = item.params.presetInputUploadIds ?? []
        Task {
            defer { isPreparingRemix = false }
            let directInputs = item.presetInputUrls ?? []
            var slots: [PresetSlotInput?] = Array(repeating: nil, count: max(ids.count, directInputs.count))
            let missingDirectIds = ids.enumerated().compactMap { index, id -> String? in
                guard let id else { return nil }
                let direct = directInputs.indices.contains(index) ? directInputs[index] : nil
                return direct == nil ? id : nil
            }
            if !missingDirectIds.isEmpty {
                await mediaLibrary.load()
            }
            var map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if !Set(missingDirectIds).isSubset(of: Set(map.keys)) {
                await mediaLibrary.load(forceRefresh: true)
                map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
            // `id` may be nil (empty optional slot, 09.1-11 Clothes Swap) — leave that slot's
            // entry nil so PresetInputSheet reopens with it correctly blank, not misaligned.
            for (index, id) in ids.enumerated() {
                guard let id else { continue }
                let direct = directInputs.indices.contains(index) ? directInputs[index] : nil
                let match = map[id]
                guard let url = direct?.url ?? match?.url else { continue }
                slots[index] = PresetSlotInput(
                    uploadId: id,
                    url: url,
                    thumbnail: nil,
                    isUploading: false,
                    durationSeconds: nil
                )
            }
            remixPrefillSlots = slots
            presetForRemix = preset   // triggers .sheet(item:) above
        }
    }

    // Attach this generation's own output as a reference input on the Generate tab.
    private func handleReference() {
        generationManager.pendingReference = item
        NotificationCenter.default.post(name: .referenceGenerationRequested, object: nil)
        isPresented = false
    }

    // Generic Animate action (09.1-12): turns any completed image into a short video via
    // bytedance/seedance-2.0-mini, same model/duration/prompt style as the Animate Old Photo
    // preset — but works on ANY completed image, not just a fresh upload, since it references
    // this generation's own output directly (reference_image_generation_ids) instead of routing
    // through a preset/upload flow. Fixed 5s duration matches Animate Old Photo's max_seconds cap.
    private let animateModel = "bytedance/seedance-2.0-mini"
    private let animateDurationSeconds = 5
    private let animatePrompt =
        "Bring this photo to life with subtle, natural motion — gentle breathing, slight head " +
        "movement, soft ambient background motion — keep the look and colors intact, no audio."

    private var animateCostCredits: Int {
        ratesManager.cost(model: animateModel, durationSeconds: animateDurationSeconds, resolution: "720p", hasVideoReference: false)
    }

    private func handleAnimate() async {
        guard !isAnimating, let sourceUrl = item.completedMediaUrl else { return }
        isAnimating = true
        defer { isAnimating = false }

        let body = GenerationRequestBody(
            prompt: animatePrompt,
            model: animateModel,
            mediaType: "video",
            duration: animateDurationSeconds,
            resolution: "720p",
            aspectRatio: nil,
            audioEnabled: false,
            imageAspectRatio: nil,
            imageQuality: nil,
            referenceImages: [sourceUrl],
            referenceVideos: nil,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: [item.id],
            referenceVideoGenerationIds: nil
        )

        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: animateModel,
            mediaType: .video,
            prompt: animatePrompt,
            params: GenerationParams(
                resolution: "720p",
                duration: animateDurationSeconds,
                aspectRatio: nil,
                audioEnabled: false,
                hasReference: true,
                width: nil,
                height: nil
            ),
            costCredits: animateCostCredits,
            referenceUrls: [GenerationReference(url: sourceUrl, isVideo: false)],
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            generationManager.removeLocalPlaceholder(id: placeholderId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                animateError = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                animateError = "This may not adhere to our community guidelines. Please try again."
            } else {
                animateError = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            animateError = "An error has occurred. Please try again."
        }
    }

    private func handleDelete() async {
        isDeleting = true
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
            isPresented = false
        } catch {
            print("[GenerationDetailSheet] delete error: \(error)")
        }
        isDeleting = false
    }

    // MARK: - Helpers

    private func loadCachedImage() async {
        guard item.isImage, let urlString = item.completedMediaUrl, let url = URL(string: urlString) else { return }
        // T20: seed instantly from the already-downscaled grid thumbnail (LibraryThumbnailView's
        // "-grid" cache key), if present, for an instant first paint while the full-res copy
        // loads — instead of a blank/spinner state during sheet presentation.
        if cachedImage == nil, let gridThumb = await ThumbnailCache.shared.image(for: item.id + "-grid") {
            cachedImage = gridThumb
        }
        if let cached = await ThumbnailCache.shared.image(for: item.id) { cachedImage = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        // Perf: UIImage(data:) only decodes lazily on first draw — that decode used to happen
        // on the render path during sheet-presentation animation, which could stall the main
        // thread long enough to eat the initial swipe-to-dismiss touch (T20).
        let prepared = await image.byPreparingForDisplay() ?? image
        ThumbnailCache.shared[item.id] = prepared
        cachedImage = prepared
    }

    private func paramRow(_ label: String, value: String, showDivider: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .foregroundStyle(theme.textSecondary)
                    .font(.system(size: 13.5))
                Spacer()
                Text(value)
                    .foregroundStyle(theme.textPrimary)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            .padding(.vertical, 9)
            if showDivider {
                Rectangle().fill(theme.divider).frame(height: 0.5)
            }
        }
    }

    private func saveToPhotos() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let (freshItem, mediaUrl) = try await refreshedCompletedMedia()
            let sourceURL: URL
            if freshItem.isImage {
                sourceURL = try await validatedDownload(from: mediaUrl)
            } else {
                sourceURL = try await VideoCache.shared.ensureCached(id: freshItem.id, remoteURL: mediaUrl)
            }
            let ext = freshItem.isImage ? (mediaUrl.pathExtension.isEmpty ? "jpg" : mediaUrl.pathExtension) : "mp4"
            let destUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(freshItem.id).\(ext)")
            try? FileManager.default.removeItem(at: destUrl)
            try FileManager.default.copyItem(at: sourceURL, to: destUrl)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "Photo library access denied. Allow access in Settings."
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                if freshItem.isImage {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: destUrl)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: destUrl)
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.3)) { showSavedToast = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { showSavedToast = false }
            }
        } catch {
            saveError = "Could not save \(item.isImage ? "image" : "video"): \(error.localizedDescription)"
        }
    }

    private func prepareAndShare() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        do {
            let (freshItem, mediaUrl) = try await refreshedCompletedMedia()
            let ext = freshItem.isImage ? (mediaUrl.pathExtension.isEmpty ? "jpg" : mediaUrl.pathExtension) : "mp4"
            let destUrl = FileManager.default.temporaryDirectory
                .appendingPathComponent("fantasia-\(freshItem.isImage ? "image" : "video").\(ext)")
            try? FileManager.default.removeItem(at: destUrl)
            if freshItem.isImage {
                // No image cache today — download straight from the presigned URL, then move
                // (not copy) the disposable temp download into the share path.
                let tmpUrl = try await validatedDownload(from: mediaUrl)
                try FileManager.default.moveItem(at: tmpUrl, to: destUrl)
            } else {
                // VideoCache is usually already warm (player/thumbnail generation prefetch it) —
                // this avoids re-downloading the whole video just to share it, and only hits the
                // network on a genuine cache miss. Copy (not move) since the cache still owns it.
                let cachedUrl = try await VideoCache.shared.ensureCached(id: freshItem.id, remoteURL: mediaUrl)
                try FileManager.default.copyItem(at: cachedUrl, to: destUrl)
            }
            // Presented natively via UIKit (not a SwiftUI .sheet) — see presentActivityViewController
            // for why: SwiftUI's sheet sizing either forces full-height or collapses the app-icon
            // grid to "More" under .presentationDetents([.medium]).
            presentActivityViewController(items: [
                ShareableMedia(url: destUrl, isVideo: !freshItem.isImage, thumbnail: thumbnail ?? cachedImage)
            ])
        } catch {
            print("[GenerationDetailSheet] share prepare error: \(error)")
            shareError = "Could not prepare \(item.isImage ? "image" : "video") for sharing: \(error.localizedDescription)"
        }
    }

    /// Presigned media URLs expire. Resolve this exact generation immediately before an action
    /// instead of trusting the immutable sheet item or a disk snapshot captured hours earlier.
    private func refreshedCompletedMedia() async throws -> (GenerationItem, URL) {
        let fresh = try await APIClient.shared.fetchGeneration(id: item.id)
        guard fresh.status == .completed,
              let urlString = fresh.completedMediaUrl,
              let url = URL(string: urlString)
        else { throw URLError(.resourceUnavailable) }
        return (fresh, url)
    }

    private func validatedDownload(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw URLError(.badServerResponse)
        }
        return temporaryURL
    }

    private func generateThumbnail(from url: URL) async {
        // Use the cached local file if this generation's video is already on disk (VideoCache
        // is keyed by generation ID, not URL — presigned R2 URLs rotate on every fetch) so this
        // doesn't re-download over the network just to grab a frame. If not cached yet, warm the
        // cache in the background so the full-screen player opened from here is instant too.
        guard let cachedURL = VideoCache.shared.cachedURL(for: item.id) else {
            VideoCache.shared.prefetch(id: item.id, remoteURL: url)
            return await generateThumbnail(from: url, source: url)
        }
        return await generateThumbnail(from: url, source: cachedURL)
    }

    private func generateThumbnail(from url: URL, source: URL) async {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            thumbnail = UIImage(cgImage: cgImage)
        } catch {
            print("[GenerationDetailSheet] thumbnail error: \(error)")
        }
    }

    private func reportGeneration() async {
        guard !isReporting else { return }
        do {
            let body = try JSONEncoder().encode(["generation_id": item.id])
            try await APIClient.shared.authorizedRequestNoContent(path: "api/reports", method: "POST", body: body)
            isReporting = true
        } catch {
            print("[GenerationDetailSheet] report error: \(error)")
        }
    }
}

// MARK: - Translate Video

private struct VideoTranslationSheet: View {
    let item: GenerationItem

    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager
    @Environment(ThemeManager.self) private var theme

    @State private var selectedLanguage = videoTranslationLanguages[0]
    @State private var measuredDurationSeconds: Double?
    @State private var isMeasuring = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var estimatedDurationSeconds: Double? {
        measuredDurationSeconds
            ?? item.params.sourceDurationSeconds
            ?? item.params.duration.map(Double.init)
    }

    private var estimatedCostCredits: Int? {
        estimatedDurationSeconds.map { Int(ceil($0)) * 5 }
    }

    private var isTooLong: Bool {
        (estimatedDurationSeconds ?? 0) > 480
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Translate the speech and on-screen speaker into another language.")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)

                    HStack {
                        Label("Up to 8 minutes", systemImage: "clock")
                        Spacer()
                        if let cost = estimatedCostCredits {
                            Text("Est. \(cost) credits")
                                .fontWeight(.semibold)
                        } else if isMeasuring {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking cost…")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                List(videoTranslationLanguages, id: \.self) { language in
                    Button {
                        selectedLanguage = language
                    } label: {
                        HStack {
                            Text(language)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if language == selectedLanguage {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color(red: 0.545, green: 0.427, blue: 0.839))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                }
                .listStyle(.plain)

                if isTooLong {
                    Text("This video is longer than the 8-minute limit.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                Button {
                    Task { await submitTranslation() }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting { ProgressView().tint(.white) }
                        Text(buttonTitle)
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                                     Color(red: 0.357, green: 0.561, blue: 0.851)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(isSubmitting || estimatedCostCredits == nil || isTooLong)
                .opacity((estimatedCostCredits == nil || isTooLong) ? 0.5 : 1)
                .padding(20)
            }
            .background(theme.background)
            .navigationTitle("Translate Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await measureDurationIfNeeded() }
    }

    private var buttonTitle: String {
        if isSubmitting { return "Translating…" }
        if let cost = estimatedCostCredits { return "Translate to \(selectedLanguage) · \(cost) credits" }
        return "Checking video…"
    }

    private func measureDurationIfNeeded() async {
        guard measuredDurationSeconds == nil,
              let urlString = item.completedMediaUrl,
              let url = URL(string: urlString) else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                measuredDurationSeconds = seconds
            }
        } catch {
            // Existing generated videos carry params.duration, so this is normally only reached
            // for older/imported rows. Keep the CTA disabled if no honest estimate is available.
            if estimatedDurationSeconds == nil {
                errorMessage = "Couldn’t check this video’s duration. Please try again."
            }
        }
    }

    private func submitTranslation() async {
        guard !isSubmitting, let cost = estimatedCostCredits, !isTooLong else { return }
        isSubmitting = true
        errorMessage = nil

        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: "",
            mediaType: .video,
            prompt: nil,
            params: GenerationParams(
                resolution: item.params.resolution,
                duration: estimatedDurationSeconds.map { Int(ceil($0)) },
                aspectRatio: item.params.aspectRatio,
                audioEnabled: true,
                hasReference: true,
                width: nil,
                height: nil,
                tool: "video_translation",
                outputLanguage: selectedLanguage,
                sourceDurationSeconds: estimatedDurationSeconds
            ),
            costCredits: cost,
            referenceUrls: nil,
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            let submitted = try await APIClient.shared.translateVideo(
                id: item.id,
                outputLanguage: selectedLanguage
            )
            generationManager.promoteLocalPlaceholder(localId: placeholderId, toRealId: submitted.generationId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError {
                switch code {
                case "INSUFFICIENT_CREDITS": errorMessage = "Insufficient credits."
                case "VIDEO_TOO_LONG": errorMessage = "This video is longer than the 8-minute limit."
                case "DURATION_UNAVAILABLE": errorMessage = "Couldn’t read this video’s duration."
                default: errorMessage = "Translation couldn’t start. Please try again."
                }
            } else {
                errorMessage = "Translation couldn’t start. Please try again."
            }
            await creditManager.fetchBalance()
            isSubmitting = false
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            errorMessage = "Translation couldn’t start. Please try again."
            isSubmitting = false
        }
    }
}

private let videoTranslationLanguages = [
    "Spanish", "French", "German", "Italian", "Portuguese", "Hindi", "Japanese", "Korean",
    "Mandarin", "Arabic", "Russian", "Indonesian", "Vietnamese (Vietnam)", "Turkish", "Polish",
    "Thai (Thailand)", "Filipino", "Dutch"
]
