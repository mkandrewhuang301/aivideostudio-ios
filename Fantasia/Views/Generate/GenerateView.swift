// GenerateView.swift
// Fantasia
// Chat-style generation hub: prompt bar pinned at bottom, generations scroll upward above it.
// Empty state shows inspiration chips. No separate Feed tab — everything lives here.

import SwiftUI
import PhotosUI
import AVFoundation

struct GenerateView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(RatesManager.self) private var ratesManager

    @State private var promptText = ""
    @State private var showProfileSheet = false
    @FocusState private var promptFocused: Bool

    // D-18: option state with defaults
    @State private var selectedMode = "AI Video"
    @State private var selectedModel = "bytedance/seedance-2.0-mini"
    @State private var selectedDuration = 6
    @State private var selectedResolution = "720p"
    @State private var selectedAspectRatio = "9:16"
    @State private var audioEnabled = true
    @State private var showOptions = false

    // Reference attachment state
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var referenceMediaData: Data?        // non-nil = needs upload on submit
    @State private var referenceURL: String?            // presigned URL (library item or post-upload)
    @State private var referenceUploadId: String?       // reference_uploads UUID for remix/regen
    @State private var referenceMimeType: String?
    @State private var referenceThumbnail: UIImage?
    @State private var referenceThumbnailURL: String?
    @State private var hasVideoReference = false

    // @ media library picker
    @State private var showMediaLibrary = false
    @State private var mediaLibraryItems: [ReferenceUploadItem] = []
    @State private var isLoadingLibrary = false

    // Paywall and submit state
    @State private var showPaywall = false
    @State private var isSubmitting = false

    // Card actions
    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var generationCost: Int {
        ratesManager.cost(
            model: selectedModel,
            durationSeconds: selectedDuration,
            resolution: selectedResolution,
            hasVideoReference: hasVideoReference
        )
    }

    // True when the user has a subscription but can't afford this generation.
    private var hasInsufficientCredits: Bool {
        creditManager.entitlementLevel != .none && creditManager.creditsBalance < generationCost
    }

    // Lights up the Options button when anything differs from defaults
    private var hasNonDefaultSettings: Bool {
        selectedMode != "AI Video" ||
        selectedModel != "bytedance/seedance-2.0-mini" ||
        selectedDuration != 6 ||
        selectedResolution != "720p" ||
        selectedAspectRatio != "9:16" ||
        !audioEnabled
    }

    private let suggestions: [(label: String, icon: String, prompt: String)] = [
        ("Anime girl",           "sparkles",           "Anime girl sitting in a sunlit cafe in the afternoon, soft golden light streaming through the window"),
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

                if generationManager.generations.isEmpty {
                    // Empty state — inspiration chips vertically centred
                    Spacer()
                    centerContent
                    Spacer()
                } else {
                    // Chat-style scroll: oldest at top, newest at bottom
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(generationManager.generations.reversed()) { item in
                                    GenerationCardView(
                                        item: item,
                                        onTapDetail: { selectedItem = item },
                                        onRemix: { handleRemix(item: item) },
                                        onRegenerate: { Task { await handleRegenerate(item: item) } },
                                        onDelete: { Task { await handleDelete(item: item) } }
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }
                        .onChange(of: generationManager.generations.first?.id) { _, _ in
                            scrollToNewest(proxy: proxy)
                        }
                        .onAppear { scrollToNewest(proxy: proxy) }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                // @ media library picker — slides in above the credit label when @ is typed
                if showMediaLibrary {
                    mediaLibraryPicker
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Cost floats outside the card, above the send arrow
                HStack {
                    Spacer()
                    creditCostLabel
                }
                .padding(.trailing, 38)
                promptBar
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMediaLibrary)
            // Lift the composer so its bottom clears the "+" diamond
            // (the tab bar reserves 74pt and the diamond is offset ~14pt above it).
            .padding(.bottom, 71)
        }
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
        // Auto-switch mode from prompt keywords
        .onChange(of: promptText) { _, text in
            let lower = text.lowercased()
            let imageWords = ["image", "photo", "picture", "illustration", "drawing", "painting", "poster", "portrait"]
            let videoWords = ["video", "animate", "animation", "motion", "clip", "movie", "reel"]
            if videoWords.contains(where: { lower.contains($0) }), selectedMode != "AI Video" {
                selectedMode = "AI Video"
                selectedModel = ModelCatalog.defaultModel(for: "AI Video")
            } else if imageWords.contains(where: { lower.contains($0) }), selectedMode != "AI Image" {
                selectedMode = "AI Image"
                selectedModel = ModelCatalog.defaultModel(for: "AI Image")
            }
        }
        // Polling — start/stop with this view's lifecycle
        .onAppear {
            generationManager.startPolling()
            if let remix = generationManager.pendingRemix {
                promptText = remix.prompt ?? ""
                selectedModel = remix.model
                selectedDuration = remix.params.duration ?? 6
                selectedResolution = remix.params.resolution ?? "720p"
                selectedAspectRatio = remix.params.aspectRatio ?? "9:16"
                audioEnabled = remix.params.audioEnabled ?? true
                generationManager.pendingRemix = nil
            }
        }
        .onDisappear { generationManager.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: .generationCompleted)) { _ in
            Task { await generationManager.refresh() }
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(isPresented: $showPaywall)
                .environment(creditManager)
        }
        .sheet(item: $selectedItem) { item in
            GenerationDetailSheet(
                item: item,
                isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } })
            )
            .environment(authManager)
        }
        .onChange(of: selectedPickerItem) { _, newItem in
            Task {
                guard let item = newItem else { clearReference(); return }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let contentTypes = item.supportedContentTypes
                let isVideo = contentTypes.contains(.movie) || contentTypes.contains(.mpeg4Movie)
                if isVideo {
                    let tmpInput = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(UUID().uuidString).tmp")
                    try? data.write(to: tmpInput)
                    let finalUrl = try? await transcodeToH264IfNeeded(url: tmpInput)
                    let finalData = (try? Data(contentsOf: finalUrl ?? tmpInput)) ?? data
                    referenceMediaData = finalData
                    referenceMimeType = "video/mp4"
                    hasVideoReference = true
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
        .onChange(of: promptText) { old, new in
            if new.hasSuffix("@") && !old.hasSuffix("@") {
                showMediaLibrary = true
                if !isLoadingLibrary {
                    Task { await loadMediaLibrary() }
                }
            } else if !new.hasSuffix("@") && showMediaLibrary {
                showMediaLibrary = false
            }
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(red: 0.13, green: 0.125, blue: 0.15)
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

    // MARK: - Top bar

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

            // Credit balance + ring — opens profile / credit sheet
            Button {
                showProfileSheet = true
            } label: {
                HStack(spacing: 12) {
                    Text("\(creditManager.creditsBalance)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                    CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 32)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Credits — tap to manage")
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    // MARK: - Center inspiration content

    private var centerContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("What will you create?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap an idea or describe your own")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            chipRow
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(suggestions, id: \.label) { item in
                    Button {
                        promptText = item.prompt
                        promptFocused = true
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(item.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
        }
        .mask(
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 48)
            }
        )
    }

    // MARK: - Credit cost (floats above the send arrow, outside the card)

    private var creditCostLabel: some View {
        Group {
            if hasInsufficientCredits {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("Insufficient credits")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Color.red)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                    Text("\(generationCost)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: generationCost)
                    Text("credits")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hasInsufficientCredits ? "Insufficient credits" : "Estimated cost \(generationCost) credits")
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        VStack(spacing: 4) {
            // Row 1: attach + prompt + send
            HStack(alignment: .center, spacing: 0) {
            // Left: attach button, thumbnail stacked below when present
            VStack(spacing: 6) {
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

                if referenceThumbnail != nil || referenceThumbnailURL != nil || (referenceURL != nil && hasVideoReference) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumb = referenceThumbnail {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                            } else if let urlStr = referenceThumbnailURL, let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.white.opacity(0.08)
                                    }
                                }
                            } else {
                                ZStack {
                                    Color.white.opacity(0.08)
                                    Image(systemName: "video.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
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
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            // Prompt text — full width, starts 1 line, expands downward as user types
            TextField("Describe a scene...", text: $promptText, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(.white)
                .tint(accent)
                .focused($promptFocused)
                .padding(.leading, 6)
                .padding(.top, 10)
                .padding(.bottom, 4)

            // Submit
            Button {
                promptFocused = false
                guard creditManager.entitlementLevel != .none else {
                    showPaywall = true
                    return
                }
                guard !hasInsufficientCredits else { return }
                Task { await dispatchGeneration() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                                     Color(red: 0.357, green: 0.561, blue: 0.851)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .opacity(isSubmitting || hasInsufficientCredits ? 0.5 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || hasInsufficientCredits)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
            }

            // Row 2: options toggle + collapsible panel
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) { showOptions.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                        ZStack {
                            Text("Options").opacity(0)
                            if showOptions {
                                Text("Hide").transition(.opacity)
                            } else {
                                Text("Options").transition(.opacity)
                            }
                        }
                        .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(hasNonDefaultSettings ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(hasNonDefaultSettings ? 0.12 : 0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(hasNonDefaultSettings ? 0.25 : 0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            if showOptions {
                GenerationOptionsPanel(
                    selectedMode: $selectedMode,
                    selectedModel: $selectedModel,
                    selectedDuration: $selectedDuration,
                    selectedResolution: $selectedResolution,
                    selectedAspectRatio: $selectedAspectRatio,
                    audioEnabled: $audioEnabled
                )
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    // MARK: - Media library picker

    // Stacked card pile: oldest behind-left, newest on top-right.
    // Up to 3 cards visible; each successive card offset +14pt right, 1pt down.
    private var mediaLibraryPicker: some View {
        HStack(spacing: 14) {
            // Card stack
            if isLoadingLibrary {
                // Skeleton placeholder stack
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 72, height: 72)
                            .offset(x: CGFloat(i) * 14, y: -CGFloat(i))
                            .zIndex(Double(i))
                    }
                }
                .frame(width: 72 + 2 * 14, height: 74)
            } else if mediaLibraryItems.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.2))
                    )
            } else {
                let visible = Array(mediaLibraryItems.prefix(3))
                // Reverse so oldest renders first (behind), newest last (on top)
                let ordered = Array(visible.reversed())
                ZStack(alignment: .bottomLeading) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, item in
                        Button {
                            Task { await selectLibraryItem(item) }
                        } label: {
                            libraryItemThumbnail(item)
                        }
                        .buttonStyle(.plain)
                        .offset(x: CGFloat(index) * 14, y: -CGFloat(index))
                        .zIndex(Double(index))
                    }
                }
                .frame(width: 72 + CGFloat(min(visible.count - 1, 2)) * 14, height: 74)
            }

            // Label + count
            VStack(alignment: .leading, spacing: 3) {
                Text("My Uploads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                if !mediaLibraryItems.isEmpty {
                    Text("\(mediaLibraryItems.count) file\(mediaLibraryItems.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                } else if !isLoadingLibrary {
                    Text("No uploads yet")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }

            Spacer()

            Button { showMediaLibrary = false } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 22)
    }

    @ViewBuilder
    private func libraryItemThumbnail(_ item: ReferenceUploadItem) -> some View {
        ZStack {
            if item.isVideo {
                LinearGradient(
                    colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                             Color(red: 0.416, green: 0.561, blue: 0.878)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "video.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                AsyncImage(url: URL(string: item.url)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Color.white.opacity(0.07)
                    }
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private func loadMediaLibrary() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        do {
            mediaLibraryItems = try await APIClient.shared.fetchMyUploads()
        } catch {
            print("[GenerateView] fetchMyUploads failed: \(error)")
            mediaLibraryItems = []
        }
    }

    private func selectLibraryItem(_ item: ReferenceUploadItem) async {
        referenceURL = item.url
        referenceUploadId = item.id
        referenceMimeType = item.mimeType
        hasVideoReference = item.isVideo
        referenceMediaData = nil
        selectedPickerItem = nil
        referenceThumbnail = nil
        referenceThumbnailURL = item.isVideo ? nil : item.url

        // Remove the @ trigger from prompt text
        if promptText.hasSuffix("@") {
            promptText = String(promptText.dropLast())
        }
        showMediaLibrary = false
    }

    // MARK: - Submit dispatch

    private func dispatchGeneration() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            var refImages: [String]? = nil
            var refVideos: [String]? = nil
            var refUploadId: String? = referenceUploadId  // may already be set from library pick

            if let libraryURL = referenceURL, let mime = referenceMimeType {
                if mime.contains("video") { refVideos = [libraryURL] }
                else { refImages = [libraryURL] }
            } else if let data = referenceMediaData, let mime = referenceMimeType {
                let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
                let fileName = mime.contains("video") ? "reference.mp4" : "reference.\(ext)"
                let uploadResponse = try await APIClient.shared.uploadReferenceMedia(
                    data: data, mimeType: mime, fileName: fileName
                )
                if mime.contains("video") { refVideos = [uploadResponse.url] }
                else { refImages = [uploadResponse.url] }
                refUploadId = uploadResponse.id  // capture for remix/regen
            }

            let body = GenerationRequestBody(
                prompt: promptText,
                model: selectedModel,
                mediaType: "video",
                duration: selectedDuration,
                resolution: selectedResolution,
                aspectRatio: selectedAspectRatio,
                audioEnabled: audioEnabled,
                width: nil,
                height: nil,
                referenceImages: refImages,
                referenceVideos: refVideos,
                referenceUploadIds: refUploadId.map { [$0] }
            )
            _ = try await APIClient.shared.submitGeneration(body: body)

            promptText = ""
            clearReference()
            await generationManager.refresh()
            generationManager.startPolling()
            // Auto-scroll to newest handled by onChange(of: generations.first?.id)

        } catch {
            print("[GenerateView] dispatch error: \(error)")
            await generationManager.refresh()
        }
    }

    // MARK: - Card action handlers

    private func handleRemix(item: GenerationItem) {
        promptText = item.prompt ?? ""
        selectedModel = item.model
        selectedDuration = item.params.duration ?? 6
        selectedResolution = item.params.resolution ?? "720p"
        selectedAspectRatio = item.params.aspectRatio ?? "9:16"
        audioEnabled = item.params.audioEnabled ?? true
        // Pre-fill reference if the original generation had one
        if let ref = item.referenceUrls?.first {
            referenceURL = ref.url
            referenceMimeType = ref.isVideo ? "video/mp4" : "image/jpeg"
            hasVideoReference = ref.isVideo
            referenceThumbnail = nil
            referenceThumbnailURL = ref.isVideo ? nil : ref.url
            referenceMediaData = nil
            selectedPickerItem = nil
            // referenceUploadId: unknown at this point — will be set when user re-submits
            // The server will receive reference_images/videos from the presigned URL
            referenceUploadId = nil
        } else {
            clearReference()
        }
        promptFocused = true
    }

    private func handleRegenerate(item: GenerationItem) async {
        let hasVideoRef = item.referenceUrls?.contains(where: { $0.isVideo }) ?? false
        let cost = ratesManager.cost(
            model: item.model,
            durationSeconds: item.params.duration ?? 0,
            resolution: item.params.resolution ?? "720p",
            hasVideoReference: hasVideoRef
        )
        guard creditManager.creditsBalance >= cost else { return }
        await dispatchRegenerate(item: item)
    }

    private func dispatchRegenerate(item: GenerationItem) async {
        guard let prompt = item.prompt else { return }
        // Re-use the reference from the original generation if available
        let ref = item.referenceUrls?.first
        let refImages: [String]? = ref.flatMap { $0.isVideo ? nil : [$0.url] }
        let refVideos: [String]? = ref.flatMap { $0.isVideo ? [$0.url] : nil }
        let body = GenerationRequestBody(
            prompt: prompt,
            model: item.model,
            mediaType: item.isImage ? "image" : "video",
            duration: item.params.duration,
            resolution: item.params.resolution,
            aspectRatio: item.params.aspectRatio,
            audioEnabled: item.params.audioEnabled,
            width: item.params.width,
            height: item.params.height,
            referenceImages: refImages,
            referenceVideos: refVideos,
            referenceUploadIds: nil  // presigned URL will be used directly; no upload ID needed
        )
        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            await generationManager.refresh()
            generationManager.startPolling()
        } catch {
            print("[GenerateView] regenerate error: \(error)")
        }
    }

    private func handleDelete(item: GenerationItem) async {
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
        } catch {
            print("[GenerateView] delete error: \(error)")
        }
    }

    private func scrollToNewest(proxy: ScrollViewProxy) {
        guard let id = generationManager.generations.first?.id else { return }
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    private func clearReference() {
        selectedPickerItem = nil
        referenceMediaData = nil
        referenceURL = nil
        referenceUploadId = nil
        referenceMimeType = nil
        referenceThumbnail = nil
        referenceThumbnailURL = nil
        hasVideoReference = false
    }
}

// MARK: - HEVC transcoding helper

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
    NavigationStack { GenerateView() }
        .environment(CreditManager())
        .environment(AuthManager())
        .environment(GenerationManager())
        .preferredColorScheme(.dark)
}
