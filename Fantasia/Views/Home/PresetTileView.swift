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
    // How much of the source to zoom into. 1.0 = show the full source width (no horizontal crop);
    // >1 crops in horizontally too (e.g. the 3:4 grid tile zooms to 1.65 for a head-focused
    // portrait). Higher = tighter/bigger subject.
    var zoom: CGFloat = 1.0
    // Which source row sits at the tile's TOP edge, as a fraction of source height (0 = very top,
    // 0.5 = middle). Loops are portrait people-videos: head up top, torso filling the lower half.
    // Trimming a little off the top (e.g. 0.125) drops dead ceiling above the hair without cutting
    // the hairline; 0 keeps the whole top (used by the input-sheet cover).
    // nil = center vertically — the historical default, preserved for the hero / Avatar Center /
    // Shows & Vlogs cards, whose wide/square boxes want the subject's FACE centered, not its top.
    var focalTop: CGFloat? = nil

    @State private var poster: UIImage?
    @State private var loopState = LoopTileState()

    // All registry loop assets are ingested at native portrait 9:16 (uploadPresetArt.ts's
    // transcodeLoop only ever downscales within a portrait bounding box, preserving source AR) —
    // hardcoding avoids a poster/video decode round-trip just to learn an AR we control at
    // ingestion time.
    private let sourceAspectRatio: CGFloat = 9.0 / 16.0

    var body: some View {
        GeometryReader { geo in
            // Render the media at (geo * zoom), preserving source AR, then window into it by
            // offset + clip. This draws at FULL resolution for the zoom level (SwiftUI resamples
            // the source into this larger frame) — unlike `.scaleEffect`, which rasterizes at the
            // small tile size FIRST and then magnifies that bitmap, producing upscale blur even
            // from a hi-res source (user-reported 2026-07-08: blurry after delete+reinstall, i.e.
            // not a cache issue — the source frame is sharp, scaleEffect was softening it).
            let contentW = geo.size.width * zoom
            let contentH = contentW / sourceAspectRatio        // preserve source 9:16
            let offsetX = -(contentW - geo.size.width) / 2       // center horizontally
            // focalTop set → put that source row at the top edge; nil → center the overflow.
            let offsetY = focalTop.map { -$0 * contentH } ?? -(contentH - geo.size.height) / 2

            ZStack {
                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.06)
                }
                if let player = loopState.player {
                    // Hard cut, no crossfade (user request 2026-07-08) — video simply replaces
                    // the poster the instant it's ready, no animation.
                    FillingVideoPlayerView(player: player, videoGravity: .resizeAspectFill)
                        .opacity(loopState.isReady ? 1 : 0)
                }
            }
            .frame(width: contentW, height: contentH)
            .offset(x: offsetX, y: offsetY)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .onAppear {
            loadPoster()
        }
        // Keyed on availabilityGeneration (not a plain onAppear Task): runs immediately when the
        // tile appears (covers the original acquire-on-appear), AND re-runs every time the pool
        // frees a slot elsewhere — the only way a tile that was denied a player (pool full of
        // active slots, see LoopPlayerPool) later upgrades from poster-only to actually playing.
        // Guarded on `loopState.player == nil` so tiles that already have a player don't
        // needlessly re-acquire on every unrelated release() elsewhere (2026-07-08).
        .task(id: LoopPlayerPool.shared.availabilityGeneration) {
            guard loopState.player == nil, let url = preset.tile.loopURL else { return }
            if let player = await LoopPlayerPool.shared.acquire(presetId: preset.id, loopURL: url) {
                loopState.attach(player)
            }
        }
        .onDisappear {
            LoopPlayerPool.shared.release(presetId: preset.id)
            loopState.detach()
        }
    }

    private func loadPoster() {
        guard poster == nil, let url = preset.tile.posterURL else { return }
        // Key includes the URL's filename (e.g. poster-v2.jpg), mirroring LoopFileCache's
        // versioned key below — the ingestion script's version-suffixed filenames give free
        // cache-busting on re-ingestion. Without this, re-ingesting a preset's art (e.g. the
        // 2026-07-08 resolution fix) silently kept serving the OLD cached poster forever, since
        // a bare "presetId-poster" key never changes when the server URL does (user-reported:
        // still blurry after the server-side fix deployed — root cause was this stale client
        // cache, not the server data).
        let versionedKey = preset.id + "-poster-" + url.lastPathComponent
        // Preset-scoped (NOT version-scoped) fallback: whatever poster last successfully loaded
        // for this preset, however old. Shown immediately on any versioned-cache miss — first
        // launch after a version bump, a slow/offline network, whatever — so the tile never
        // shows a blank placeholder while the current version fetches in the background
        // (user request 2026-07-08: "even if the video is loading it is the first image rather
        // than nothing").
        let latestKey = preset.id + "-poster-latest"
        Task {
            if let cached = await ThumbnailCache.shared.image(for: versionedKey) {
                poster = cached
                return
            }
            if let stale = await ThumbnailCache.shared.image(for: latestKey) {
                poster = stale
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            ThumbnailCache.shared[versionedKey] = image
            ThumbnailCache.shared[latestKey] = image
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
                // Head-focused portrait crop: zoom 1.65 into the source, top edge at 12.5% of
                // source height → shows ~hair(14%)-through-chin(58%), trimming ceiling above the
                // hair and torso below. This is the SAME visible framing the old
                // `.scaleEffect(1.65, anchor: .top)` produced, but rendered at full source
                // resolution instead of magnifying a tile-sized bitmap (which was the blur — see
                // PresetLoopBackground body). Do NOT reintroduce scaleEffect here.
                PresetLoopBackground(preset: preset, zoom: 1.65, focalTop: 0.125)
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
