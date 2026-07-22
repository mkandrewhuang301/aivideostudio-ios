// GenerationCardView.swift
// Fantasia
// Card component for a single generation item in the Feed.
// D-06: aspect-ratio box sized to requested aspect ratio
// D-07: shimmer animation for pending/processing state
// D-09: action buttons greyed/disabled while active
// D-10, D-11, D-12: time-based progress jitter with Task.sleep (never Timer)
// D-16: static thumbnail + play icon → FullScreenVideoPlayerView on tap
// D-37: delete confirmation alert before calling onDelete
// D-38: error state with credits-returned message

import SwiftUI
import AVFoundation

/// Reconstructs Magic Editor's user-facing selection from the persisted OpenAI alpha mask.
/// The service mask is intentionally inverted (transparent = edit), so drawing the mask with
/// destinationOut over magenta leaves color only where the user painted.
struct MagicEditorInputThumbnail: View {
    let sourceURL: URL?
    let maskURL: URL?
    let cacheKey: String

    @State private var coloredMask: UIImage?

    var body: some View {
        ZStack {
            CachedThumbnailImage(cacheKey: cacheKey + "-source", url: sourceURL)
            if let coloredMask {
                Image(uiImage: coloredMask)
                    .resizable()
                    .scaledToFill()
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .task(id: maskURL) {
            guard coloredMask == nil, let maskURL else { return }
            let overlayKey = cacheKey + "-mask-overlay"
            if let cached = await ThumbnailCache.shared.image(for: overlayKey) {
                coloredMask = cached
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: maskURL),
                  let mask = UIImage(data: data) else { return }
            let smallMask = mask.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? mask
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: smallMask.size, format: format)
            let overlay = renderer.image { context in
                MaskPalette.color.withAlphaComponent(0.78).setFill()
                context.fill(CGRect(origin: .zero, size: smallMask.size))
                smallMask.draw(
                    in: CGRect(origin: .zero, size: smallMask.size),
                    blendMode: .destinationOut,
                    alpha: 1
                )
            }
            ThumbnailCache.shared[overlayKey] = overlay
            coloredMask = overlay
        }
    }
}

/// Rough wall-clock expectation for a generation's duration, seconds. Constants are best-effort
/// seeds — tune later against real Replicate timings; keep them in this one place.
enum ProgressEstimator {
    static func expectedSeconds(for item: GenerationItem) -> Double {
        if item.isImage { return item.model.contains("grok") ? 20 : 30 }
        let base: Double = item.model.contains("mini") ? 40 : 25
        let perSecond: Double = item.model.contains("mini") ? 6 : 4
        let duration = Double(item.params.duration ?? 6)
        let resMultiplier: Double = (item.params.resolution == "1080p") ? 1.6 : 1.0
        return (base + perSecond * duration) * resMultiplier
    }
}

struct GenerationCardView: View {
    static let detailButtonMinimumHitSize: CGFloat = 44

    let item: GenerationItem
    var onTapDetail: () -> Void      // tap prompt text → detail sheet (D-29)
    var onRemix: () -> Void          // D-35
    var onRegenerate: () -> Void     // D-36
    var onReference: () -> Void      // use this generation's output as a reference input
    var onNameAsReference: () -> Void  // long-press → promote this output into the permanent reference library
    var onDelete: () -> Void         // D-37
    var onRequestDelete: () -> Void = {}  // T12: long-press context menu Delete — routes to the caller's existing confirmationDialog (e.g. SwipeToDeleteRow's confirmDeleteItem), distinct from onDelete above

    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    // Perf: preset-input thumbnails (both here and in the remix fork below) resolve
    // preset_input_upload_ids against the shared upload library instead of calling
    // APIClient.fetchMyUploads() directly — that hit GET /api/uploads once PER preset card on
    // every appear (feed with N preset cards = N duplicate fetches of the same list on load).
    // MediaLibraryManager already caches this (hasLoadedOnce + 300s staleness window, snapshot-
    // hydrated), so .load() below is a no-op network call on cache hits.
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    @State private var animatedProgress: Double = 0
    @State private var jitterTask: Task<Void, Never>? = nil
    @State private var progressMessage: String? = nil   // elapsed-time-tiered "taking a while" copy
    @State private var thumbnail: UIImage? = nil
    @State private var showPlayer = false
    @State private var revealCompleted = false    // gates media reveal after fill-to-100 animation
    @State private var cachedImage: UIImage? = nil  // for image generations
    @State private var isMediaPreviewActive = false  // hides the media while the long-press lift is on screen (no duplicate)

    // D-11/T-09.1-03: preset badge + Remix-into-sheet fork. Local registry instance mirrors
    // HomeView's own `@State private var registry = PresetRegistryManager()` — registry rows are
    // cached to disk (bundled fallback + snapshot), so this is instant, no extra network fetch.
    @State private var presetRegistry = PresetRegistryManager()
    @State private var presetInputThumbs: [PresetInputThumbnail] = [] // re-signed via GET /api/uploads
    @State private var presetForRemix: Preset?                         // drives fullScreenCover(item:)
    @State private var remixPrefillSlots: [PresetSlotInput?] = []
    @State private var isPreparingRemix = false
    @State private var magicEditorRemixDraft: MagicEditorRemixDraft?

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    /// Extra tap target below the prompt row — taps that land on the top of the media still
    /// open the detail sheet instead of fullscreen preview.
    private let promptTapExtension: CGFloat = 56
    private var isActive: Bool { item.status == .pending || item.status == .processing }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Aspect-ratio box (D-06: sized to requested aspect ratio)
            // ×1.06 shaves ~6% off the media height and hands it to the prompt box — card
            // total height ≈ unchanged (2026-07-19). The fill crop stays center-aligned below.
            Color.clear
                .aspectRatio(cardAspectRatio * 1.06, contentMode: .fit)
                // Hidden while the long-press preview is lifted so the lifted copy is the only
                // visible image (avoids the "two images" duplicate look).
                .overlay { mediaContent.opacity(isMediaPreviewActive ? 0 : 1) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Long-press context menu (user request 2026-07-06). ⚠️ MUST stay UIKit-backed:
                // SwiftUI's .contextMenu here ate fast scroll flicks starting from rest on media
                // (confirmed regression, twice — see ScrollFriendlyContextMenu's header for the
                // full arbitration explanation). This overlay hit-tests the whole media box, so
                // it also owns the plain tap → fullscreen preview (the onTapGesture inside
                // mediaContent is now unreachable through it and kept only as documentation).
                .overlay {
                    ScrollFriendlyContextMenu(
                        menu: { mediaContextMenu },
                        previewImage: item.isImage ? cachedImage : thumbnail,
                        onTap: {
                            guard item.status == .completed, revealCompleted else { return }
                            showPlayer = true
                        },
                        onPreviewingChanged: { active in isMediaPreviewActive = active },
                        showsPlayIcon: !item.isImage
                    )
                    .accessibilityLabel(item.isImage ? "Open image fullscreen" : "Open video fullscreen")
                    .accessibilityAddTraits(.isButton)
                }
                // Extend prompt tap target into the top of the media — users often tap slightly
                // below the truncated prompt and hit the image instead. Placed AFTER the menu
                // overlay so this band keeps winning hit-testing for taps.
                .overlay(alignment: .top) {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: promptTapExtension)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onTapDetail)
                }
                .overlay(alignment: .bottomTrailing) {
                    if item.isPreset {
                        Text("PRESET")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LinearGradient.brandPrimary, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .allowsHitTesting(false)
                    } else if let durationLabel = mediaDurationLabel {
                        Text(durationLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                // Fullscreen pill matches the Kimi mockup: compact, dark, and anchored 8pt
                // from the bottom-left. The UIKit media overlay still owns the actual tap so
                // long-press and scroll arbitration remain unchanged.
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 8) {
                        if item.status == .completed, revealCompleted {
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
                        }

                        // Favorite badge — mirrors LibraryThumbnailView's heart while leaving
                        // fullscreen as the leftmost control.
                        if item.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        }
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                    .opacity(isMediaPreviewActive ? 0 : 1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

            detailSummaryButton
                .padding(.horizontal, 12)
                .padding(.top, 9)

            // Action buttons (D-09: always visible; disabled/greyed while active). Delete lives
            // on swipe-to-delete + the detail sheet for completed cards — a destructive accent on
            // every card's action row was unwarranted given those two paths already exist. Failed
            // cards have no output to reference, so "Reference" is replaced with a real Delete
            // button here (D-38: Remix/Regenerate/Delete are the active actions on a failed card) —
            // swipe-to-delete alone wasn't a discoverable enough affordance for clearing errors.
            HStack(spacing: 0) {
                actionButton("arrow.2.squarepath", "Remix", action: handleRemixTap)
                Rectangle().fill(theme.divider).frame(width: 0.5, height: 28)
                actionButton("arrow.clockwise", "Regen", action: handleRegenerateTap)
                Rectangle().fill(theme.divider).frame(width: 0.5, height: 28)
                if item.status == .failed {
                    actionButton("trash", "Delete", action: onRequestDelete, destructive: true)
                } else {
                    actionButton("paperclip", "Reference", action: onReference)
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.surfaceBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)

        // Full-screen player (D-16: tap thumbnail → full-screen)
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url, generationId: item.id)
            }
        }
        .fullScreenCover(item: $magicEditorRemixDraft) { draft in
            MaskEditorView(source: .url(draft.sourceURL), initialPrompt: draft.prompt)
        }

        // D-11/T-09.1-03: schema-driven preset Remix reopens PresetInputSheet prefilled from this
        // row's stored preset_input_upload_ids. Magic Editor uses the full-screen mask canvas
        // above because its freehand input cannot be represented by PresetInputSheet.
        // .sheet (not .fullScreenCover) so it swipe-down-dismisses like the generation detail
        // pullup (GenerationDetailPagerView) — user request 2026-07-08.
        .sheet(item: $presetForRemix) { preset in
            PresetInputSheet(
                preset: preset,
                prefillSlots: remixPrefillSlots,
                prefillStyleId: item.params.styleId,
                prefillAspectRatio: item.params.aspectRatio
            )
                .presentationBackground(theme.background)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }

        // Progress jitter lifecycle (D-10, D-11) — Task.sleep, not Timer
        .onAppear {
            loadThumbnail()
            loadCachedImage()
            loadPresetInputThumbnails()
            if isActive {
                startProgressTicking()
            } else if item.status == .completed {
                revealCompleted = true   // already done — skip animation
            }
        }
        .onDisappear { jitterTask?.cancel() }
        .onChange(of: item.status) { _, newStatus in
            jitterTask?.cancel()
            jitterTask = nil
            if newStatus == .completed {
                Task {
                    // Fast fill races toward 1.0 while downloading — exponential decay so it
                    // accelerates from current position and naturally slows near the top
                    let fillTask = Task {
                        while !Task.isCancelled && animatedProgress < 0.985 {
                            try? await Task.sleep(for: .seconds(0.1))
                            let gap = 1.0 - animatedProgress
                            animatedProgress = min(animatedProgress + gap * 0.28, 0.985)
                        }
                    }
                    await downloadMedia()     // 100% = image is in memory
                    fillTask.cancel()
                    animatedProgress = 1.0
                    try? await Task.sleep(for: .seconds(0.45))
                    revealCompleted = true
                }
            }
        }
    }

    // Accent-ruled summary box. Preset rows never expose the server-expanded prompt; they use
    // the registry title and index-aligned input slots instead.
    private var detailSummaryButton: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient.brandPrimary)
                .frame(width: 3)

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    if item.isPreset {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LinearGradient.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(matchedPreset?.title ?? "Preset")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            if let prompt = magicEditorPrompt {
                                Text(prompt)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text(item.prompt ?? "No prompt")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTapDetail)

                if item.isPreset {
                    presetInputThumbnailRow
                } else {
                    referenceThumbnailRow
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 10)
            .padding(.vertical, 13)
            // Always at least as tall as the with-references state (28pt thumb row) plus
            // the ~12pt reclaimed from the media's bottom crop — same box height + tap
            // target on every card, refs or not (2026-07-19).
            .frame(minHeight: 40)

            Button(action: onTapDetail) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    // The visible trailing column spans the summary row, so its hit target must
                    // span it too. A width-only frame left only the glyph-height strip tappable.
                    .frame(minWidth: Self.detailButtonMinimumHitSize, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.divider)
                            .frame(width: 0.5, height: Self.detailButtonMinimumHitSize)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open generation details")
        }
        .frame(maxWidth: .infinity)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.surfaceBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var mediaDurationLabel: String? {
        guard !item.isImage,
              item.status == .completed,
              let duration = item.params.duration,
              duration > 0 else { return nil }
        let minutes = duration / 60
        let seconds = duration % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    private var magicEditorPrompt: String? {
        guard item.params.presetId == "magic-editor",
              let prompt = item.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        return prompt
    }

    // MARK: - Media context menu (long-press)
    // nil while a generation is in flight/failed — the interaction stays inert so a held press
    // does nothing and no empty preview platter is lifted.
    private var mediaContextMenu: UIMenu? {
        guard item.status == .completed else { return nil }
        return UIMenu(children: [
            UIAction(title: "Name as Reference", image: UIImage(systemName: "tag")) { _ in
                onNameAsReference()
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                onRequestDelete()
            }
        ])
    }

    // MARK: - Preset badge thumbnails (D-11/T-09.1-03)
    // Shows the slot media the preset run actually used, in place of the freeform reference
    // thumbnails above — sourced by re-signing `params.preset_input_upload_ids` against the
    // user's own upload library (same GET /api/uploads machinery the Remix fork below reuses),
    // since preset rows don't populate `reference_urls` (that field is driven by `ref_upload_ids`,
    // which the presetResolver never stamps — see aivideostudio-backend generations.ts).
    @ViewBuilder
    private var presetInputThumbnailRow: some View {
        if !presetInputThumbs.isEmpty {
            let visible = Array(presetInputThumbs.prefix(3))
            let overflow = presetInputThumbs.count - visible.count
            HStack(spacing: 3) {
                ForEach(visible) { thumbnail in
                    presetInputThumbnail(thumbnail)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func presetInputThumbnail(_ thumbnail: PresetInputThumbnail) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if thumbnail.isVideo {
                    ZStack {
                        LinearGradient.brandPrimary
                        Image(systemName: "video.fill")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else {
                    if item.params.presetId == "magic-editor", thumbnail.slotIndex == 0 {
                        MagicEditorInputThumbnail(
                            sourceURL: URL(string: thumbnail.url),
                            maskURL: item.magicEditorMaskUrl.flatMap(URL.init(string:)),
                            cacheKey: item.id + "-presetinput-\(thumbnail.slotIndex)"
                        )
                    } else {
                        CachedThumbnailImage(
                            cacheKey: item.id + "-presetinput-\(thumbnail.slotIndex)",
                            url: URL(string: thumbnail.url)
                        )
                    }
                }
            }
            .frame(width: 40, height: 40)

            if let slotLabel = presetSlotLabel(at: thumbnail.slotIndex) {
                Text(slotLabel)
                    // 7pt rasterized to too few device pixels for the all-caps SOURCE badge.
                    // Keep the thumbnail compact, but render the label at a legible native size.
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .allowsTightening(true)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    private func presetSlotLabel(at index: Int) -> String? {
        guard let slots = matchedPreset?.inputSchema?.slots, slots.indices.contains(index) else { return nil }
        let label = slots[index].label.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.params.presetId == "magic-editor" { return "EDIT" }
        return label.isEmpty ? nil : label.uppercased()
    }

    // MARK: - Reference thumbnail row (Issue 4)
    // Hints at what a reference-based generation actually used — ties into the remix flow
    // (Issue 1), where the restored [ImageN]/[VideoN] tokens now visually match these thumbs.
    @ViewBuilder
    private var referenceThumbnailRow: some View {
        if let refs = item.referenceUrls, !refs.isEmpty {
            let visible = Array(refs.prefix(3))
            let overflow = refs.count - visible.count
            HStack(spacing: 3) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, ref in
                    referenceThumbnail(ref, index: index)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func referenceThumbnail(_ ref: GenerationReference, index: Int) -> some View {
        Group {
            if ref.isVideo {
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                                 Color(red: 0.416, green: 0.561, blue: 0.878)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "video.fill")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else {
                CachedThumbnailImage(cacheKey: item.id + "-refthumb-\(index)", url: URL(string: ref.url))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: - Media Content
    @ViewBuilder
    private var mediaContent: some View {
        switch item.status {
        case .pending, .processing:
            ZStack {
                shimmerView
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: animatedProgress)
                            .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.4), value: animatedProgress)
                    }
                    .frame(width: 44, height: 44)
                    Text("\(Int(animatedProgress * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    if let stageLabel = activeStageLabel {
                        Text(stageLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !generationManager.isOnline {
                        Text("Waiting for connection…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let progressMessage {
                        Text(progressMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .completed where revealCompleted:
            if item.isImage {
                // Images: cached UIImage loader (AsyncImage skipped — presigned URLs change per-fetch)
                // scaledToFill makes the image's LAYOUT FRAME larger than the proposed box
                // (not just its drawing), and neither .clipped() nor the parent .clipShape()
                // constrains hit testing — so the invisible overflow above/below the box stole
                // taps from this card's prompt and the previous card's action buttons, opening
                // the wrong generation fullscreen. Color.clear pins the label's frame to the
                // box, allowsHitTesting(false) removes the oversized image from hit testing,
                // and contentShape makes exactly the visible box tappable.
                Color.clear
                    .overlay(alignment: .center) {
                        Group {
                            if let img = cachedImage {
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .transition(.opacity.animation(.easeIn(duration: 0.3)))
                            } else {
                                shimmerView
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { showPlayer = true }
            } else if let thumb = thumbnail {
                // D-16: static thumbnail + play icon overlay
                // Same hit-test containment as the image branch above.
                Color.clear
                    .overlay(alignment: .center) {
                        ZStack {
                            if item.usesTransparencyBackdrop {
                                TransparencyBackdrop()
                            }
                            Image(uiImage: thumb)
                                .resizable().scaledToFill()
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .allowsHitTesting(false)
                    }
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { showPlayer = true }
            } else {
                // Thumbnail not loaded yet — shimmer placeholder
                shimmerView
            }

        case .failed:
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                Text(item.failureMessage ?? "An error has occurred. Your credits have been refunded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.03))

        default:
            Color.white.opacity(0.03)
        }
    }

    private var activeStageLabel: String? {
        guard let raw = item.params.stageLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    // Shimmer: pulsing gradient overlay (premium feel)
    @State private var shimmerOffset: CGFloat = -1
    private var shimmerView: some View {
        ZStack {
            Color.white.opacity(0.03)
            LinearGradient(
                colors: [Color.clear, Color.white.opacity(0.06), Color.clear],
                startPoint: .init(x: shimmerOffset, y: 0),
                endPoint: .init(x: shimmerOffset + 0.5, y: 1)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.5
            }
        }
    }

    // MARK: - Preset Remix fork (D-11/T-09.1-03)

    /// Loads this row's preset input thumbnails once, if this is a preset run. Re-signs the
    /// stored `preset_input_upload_ids` against the shared MediaLibraryManager cache (same list
    /// GET /api/uploads returns, same reference machinery the composer's reference picker
    /// already uses) rather than trusting any stale URL, since presigned URLs rotate per fetch
    /// (documented project landmine) — .load() is cache-first, so this is a no-op network call
    /// once the library has been fetched (within its 300s staleness window).
    private func loadPresetInputThumbnails() {
        guard item.isPreset, let ids = item.params.presetInputUploadIds, !ids.isEmpty,
              presetInputThumbs.isEmpty else { return }
        Task {
            // Current API responses carry exact, freshly-signed preset inputs. Prefer those over
            // the general upload library, whose newest-50 cap can omit inputs used by older cards.
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
            // 09.1-11: `ids` may contain nil (empty optional slot) — compactMap drops those before
            // the lookup, so only actually-filled slots produce a thumbnail.
            presetInputThumbs = ids.enumerated().compactMap { index, id in
                guard let id, let upload = map[id] else { return nil }
                return PresetInputThumbnail(slotIndex: index, url: upload.url, isVideo: upload.isVideo)
            }
        }
    }

    /// Remix fork: Magic Editor restores its mask canvas; other preset rows reopen
    /// PresetInputSheet with stored slot uploads; freeform rows retain the composer flow.
    private func handleRemixTap() {
        if item.params.presetId == "magic-editor" {
            presentMagicEditorRemix()
        } else if item.isPreset {
            presentPresetRemixSheet()
        } else {
            onRemix()
        }
    }

    /// New Magic Editor rows can replay the exact persisted mask in one tap. Rows created before
    /// mask ids were retained cannot be replayed exactly, so route them back to the editor instead
    /// of sending the known-invalid empty-model request that previously made Regen appear dead.
    private func handleRegenerateTap() {
        if item.params.presetId == "magic-editor", item.params.maskUploadId == nil {
            presentMagicEditorRemix()
        } else {
            onRegenerate()
        }
    }

    /// Magic Editor has a freehand canvas rather than a schema-driven preset sheet. Restore the
    /// original source photo (slot 0) and prompt so Remix returns to the state that produced this
    /// generation. Prefer the exact freshly signed URL attached to the generation response;
    /// MediaLibraryManager is only a compatibility fallback for older responses.
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
            // 09.1-11: `id` may be nil (empty optional slot) — leave that slot's entry nil in
            // `slots` so PresetInputSheet reopens with it correctly blank, not misaligned.
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
            presetForRemix = preset   // triggers .fullScreenCover(item:) above
        }
    }

    // MARK: - Action Button Helper
    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void, destructive: Bool = false) -> some View {
        let fg: Color = destructive ? Color.red.opacity(0.85) : (isActive ? theme.textTertiary : theme.textSecondary)
        return Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .disabled(isActive)
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Progress Curve (D-10, D-11, D-12)
    // CLAUDE.md: Swift Concurrency — NO Timer allowed.
    // Deterministic, elapsed-time-driven curve replaces the old random-jitter loop: progress is
    // a pure function of wall-clock time since item.createdAt, so it never freezes, never jumps,
    // and self-corrects across backgrounding/foregrounding for free.
    private func startProgressTicking() {
        let expected = ProgressEstimator.expectedSeconds(for: item)
        let tau = expected * 0.55

        func curveValue(at t: TimeInterval) -> Double {
            0.95 * (1 - exp(-t / tau))
        }

        // Seed immediately so the ring doesn't sit at 0 for the first tick.
        animatedProgress = curveValue(at: Date().timeIntervalSince(item.createdAt))

        jitterTask = Task {
            while !Task.isCancelled && isActive {
                try? await Task.sleep(for: .seconds(0.2))
                guard !Task.isCancelled else { break }

                let t = Date().timeIntervalSince(item.createdAt)
                withAnimation(.linear(duration: 0.2)) {
                    animatedProgress = curveValue(at: t)
                }

                if t > max(3 * expected, 240) {
                    progressMessage = "Hang tight — this one might take a while. We'll notify you when it's ready."
                } else if t > 1.5 * expected {
                    progressMessage = "Taking a bit longer than usual…"
                } else {
                    progressMessage = nil
                }
            }
        }
    }

    // MARK: - Media Loading

    // Awaitable download — used by onChange so 100% only fires when image is in memory
    // Perf: card grid cells decode+cache a downscaled copy under a distinct "-grid" cache key
    // (matches the existing 400x400 cap already used for video thumbnails below) instead of the
    // full-resolution image — GenerationDetailSheet/FullScreenImageView cache the full image
    // separately under the plain item.id key, so they're unaffected by this.
    private func downloadMedia() async {
        if item.isImage {
            guard let urlString = item.completedMediaUrl, let url = URL(string: urlString),
                  cachedImage == nil else { return }
            let gridKey = item.id + "-grid2"  // bumped: bypass stale 400px disk-cached thumbs
            if let cached = await ThumbnailCache.shared.image(for: gridKey) { cachedImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let thumb = image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
            ThumbnailCache.shared[gridKey] = thumb
            cachedImage = thumb
        } else {
            guard let urlString = item.videoUrl, let url = URL(string: urlString) else { return }
            // Download to disk first — extracting the thumbnail frame from the local file
            // avoids a second network round-trip, and (critically) avoids running the frame
            // decode against a remote URL, which is where it used to block.
            let localURL = (try? await VideoCache.shared.ensureCached(id: item.id, remoteURL: url)) ?? url
            if thumbnail == nil {
                if let cached = await ThumbnailCache.shared.image(for: item.id) {
                    thumbnail = cached
                } else {
                    thumbnail = await Self.extractThumbnail(from: localURL, cacheKey: item.id)
                }
            }
        }
    }

    private func loadThumbnail() {
        guard !item.isImage, item.status == .completed,
              let urlString = item.videoUrl, let url = URL(string: urlString),
              thumbnail == nil else { return }
        Task {
            if let cached = await ThumbnailCache.shared.image(for: item.id) { thumbnail = cached; return }
            let localURL = VideoCache.shared.cachedURL(for: item.id) ?? url
            thumbnail = await Self.extractThumbnail(from: localURL, cacheKey: item.id)
        }
    }

    // Async frame extraction — never blocks the calling thread (unlike the old
    // copyCGImage(at:actualTime:), which is synchronous and was being called on the main
    // actor against a remote URL, stalling the UI until the network fetch + decode finished).
    private static func extractThumbnail(from url: URL, cacheKey: String) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 400, height: 400)
        guard let (cgImg, _) = try? await gen.image(at: .zero) else { return nil }
        let image = UIImage(cgImage: cgImg)
        ThumbnailCache.shared[cacheKey] = image
        return image
    }

    private func loadCachedImage() {
        guard item.isImage, item.status == .completed,
              let urlString = item.completedMediaUrl, let url = URL(string: urlString),
              cachedImage == nil else { return }
        let gridKey = item.id + "-grid2"  // bumped: bypass stale 400px disk-cached thumbs
        Task {
            if let cached = await ThumbnailCache.shared.image(for: gridKey) { cachedImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            // Image cards render full-width, so a fixed 400px thumbnail was upscaled ~3x on a
            // modern phone (≈1179px @3x) and looked blurry. Size the downscale to the card's real
            // pixel width instead — crisp on-screen, still bounded (never larger than the source).
            let targetWidth = min(image.size.width * image.scale,
                                  UIScreen.main.bounds.width * UIScreen.main.scale)
            let thumb = image.preparingThumbnail(of: CGSize(width: targetWidth, height: targetWidth)) ?? image
            ThumbnailCache.shared[gridKey] = thumb
            cachedImage = thumb
        }
    }

    // MARK: - Aspect Ratio Helper (D-06)
    private var cardAspectRatio: CGFloat {
        let raw = aspectRatioValue(item.params.aspectRatio ?? (item.isImage ? "1:1" : "16:9"))
        // Clamp between 4:5 (portrait cap) and 16:9 (landscape cap) — matches Instagram/Twitter feed behaviour
        return max(min(raw, 16.0 / 9.0), 4.0 / 5.0)
    }

    private func aspectRatioValue(_ ratio: String) -> CGFloat {
        switch ratio {
        case "16:9": return 16.0 / 9.0
        case "9:16": return 9.0 / 16.0
        case "1:1":  return 1.0
        case "4:3":  return 4.0 / 3.0
        case "3:4":  return 3.0 / 4.0
        default:     return 16.0 / 9.0
        }
    }
}
