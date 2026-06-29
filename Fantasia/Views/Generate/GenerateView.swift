// GenerateView.swift
// Fantasia
// Home tab: custom topbar, vertically-centered inspiration content, bottom prompt bar.
// System nav bar is hidden — this view manages its own header and profile sheet.
// Phase 7: options panel, reference media attachment, paywall gate, submit dispatch wired.

import SwiftUI
import PhotosUI
import AVFoundation

struct GenerateView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager

    @State private var promptText = ""
    @State private var showProfileSheet = false
    @FocusState private var promptFocused: Bool

    // D-18: option state with defaults
    @State private var selectedModel = "bytedance/seedance-2.0-fast"
    @State private var selectedDuration = 5
    @State private var selectedResolution = "720p"
    @State private var selectedAspectRatio = "16:9"
    @State private var audioEnabled = true

    // D-20–D-22: reference attachment state
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var referenceMediaData: Data?
    @State private var referenceMimeType: String?
    @State private var referenceThumbnail: UIImage?
    @State private var hasVideoReference = false

    // Paywall and submit state
    @State private var showPaywall = false
    @State private var isSubmitting = false

    // D-26: tab binding for post-submit navigation to Feed (index 0)
    // D-35: also used by Remix pre-fill (Plan 10 wires $selectedTab from MainTabView)
    var selectedTab: Binding<Int>? = nil

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private let suggestions: [(label: String, icon: String, prompt: String)] = [
        ("Anime girl, afternoon", "sparkles",           "Anime girl sitting in a sunlit cafe in the afternoon, soft golden light streaming through the window"),
        ("Underwater city",      "water.waves",        "An ancient sunken city lit by bioluminescent coral, camera drifting through archways"),
        ("Rainy street",         "cloud.rain.fill",    "A cobblestone street at night, warm lamplight reflecting in puddles, soft rain falling"),
        ("Space station",        "moon.stars.fill",    "Astronaut floating outside a space station, Earth glowing below"),
        ("Cherry blossom park",  "leaf.fill",          "A serene Japanese park in spring, cherry blossoms drifting in a gentle breeze"),
    ]

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerContent
                Spacer().frame(height: 278) // push chips up toward screen center
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                // D-17: options panel always visible above the prompt bar
                GenerationOptionsPanel(
                    selectedModel: $selectedModel,
                    selectedDuration: $selectedDuration,
                    selectedResolution: $selectedResolution,
                    selectedAspectRatio: $selectedAspectRatio,
                    audioEnabled: $audioEnabled,
                    hasVideoReference: hasVideoReference
                )
                promptBar
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
        }
        // D-27: PaywallView as fullScreenCover when credits == 0 or entitlementLevel == .none
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(isPresented: $showPaywall)
                .environment(creditManager)
        }
        // D-24: load media data when picker selection changes
        .onChange(of: selectedPickerItem) { _, newItem in
            Task {
                guard let item = newItem else { clearReference(); return }
                // loadTransferable(type: Data.self) — more reliable than URL for videos (RESEARCH.md Pitfall 8)
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let contentTypes = item.supportedContentTypes
                let isVideo = contentTypes.contains(.movie) || contentTypes.contains(.mpeg4Movie)
                if isVideo {
                    // D-24: transcode HEVC to H.264 if needed (RESEARCH.md Pitfall 1)
                    let tmpInput = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString).tmp")
                    try? data.write(to: tmpInput)
                    let finalUrl = try? await transcodeToH264IfNeeded(url: tmpInput)
                    let finalData = (try? Data(contentsOf: finalUrl ?? tmpInput)) ?? data
                    referenceMediaData = finalData
                    referenceMimeType = "video/mp4"
                    hasVideoReference = true
                    // Generate thumbnail from first frame of video
                    let thumbUrl = finalUrl ?? tmpInput
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: thumbUrl))
                    generator.appliesPreferredTrackTransform = true
                    if let cgImg = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                        referenceThumbnail = UIImage(cgImage: cgImg)
                    }
                } else {
                    referenceMediaData = data
                    referenceMimeType = "image/jpeg"
                    hasVideoReference = false
                    if let uiImage = UIImage(data: data) {
                        referenceThumbnail = uiImage
                    }
                }
            }
        }
        // D-35: Remix pre-fill on appear — reads pendingRemix from GenerationManager
        .onAppear {
            if let remix = generationManager.pendingRemix {
                promptText = remix.prompt ?? ""
                selectedModel = remix.model
                selectedDuration = remix.params.duration
                selectedResolution = remix.params.resolution
                selectedAspectRatio = remix.params.aspectRatio
                audioEnabled = remix.params.audioEnabled
                // D-35: does NOT pre-fill attachment
                generationManager.pendingRemix = nil
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.09, green: 0.085, blue: 0.105)
                .ignoresSafeArea()

            RadialGradient(
                colors: [accent.opacity(0.13), .clear],
                center: .init(x: 0.1, y: 0.0),
                startRadius: 0,
                endRadius: 340
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Top bar (hamburger + brand left, credit ring right)

    private var topBar: some View {
        HStack(alignment: .center, spacing: 11) {
            Button { } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            // Brand mark + name
            HStack(spacing: 8) {
                Image("LogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Fantasia")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .kerning(-0.16)
            }

            Spacer()

            // Credit ring — opens profile / credit sheet
            Button {
                showProfileSheet = true
            } label: {
                CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 36)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    // MARK: - Center inspiration content

    private var centerContent: some View {
        VStack(spacing: 20) {
            Text("What will you create?")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            chipRow
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggestions, id: \.label) { item in
                    Button {
                        promptText = item.prompt
                        promptFocused = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(accent.opacity(0.9))
                            Text(item.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 48)
            }
        )
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        HStack(alignment: .center, spacing: 8) {
            // D-20: paperclip opens PhotosPicker for images + videos
            PhotosPicker(
                selection: $selectedPickerItem,
                matching: .any(of: [.images, .videos])
            ) {
                Image(systemName: "paperclip")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // D-22: reference thumbnail (32x32pt) with dismiss button — shown when attachment present
            if let thumb = referenceThumbnail {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button { clearReference() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .offset(x: 4, y: -4)
                }
            }

            // Text input — grows up to 5 lines
            TextField("Describe a scene...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(accent)
                .focused($promptFocused)

            // D-27/D-28: generate button — paywall gate when credits == 0 or no entitlement
            Button {
                promptFocused = false
                guard creditManager.creditsBalance > 0 && creditManager.entitlementLevel != .none else {
                    showPaywall = true
                    return
                }
                Task { await dispatchGeneration() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        // D-28: desaturated gradient when credits == 0 (still tappable — opens paywall)
                        creditManager.creditsBalance > 0
                            ? LinearGradient(
                                colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                                         Color(red: 0.357, green: 0.561, blue: 0.851)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                              )
                            : LinearGradient(
                                colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                              )
                    )
                    .clipShape(Circle())
                    .opacity(isSubmitting ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 72) // clear tab bar + diamond raise + comfortable gap
    }

    // MARK: - Submit dispatch

    // D-25: lazy upload on submit (not on pick) — upload reference media then POST generation
    private func dispatchGeneration() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            var refImages: [String]? = nil
            var refVideos: [String]? = nil

            if let data = referenceMediaData, let mime = referenceMimeType {
                let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
                let fileName = mime.contains("video") ? "reference.mp4" : "reference.\(ext)"
                let uploadResponse = try await APIClient.shared.uploadReferenceMedia(
                    data: data, mimeType: mime, fileName: fileName
                )
                if mime.contains("video") {
                    refVideos = [uploadResponse.url]
                } else {
                    refImages = [uploadResponse.url]
                }
            }

            let body = GenerationRequestBody(
                prompt: promptText,
                model: selectedModel,
                duration: selectedDuration,
                resolution: selectedResolution,
                aspectRatio: selectedAspectRatio,
                audioEnabled: audioEnabled,
                referenceImages: refImages,
                referenceVideos: refVideos
            )
            _ = try await APIClient.shared.submitGeneration(body: body)

            // Clear input state after successful submission
            promptText = ""
            clearReference()
            await generationManager.refresh()

            // D-26: switch to Feed tab (index 0) so user sees the new pending job
            selectedTab?.wrappedValue = 0

        } catch {
            print("[GenerateView] dispatch error: \(error)")
        }
    }

    private func clearReference() {
        selectedPickerItem = nil
        referenceMediaData = nil
        referenceMimeType = nil
        referenceThumbnail = nil
        hasVideoReference = false
    }
}

// MARK: - HEVC transcoding helper (file scope, not inside struct)
// RESEARCH.md Pattern 5 — iOS 17: must use exportAsynchronously (NOT iOS 18+ export(to:as:))
// withCheckedThrowingContinuation wraps the callback-based API for Swift Concurrency compatibility

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: self.error ?? NSError(domain: "AVExport", code: -1))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: NSError(domain: "AVExport", code: -1))
                }
            }
        }
    }
}

@MainActor
private func transcodeToH264IfNeeded(url: URL) async throws -> URL {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { return url }
    let descs = try await track.load(.formatDescriptions)
    let isHEVC = descs.contains {
        CMFormatDescriptionGetMediaSubType($0 as! CMFormatDescription) == kCMVideoCodecType_HEVC
    }
    guard isHEVC else { return url }

    let tmpURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp4")
    guard let session = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
    ) else {
        throw NSError(domain: "AVExport", code: -1)
    }
    session.outputURL = tmpURL
    session.outputFileType = .mp4
    try await session.exportAsync()
    return tmpURL
}

#Preview {
    NavigationStack {
        GenerateView()
    }
    .environment(CreditManager())
    .environment(AuthManager())
    .environment(GenerationManager())
    .preferredColorScheme(.dark)
}
