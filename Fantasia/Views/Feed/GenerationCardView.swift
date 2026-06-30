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
    var onDelete: () -> Void         // D-37

    @State private var animatedProgress: Double = 0
    @State private var jitterTask: Task<Void, Never>? = nil
    @State private var showDelayMessage = false   // D-12: "Taking a bit longer..."
    @State private var showDeleteAlert = false
    @State private var thumbnail: UIImage? = nil
    @State private var showPlayer = false

    private let accent = Color(red: 0.545, green: 0.427, blue: 0.839)
    private var isActive: Bool { item.status == .pending || item.status == .processing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Truncated prompt (tap → detail popup, D-29)
            Button(action: onTapDetail) {
                Text(item.prompt ?? "No prompt")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Aspect-ratio box (D-06: sized to requested aspect ratio)
            Color.clear
                .aspectRatio(aspectRatioValue(item.params.aspectRatio ?? "16:9"), contentMode: .fit)
                .overlay { mediaContent }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)

            // Circular progress (shown only for active jobs)
            if isActive {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 3)
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
                        Text("Taking a bit longer than expected...")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            // Action buttons (D-09: always visible; disabled/greyed while active)
            HStack(spacing: 0) {
                actionButton("arrow.2.squarepath", "Remix", action: onRemix)
                actionButton("arrow.clockwise", "Regen", action: onRegenerate)
                actionButton("trash", "Delete") {
                    showDeleteAlert = true     // D-37: confirmation before delete
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)

        // Full-screen player (D-16: tap video thumbnail → full-screen)
        .fullScreenCover(isPresented: $showPlayer) {
            if let urlString = item.videoUrl, let url = URL(string: urlString) {
                FullScreenVideoPlayerView(videoUrl: url)
            }
        }

        // Delete confirmation alert (D-37)
        .alert("Delete this video?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }

        // Progress jitter lifecycle (D-10, D-11) — Task.sleep, not Timer
        .onAppear {
            loadThumbnail()
            if isActive { startProgressJitter() }
        }
        .onDisappear { jitterTask?.cancel() }
        .onChange(of: item.status) { _, newStatus in
            if newStatus != .pending && newStatus != .processing {
                jitterTask?.cancel()
                jitterTask = nil
                animatedProgress = newStatus == .completed ? 1.0 : animatedProgress
            }
        }
    }

    // MARK: - Media Content
    @ViewBuilder
    private var mediaContent: some View {
        switch item.status {
        case .pending, .processing:
            // D-07: shimmer pulse animation
            shimmerView

        case .completed:
            // D-16: static thumbnail + play icon overlay
            if let thumb = thumbnail {
                Button { showPlayer = true } label: {
                    ZStack {
                        Image(uiImage: thumb)
                            .resizable().scaledToFill()
                            .clipped()
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white.opacity(0.85))
                    }
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
                Text("Your prompt may not adhere to our community guidelines. Please try again.")
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
    private func actionButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isActive ? Color.white.opacity(0.25) : Color.white.opacity(0.7))
        }
        .disabled(isActive)
        .buttonStyle(.plain)
    }

    // MARK: - Progress Jitter (D-10, D-11, D-12)
    // CLAUDE.md: Swift Concurrency — NO Timer allowed
    private func startProgressJitter() {
        // Seed from elapsed time (D-10: elapsed / expected_duration)
        let expectedDuration: Double = item.model.contains("mini") ? 75 : 45
        let elapsed = Date().timeIntervalSince(item.createdAt)
        animatedProgress = min(elapsed / expectedDuration, 0.99)

        var timeAt99: Date? = nil

        jitterTask = Task {
            while !Task.isCancelled && isActive {
                // D-11: random sleep interval 1.5–2.5s
                let sleepSecs = Double.random(in: 1.5...2.5)
                try? await Task.sleep(for: .seconds(sleepSecs))

                guard !Task.isCancelled else { break }

                let p = animatedProgress
                let jump: Double
                if p < 0.40 { jump = Double.random(in: 0.03...0.06) }
                else if p < 0.70 { jump = Double.random(in: 0.01...0.03) }
                else { jump = Double.random(in: 0.005...0.015) }

                animatedProgress = min(p + jump, 0.99)  // hard cap at 99%

                // D-12: after 15s at 99%, show delay message
                if animatedProgress >= 0.99 {
                    if timeAt99 == nil { timeAt99 = Date() }
                    if let since = timeAt99, Date().timeIntervalSince(since) > 15 {
                        showDelayMessage = true
                    }
                }
            }
        }
    }

    // MARK: - Thumbnail (first frame from video URL)
    private func loadThumbnail() {
        guard item.status == .completed, let urlString = item.videoUrl,
              let url = URL(string: urlString), thumbnail == nil else { return }
        Task {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 400, height: 400)
            if let cgImg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                thumbnail = UIImage(cgImage: cgImg)
            }
        }
    }

    // MARK: - Aspect Ratio Helper (D-06)
    private func aspectRatioValue(_ ratio: String) -> CGFloat {
        switch ratio {
        case "16:9": return 16.0 / 9.0
        case "9:16": return 9.0 / 16.0
        case "1:1":  return 1.0
        case "4:3":  return 4.0 / 3.0
        default:     return 16.0 / 9.0
        }
    }
}
