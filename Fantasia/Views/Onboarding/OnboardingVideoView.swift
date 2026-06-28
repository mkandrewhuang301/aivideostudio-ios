// OnboardingVideoView.swift
// Fantasia
// Onboarding screen 1: Full-bleed bundled video with gradient fallback.
// D-12: autoplay, loop, muted, no controls. Falls back to LinearGradient if asset missing.
// RESEARCH.md Pitfall 7: AVPlayer nil URL is handled gracefully.

import SwiftUI
import AVKit
import AVFoundation

// FillingVideoPlayerView wraps AVPlayerLayer directly with videoGravity = .resizeAspectFill.
// SwiftUI's VideoPlayer defaults to aspect-fit (letterboxes when the video's aspect ratio
// doesn't match the screen) — this fills edge-to-edge instead, cropping as needed.
struct FillingVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

// LoopingPlayerViewModel manages AVQueuePlayer + AVPlayerLooper for seamless looping.
// AVPlayerLooper requires AVQueuePlayer (not AVPlayer). Purpose-built for this pattern.
@Observable
@MainActor
final class LoopingPlayerViewModel {
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    var hasVideo: Bool = false

    init(videoName: String) {
        player = AVQueuePlayer()
        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mp4") else {
            // Asset not yet bundled — gradient fallback shows (RESEARCH.md Pitfall 7)
            return
        }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.play()
        hasVideo = true
    }
}

// PromptCaptionController drives the typewriter-style "generated from prompt" caption,
// synced to scene cuts via AVPlayer's periodic time observer (sampled every 50ms) — much
// tighter sync than a web <video>'s timeupdate event, which fires too infrequently to feel
// exact against fast cuts.
@Observable
@MainActor
final class PromptCaptionController {
    struct Scene {
        let start: Double
        let caption: String
    }

    private let scenes: [Scene]
    var displayedText: String = ""
    var caretVisible: Bool = true
    var currentSceneIndex: Int = -1

    var sceneCount: Int { scenes.count }

    private var typingTask: Task<Void, Never>?
    private var caretTask: Task<Void, Never>?
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?

    init(scenes: [Scene]) {
        self.scenes = scenes
    }

    func attach(to player: AVPlayer) {
        guard timeObserver == nil else { return }
        observedPlayer = player
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.update(currentTime: time.seconds)
            }
        }
    }

    func detach() {
        if let timeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        typingTask?.cancel()
        caretTask?.cancel()
    }

    private func update(currentTime: Double) {
        guard !scenes.isEmpty else { return }
        var idx = 0
        for (i, scene) in scenes.enumerated() where currentTime >= scene.start { idx = i }
        guard idx != currentSceneIndex else { return }
        currentSceneIndex = idx
        startTyping(text: scenes[idx].caption)
    }

    private func startTyping(text: String) {
        typingTask?.cancel()
        caretTask?.cancel()
        displayedText = ""
        caretVisible = true
        typingTask = Task { [weak self] in
            guard let self else { return }
            for i in 0...text.count {
                if Task.isCancelled { return }
                let endIndex = text.index(text.startIndex, offsetBy: i)
                self.displayedText = String(text[..<endIndex])
                try? await Task.sleep(for: .milliseconds(22))
            }
            self.startCaretBlink()
        }
    }

    private func startCaretBlink() {
        caretTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(530))
                self.caretVisible.toggle()
            }
        }
    }
}

struct OnboardingVideoView: View {
    var onContinue: () -> Void

    @State private var videoViewModel = LoopingPlayerViewModel(videoName: "onboarding-sample")

    // Cut timestamps detected from the actual bundled video (ffmpeg scene-change detection,
    // re-run at a lower threshold to catch the motorcycle→dragon cut at 2.23s and the
    // whale→anime cut at 11.7s that the first pass missed) — keeps the caption switching
    // exactly on each cut. Every caption must stay one line — verified against the chip width.
    @State private var captionController = PromptCaptionController(scenes: [
        .init(start: 0.0,    caption: "Man riding motorcycle through the open desert"),
        .init(start: 2.2333, caption: "Dragon breathing fire over a burning battlefield"),
        .init(start: 4.27,   caption: "Car tire splashing through puddles in the rain"),
        .init(start: 7.03,   caption: "Figure skater gliding across a frozen winter lake"),
        .init(start: 9.5,    caption: "Bioluminescent whale breaching on a starry night"),
        .init(start: 11.7,   caption: "Anime boy steps through a door portal into a mystical world"),
        .init(start: 14.57,  caption: "Woman in a gown twirling outside a stone villa"),
        .init(start: 17.53,  caption: "Animated baby squirrel running through a meadow"),
        .init(start: 20.23,  caption: "Kung fu masters fighting on ancient temple steps"),
        .init(start: 22.63,  caption: "HS football player gearing up on game day"),
    ])

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private let backgroundGradient = LinearGradient(
        colors: [Color(red: 0.059, green: 0.059, blue: 0.067),
                 Color(red: 0.04, green: 0.04, blue: 0.05)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        ZStack {
            // Layer 1: Background gradient (always visible — shows if video is missing)
            backgroundGradient
                .ignoresSafeArea()

            // Layer 2: AVPlayer video (only if asset is available)
            if videoViewModel.hasVideo {
                FillingVideoPlayerView(player: videoViewModel.player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true) // Decorative content (UI-SPEC accessibility)
                    .onDisappear {
                        videoViewModel.player.pause()
                    }
            }

            // Layer 3: Plain dark gradient scrim for text legibility — no blur, just a
            // gradient fade like the reference demo. Only the Continue button keeps glass.
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.95)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.4)
                .ignoresSafeArea()
            }

            // Layer 4: Typewriter "generated from prompt" caption, pinned near the top
            // OnboardingView wraps this whole screen in .ignoresSafeArea(), which zeroes
            // out the safe-area top inset here too — padding has to clear the status bar /
            // Dynamic Island manually instead of relying on the system inset.
            VStack {
                promptChip
                    .padding(.horizontal, 20)
                    .padding(.top, 78)
                Spacer()
            }

            // Layer 5: Wordmark + tagline + Continue button, pinned to bottom
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fantasia")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Bring your creativity to life.")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 24)

                Spacer().frame(height: 32) // xl

                Button {
                    onContinue()
                } label: {
                    Text("Continue →")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background {
                            ZStack {
                                Color.white.opacity(0.15)
                                Rectangle().fill(.ultraThinMaterial)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        }
                }
                .accessibilityLabel("Continue to next step")
                .padding(.horizontal, 24)
                .padding(.bottom, 10) // nudges the button up, away from the dots below

                sceneDots
                    .padding(.top, 14)
                    .padding(.bottom, 48)
            }
        }
        .onAppear {
            if videoViewModel.hasVideo {
                captionController.attach(to: videoViewModel.player)
            }
        }
        .onDisappear {
            captionController.detach()
        }
    }

    private var sceneDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<captionController.sceneCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == captionController.currentSceneIndex ? 1 : 0.3))
                    .frame(width: index == captionController.currentSceneIndex ? 16 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.25), value: captionController.currentSceneIndex)
    }

    private var promptChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
                Text("prompt")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .tracking(1.2)
                    .textCase(.uppercase)
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(captionController.displayedText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.92))
                Rectangle()
                    .fill(.white.opacity(0.7))
                    .frame(width: 1.5, height: 14)
                    .opacity(captionController.caretVisible ? 1 : 0)
            }
            .frame(height: 20, alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
    }
}
