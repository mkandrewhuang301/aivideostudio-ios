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

struct GenerationCardView: View {
    let item: GenerationItem
    var onTapDetail: () -> Void      // tap prompt text → detail sheet (D-29)
    var onRemix: () -> Void          // D-35
    var onRegenerate: () -> Void     // D-36
    var onReference: () -> Void      // use this generation's output as a reference input
    var onNameAsReference: () -> Void  // long-press → promote this output into the permanent reference library
    var onDelete: () -> Void         // D-37

    @Environment(ThemeManager.self) private var theme

    @State private var animatedProgress: Double = 0
    @State private var jitterTask: Task<Void, Never>? = nil
    @State private var showDelayMessage = false   // D-12: "Taking a bit longer..."
    @State private var showDeleteAlert = false
    @State private var thumbnail: UIImage? = nil
    @State private var showPlayer = false
    @State private var revealCompleted = false    // gates media reveal after fill-to-100 animation
    @State private var cachedImage: UIImage? = nil  // for image generations

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private var isActive: Bool { item.status == .pending || item.status == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Truncated prompt (tap → detail popup, D-29). Chevron + primary text color signal
            // tappability the platform-native way (Settings rows, Music lists).
            Button(action: onTapDetail) {
                HStack(spacing: 8) {
                    Text(item.prompt ?? "No prompt")
                        .font(.callout)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Aspect-ratio box (D-06: sized to requested aspect ratio)
            Color.clear
                .aspectRatio(cardAspectRatio, contentMode: .fit)
                .overlay { mediaContent }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)
                .contextMenu {
                    if item.status == .completed {
                        Button("Name as reference", systemImage: "tag") { onNameAsReference() }
                    }
                }


            // Action buttons (D-09: always visible; disabled/greyed while active)
            HStack(spacing: 8) {
                actionButton("arrow.2.squarepath", "Remix", isDestructive: false, action: onRemix)
                actionButton("arrow.clockwise", "Regen", isDestructive: false, action: onRegenerate)
                actionButton("paperclip", "Reference", isDestructive: false, action: onReference)
                actionButton("trash", "Delete", isDestructive: true) { showDeleteAlert = true }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

        // Delete confirmation alert (D-37)
        .alert(item.isImage ? "Delete this image?" : "Delete this video?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }

        // Progress jitter lifecycle (D-10, D-11) — Task.sleep, not Timer
        .onAppear {
            loadThumbnail()
            loadCachedImage()
            if isActive {
                startProgressJitter()
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
                    if showDelayMessage {
                        Text("Taking a bit longer...")
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
                Button { showPlayer = true } label: {
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
                }
                .buttonStyle(.plain)
            } else if let thumb = thumbnail {
                // D-16: static thumbnail + play icon overlay
                // Same hit-test containment as the image branch above.
                Button { showPlayer = true } label: {
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
                }
                .buttonStyle(.plain)
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

    // MARK: - Action Button Helper
    private func actionButton(_ icon: String, _ label: String, isDestructive: Bool, action: @escaping () -> Void) -> some View {
        let fg: Color = isActive
            ? theme.textTertiary
            : isDestructive ? Color.red.opacity(0.85) : theme.textPrimary.opacity(0.8)
        let bg: Color = isActive
            ? theme.surface.opacity(0.6)
            : isDestructive ? Color.red.opacity(0.1) : theme.surface
        let border: Color = isActive
            ? theme.divider
            : isDestructive ? Color.red.opacity(0.25) : theme.surfaceBorder

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
        .buttonStyle(.plain)
    }

    // MARK: - Progress Jitter (D-10, D-11, D-12)
    // CLAUDE.md: Swift Concurrency — NO Timer allowed
    private func startProgressJitter() {
        // Seed from elapsed time, capped at 0.80 so the jitter has room to breathe
        let expectedDuration: Double = item.model.contains("grok") ? 20 : (item.model.contains("mini") ? 75 : 45)
        let elapsed = Date().timeIntervalSince(item.createdAt)
        animatedProgress = min(elapsed / expectedDuration * 0.85, 0.80)

        var timeStuckHigh: Date? = nil

        jitterTask = Task {
            while !Task.isCancelled && isActive {
                // D-11: random sleep interval 1.5–2.5s
                let sleepSecs = Double.random(in: 1.5...2.5)
                try? await Task.sleep(for: .seconds(sleepSecs))

                guard !Task.isCancelled else { break }

                // Asymptotic decay: each tick advances a fraction of the remaining gap to 0.99.
                // Near 0% the increment is large; near 99% it becomes imperceptibly small —
                // so the bar keeps moving without ever visually freezing at the ceiling.
                let gap = 0.99 - animatedProgress
                let increment = gap * Double.random(in: 0.04...0.09)
                animatedProgress = min(animatedProgress + increment, 0.99)

                // D-12: show delay message after 20s looking "stuck" near the ceiling
                if animatedProgress >= 0.95 {
                    if timeStuckHigh == nil { timeStuckHigh = Date() }
                    if let since = timeStuckHigh, Date().timeIntervalSince(since) > 20 {
                        showDelayMessage = true
                    }
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
            let gridKey = item.id + "-grid"
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
        let gridKey = item.id + "-grid"
        Task {
            if let cached = await ThumbnailCache.shared.image(for: gridKey) { cachedImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let thumb = image.preparingThumbnail(of: CGSize(width: 400, height: 400)) ?? image
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
