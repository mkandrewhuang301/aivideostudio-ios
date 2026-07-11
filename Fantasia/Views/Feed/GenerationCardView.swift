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
    @State private var presetInputThumbs: [ReferenceUploadItem] = []   // re-signed via GET /api/uploads
    @State private var presetForRemix: Preset?                         // drives fullScreenCover(item:)
    @State private var remixPrefillSlots: [PresetSlotInput?] = []
    @State private var isPreparingRemix = false

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    /// Extra tap target below the prompt row — taps that land on the top of the media still
    /// open the detail sheet instead of fullscreen preview.
    private let promptTapExtension: CGFloat = 56
    private var isActive: Bool { item.status == .pending || item.status == .processing }

    /// The registry row matching this generation's stamped preset_id, if any.
    private var matchedPreset: Preset? {
        guard let presetId = item.params.presetId else { return nil }
        return presetRegistry.presets.first { $0.presetId == presetId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Truncated prompt (tap → detail popup, D-29). Chevron + primary text color signal
            // tappability the platform-native way (Settings rows, Music lists).
            // D-11/T-09.1-03: preset-run rows NEVER render item.prompt (the expanded server
            // template) — badge + input thumbnails replace the prompt row entirely.
            Button(action: onTapDetail) {
                if item.isPreset {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                        Text(matchedPreset?.title ?? "Preset")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        presetInputThumbnailRow
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                } else {
                    HStack(spacing: 8) {
                        Text(item.prompt ?? "No prompt")
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        referenceThumbnailRow
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)

            // Aspect-ratio box (D-06: sized to requested aspect ratio)
            Color.clear
                .aspectRatio(cardAspectRatio, contentMode: .fit)
                // Hidden while the long-press preview is lifted so the lifted copy is the only
                // visible image (avoids the "two images" duplicate look).
                .overlay { mediaContent.opacity(isMediaPreviewActive ? 0 : 1) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                .padding(.horizontal, 14)


            // Action buttons (D-09: always visible; disabled/greyed while active). Delete lives
            // on swipe-to-delete + the detail sheet for completed cards — a destructive accent on
            // every card's action row was unwarranted given those two paths already exist. Failed
            // cards have no output to reference, so "Reference" is replaced with a real Delete
            // button here (D-38: Remix/Regenerate/Delete are the active actions on a failed card) —
            // swipe-to-delete alone wasn't a discoverable enough affordance for clearing errors.
            HStack(spacing: 8) {
                actionButton("arrow.2.squarepath", "Remix", action: handleRemixTap)
                actionButton("arrow.clockwise", "Regen", action: onRegenerate)
                if item.status == .failed {
                    actionButton("trash", "Delete", action: onRequestDelete, destructive: true)
                } else {
                    actionButton("paperclip", "Reference", action: onReference)
                }
            }
            .padding(.horizontal, 14)
            // Top padding only (gap to the media above) is smaller than the bottom padding
            // (gap to the card's own bottom edge) — user request to tighten the media-to-actions
            // gap specifically, not the whole row's vertical breathing room.
            .padding(.top, 2)
            .padding(.bottom, 10)
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)

        // Full-screen player (D-16: tap thumbnail → full-screen)
        .fullScreenCover(isPresented: $showPlayer) {
            if item.isImage {
                FullScreenImageView(item: item)
            } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url, generationId: item.id)
            }
        }

        // D-11/T-09.1-03: preset Remix reopens PresetInputSheet prefilled from this row's stored
        // preset_input_upload_ids (re-signed via the existing GET /api/uploads reference
        // machinery) — never the composer (remixGenerationRequested is never posted on this path).
        // .sheet (not .fullScreenCover) so it swipe-down-dismisses like the generation detail
        // pullup (GenerationDetailPagerView) — user request 2026-07-08.
        .sheet(item: $presetForRemix) { preset in
            PresetInputSheet(preset: preset, prefillSlots: remixPrefillSlots)
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
                ForEach(Array(visible.enumerated()), id: \.offset) { index, upload in
                    presetInputThumbnail(upload, index: index)
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
    private func presetInputThumbnail(_ upload: ReferenceUploadItem, index: Int) -> some View {
        Group {
            if upload.isVideo {
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
                CachedThumbnailImage(cacheKey: item.id + "-presetinput-\(index)", url: URL(string: upload.url))
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.surfaceBorder, lineWidth: 0.5))
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
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.surfaceBorder, lineWidth: 0.5))
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
                    if !generationManager.isOnline {
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
                    .overlay {
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
                    .overlay {
                        ZStack {
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
            await mediaLibrary.load()
            let map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // 09.1-11: `ids` may contain nil (empty optional slot) — compactMap drops those before
            // the lookup, so only actually-filled slots produce a thumbnail.
            presetInputThumbs = ids.compactMap { $0 }.compactMap { map[$0] }
        }
    }

    /// Remix fork: preset rows never post `remixGenerationRequested` (which routes freeform
    /// remix to the composer) — they reopen PresetInputSheet directly, prefilled from this row's
    /// stored slot uploads. Freeform rows keep the existing composer-remix behavior unchanged.
    private func handleRemixTap() {
        if item.isPreset {
            presentPresetRemixSheet()
        } else {
            onRemix()
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
            var slots: [PresetSlotInput?] = Array(repeating: nil, count: ids.count)
            await mediaLibrary.load()
            let map = Dictionary(mediaLibrary.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // 09.1-11: `id` may be nil (empty optional slot) — leave that slot's entry nil in
            // `slots` so PresetInputSheet reopens with it correctly blank, not misaligned.
            for (index, id) in ids.enumerated() {
                guard let id, let match = map[id] else { continue }
                slots[index] = PresetSlotInput(
                    uploadId: match.id,
                    url: match.url,
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
        let fg: Color = destructive ? Color.red.opacity(0.85) : (isActive ? theme.textTertiary : theme.textPrimary.opacity(0.8))
        let bg: Color = destructive ? Color.red.opacity(theme.isLight ? 0.07 : 0.10) : (isActive ? theme.surface.opacity(0.6) : theme.surface)
        let border: Color = destructive ? Color.red.opacity(0.12) : (isActive ? theme.divider : theme.surfaceBorder)

        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(bg, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 0.5))
            .contentShape(Rectangle())
            .frame(minHeight: 44)
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
