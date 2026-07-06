// PresetTileView.swift
// Fantasia
// Poster-first, muted autoplaying loop tile for the Home preset grid (D-08, v10 mockup). Every
// tile shows its poster instantly; the loop fades in only once it is on-screen AND fully cached
// (Option A — no spinner/shimmer, ever). SOON tiles render desaturated with a SOON pill purely
// from registry status (D-04); NEW/HOT badges are server-driven (D-06).

import SwiftUI
import AVFoundation

// Shared poster+loop media background used by every registry-driven Home card (grid tiles,
// hero, Avatar Center row, Shows & Vlogs cards) — callers add their own overlays/hit-test/tap.
struct PresetLoopBackground: View {
    let preset: Preset

    @State private var poster: UIImage?
    @State private var loopState = LoopTileState()

    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.06)
            }
            if let player = loopState.player {
                FillingVideoPlayerView(player: player, videoGravity: .resizeAspectFill)
                    .opacity(loopState.isReady ? 1 : 0)
                    .animation(.easeIn(duration: 0.35), value: loopState.isReady)
            }
        }
        .onAppear {
            loadPoster()
            Task {
                guard let url = preset.tile.loopURL else { return }
                if let player = await LoopPlayerPool.shared.acquire(presetId: preset.id, loopURL: url) {
                    loopState.attach(player)
                }
            }
        }
        .onDisappear {
            LoopPlayerPool.shared.release(presetId: preset.id)
            loopState.detach()
        }
    }

    private func loadPoster() {
        guard poster == nil, let url = preset.tile.posterURL else { return }
        let key = preset.id + "-poster"
        Task {
            if let cached = await ThumbnailCache.shared.image(for: key) {
                poster = cached
                return
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            ThumbnailCache.shared[key] = image
            poster = image
        }
    }
}

// Tracks the acquired pool player + its readiness (first frame decoded), owned per-card so the
// fade-in only triggers once THIS card's player is actually ready, not just non-nil.
@Observable
@MainActor
final class LoopTileState {
    private(set) var player: AVQueuePlayer?
    private(set) var isReady = false
    private var statusObservation: NSKeyValueObservation?

    func attach(_ player: AVQueuePlayer) {
        guard self.player !== player else { return }
        self.player = player
        isReady = false
        statusObservation = player.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] player, _ in
            guard player.currentItem?.status == .readyToPlay else { return }
            Task { @MainActor in self?.isReady = true }
        }
    }

    func detach() {
        statusObservation = nil
        player = nil
        isReady = false
    }
}

struct PresetTileView: View {
    let preset: Preset
    var onTap: (Preset) -> Void = { _ in }

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                PresetLoopBackground(preset: preset)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { titleScrim }
            .overlay(alignment: .topLeading) { badgeView }
            .saturation(preset.isSoon ? 0.55 : 1)
            .brightness(preset.isSoon ? -0.12 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture {
                guard !preset.isSoon else { return }
                onTap(preset)
            }
    }

    private var titleScrim: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                .frame(height: 56)
            Text(preset.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var badgeView: some View {
        if preset.isSoon {
            badgeText("SOON", background: AnyShapeStyle(Color.white.opacity(0.14)))
        } else if let badge = preset.badge {
            badgeText(badge, background: badgeStyle(for: badge))
        }
    }

    private func badgeStyle(for badge: String) -> AnyShapeStyle {
        if badge == "HOT" {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.84, green: 0.38, blue: 0.43), Color(red: 0.85, green: 0.54, blue: 0.36)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(LinearGradient(
            colors: [Color(red: 0.545, green: 0.427, blue: 0.839), Color(red: 0.357, green: 0.561, blue: 0.851)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
    }

    private func badgeText(_ text: String, background: AnyShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.7)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .padding(8)
            .allowsHitTesting(false)
    }
}
