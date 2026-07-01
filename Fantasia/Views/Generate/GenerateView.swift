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
    @State private var selectedImageResolution: ImageResolution = .square
    @State private var showOptions = false

    // Multi-reference attachment state
    @State private var selectedPickerItem: PhotosPickerItem?
    @State private var attachedReferences: [AttachedReference] = []

    // Rename sheet
    @State private var renamingItem: ReferenceUploadItem? = nil
    @State private var renameText = ""

    // @ media library picker
    @State private var showMediaLibrary = false
    @State private var mediaLibraryItems: [ReferenceUploadItem] = []
    @State private var isLoadingLibrary = false
    @State private var libraryLoadFailed = false

    // Paywall and submit state
    @State private var showPaywall = false
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    // Card actions
    @State private var selectedItem: GenerationItem? = nil

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var hasVideoReference: Bool {
        attachedReferences.contains { $0.isVideo }
    }

    private var isAnyUploading: Bool {
        attachedReferences.contains { $0.isUploading }
    }

    private var isSubmitDisabled: Bool {
        isSubmitting || hasInsufficientCredits || isAnyUploading
    }

    private var generationCost: Int {
        if selectedMode == "AI Image" {
            return ratesManager.imageCost(for: selectedModel)
        }
        return ratesManager.cost(
            model: selectedModel,
            durationSeconds: selectedDuration,
            resolution: selectedResolution,
            hasVideoReference: hasVideoReference
        )
    }

    private var hasInsufficientCredits: Bool {
        creditManager.entitlementLevel != .none && creditManager.creditsBalance < generationCost
    }

    private var hasNonDefaultSettings: Bool {
        if selectedMode == "AI Image" {
            return selectedImageResolution != .square ||
                selectedModel != ModelCatalog.image[0].id
        }
        return selectedMode != "AI Video" ||
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
                    Spacer()
                    centerContent
                    Spacer()
                } else {
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
                if showMediaLibrary {
                    mediaLibraryPicker
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack {
                    Spacer()
                    creditCostLabel
                }
                .padding(.trailing, 38)
                promptBar
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMediaLibrary)
            .padding(.bottom, 71)
        }
        .contentShape(Rectangle())
        .onTapGesture { promptFocused = false }
        .onChange(of: promptText) { old, new in
            // Auto-switch mode based on keywords
            let lower = new.lowercased()
            let imageWords = ["image", "photo", "picture", "illustration", "drawing", "painting", "poster", "portrait"]
            let videoWords = ["video", "animate", "animation", "motion", "clip", "movie", "reel"]
            if videoWords.contains(where: { lower.contains($0) }), selectedMode != "AI Video" {
                selectedMode = "AI Video"
                selectedModel = ModelCatalog.defaultModel(for: "AI Video")
            } else if imageWords.contains(where: { lower.contains($0) }), selectedMode != "AI Image" {
                selectedMode = "AI Image"
                selectedModel = ModelCatalog.defaultModel(for: "AI Image")
            }

            // @ trigger for media library
            if new.hasSuffix("@") && !old.hasSuffix("@") {
                showMediaLibrary = true
                Task { await loadMediaLibrary() }
            } else if !new.hasSuffix("@") && showMediaLibrary {
                showMediaLibrary = false
            }
        }
        .onChange(of: selectedPickerItem) { _, newItem in
            Task { await handlePickerSelection(newItem) }
        }
        .onAppear {
            generationManager.startPolling()
            if let remix = generationManager.pendingRemix {
                promptText = remix.prompt ?? ""
                selectedModel = remix.model
                selectedMode = remix.isImage ? "AI Image" : "AI Video"
                if remix.isImage {
                    selectedImageResolution = ImageResolution.allCases.first {
                        $0.rawValue == remix.params.aspectRatio
                    } ?? .square
                } else {
                    selectedDuration = remix.params.duration ?? 6
                    selectedResolution = remix.params.resolution ?? "720p"
                    selectedAspectRatio = remix.params.aspectRatio ?? "9:16"
                    audioEnabled = remix.params.audioEnabled ?? true
                }
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
        .alert("Name this reference", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("e.g. sarah", text: $renameText)
                .autocorrectionDisabled()
            Button("Save") {
                guard let item = renamingItem else { return }
                let name = String(renameText.trimmingCharacters(in: .whitespaces).prefix(40))
                Task { await applyRename(to: item, name: name) }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) { renamingItem = nil }
        }
        .alert("Generation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $selectedItem) { item in
            GenerationDetailSheet(
                item: item,
                isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } })
            )
            .environment(authManager)
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

    // MARK: - Credit cost

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
            } else if isAnyUploading {
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accent))
                        .scaleEffect(0.6)
                    Text("Uploading…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
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
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Left column: paperclip + card stack
                VStack(alignment: .leading, spacing: 6) {
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

                    if !attachedReferences.isEmpty {
                        referenceCardStack
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 10)
                .padding(.bottom, 2)

                // Prompt text
                TextField("Describe a scene...", text: $promptText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(.white)
                    .tint(accent)
                    .focused($promptFocused)
                    .padding(.leading, 6)
                    .padding(.top, 14)
                    .padding(.bottom, 2)

                // Submit
                Button {
                    promptFocused = false
                    guard creditManager.entitlementLevel != .none else {
                        showPaywall = true
                        return
                    }
                    guard !isSubmitDisabled else { return }
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
                        .opacity(isSubmitDisabled ? 0.5 : 1.0)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitDisabled)
                .padding(.trailing, 10)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }

            // Options row
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
                    audioEnabled: $audioEnabled,
                    selectedImageResolution: $selectedImageResolution
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

    // MARK: - Reference card stack (below paperclip)
    // Cards fan to the right: index 0 = leftmost/oldest, last = rightmost/newest (top).
    // X button only on top card; tapping it pops the card and removes its prompt token.

    private var referenceCardStack: some View {
        let visible = Array(attachedReferences.suffix(3))
        let totalWidth = 32 + CGFloat(max(0, visible.count - 1)) * 3
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, ref in
                referenceCard(ref, isTop: index == visible.count - 1)
                    .offset(x: CGFloat(index) * 3, y: 0)
                    .zIndex(Double(index))
            }
        }
        .frame(width: totalWidth, height: 36)
    }

    @ViewBuilder
    private func referenceCard(_ ref: AttachedReference, isTop: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if ref.isUploading {
                    ZStack {
                        Color.white.opacity(0.08)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                            .scaleEffect(0.55)
                    }
                } else if let thumb = ref.thumbnail {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else if let urlStr = ref.thumbnailURL ?? (ref.isVideo ? nil : ref.url),
                          let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
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
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.2), lineWidth: 0.5))

            if isTop {
                Button { removeTopReference() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .offset(x: 4, y: -4)
            }
        }
    }

    // MARK: - Media library picker (horizontal scroll, per-item delete)

    private var mediaLibraryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("My Uploads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
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
            .padding(.top, 14)

            if isLoadingLibrary {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.07))
                                .frame(width: 64, height: 64)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else if mediaLibraryItems.isEmpty {
                Button {
                    Task { await loadMediaLibrary() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: libraryLoadFailed ? "arrow.clockwise" : "photo.on.rectangle")
                            .font(.system(size: 18))
                            .foregroundStyle(.white.opacity(libraryLoadFailed ? 0.5 : 0.2))
                        Text(libraryLoadFailed ? "Tap to retry" : "No uploads yet")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(mediaLibraryItems) { item in
                            ZStack(alignment: .topTrailing) {
                                Button {
                                    Task { await selectLibraryItem(item) }
                                } label: {
                                    libraryItemThumbnail(item)
                                        .overlay(alignment: .bottom) {
                                            if let name = item.displayName {
                                                Text(name)
                                                    .font(.system(size: 8, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                    .padding(.horizontal, 3)
                                                    .padding(.vertical, 2)
                                                    .background(.black.opacity(0.6))
                                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                                    .padding(.bottom, 3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Rename") {
                                        renamingItem = item
                                        renameText = item.displayName ?? ""
                                    }
                                    Button("Delete", role: .destructive) {
                                        Task { await deleteLibraryItem(item) }
                                    }
                                }

                                Button {
                                    Task { await deleteLibraryItem(item) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .background(Color.black.opacity(0.55), in: Circle())
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }

            Spacer().frame(height: 8)
        }
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
                    .font(.system(size: 20, weight: .medium))
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
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: - Library actions

    private func loadMediaLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryLoadFailed = false
        defer { isLoadingLibrary = false }
        do {
            mediaLibraryItems = try await APIClient.shared.fetchMyUploads()
        } catch {
            print("[GenerateView] fetchMyUploads failed: \(error)")
            libraryLoadFailed = true
        }
    }

    private func selectLibraryItem(_ item: ReferenceUploadItem) async {
        showMediaLibrary = false

        let imageSlot = attachedReferences.filter { !$0.isVideo }.count + 1
        let videoSlot = attachedReferences.filter { $0.isVideo }.count + 1
        let token: String
        if let name = item.displayName, !name.isEmpty {
            token = "[\(name)]"
        } else {
            token = item.isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
        }

        if promptText.hasSuffix("@") {
            promptText = String(promptText.dropLast()) + token
        } else {
            insertToken(token)
        }

        let ref = AttachedReference(
            mimeType: item.mimeType,
            thumbnailURL: item.isVideo ? nil : item.url,
            fromLibrary: true,
            isUploading: false,
            uploadId: item.id,
            url: item.url,
            displayName: item.displayName
        )
        attachedReferences.append(ref)
    }

    private func applyRename(to item: ReferenceUploadItem, name: String) async {
        try? await APIClient.shared.renameUpload(id: item.id, displayName: name)
        let resolved = name.isEmpty ? nil : name
        if let idx = mediaLibraryItems.firstIndex(where: { $0.id == item.id }) {
            mediaLibraryItems[idx].displayName = resolved
        }
        if let idx = attachedReferences.firstIndex(where: { $0.uploadId == item.id }) {
            attachedReferences[idx].displayName = resolved
            rebuildPromptTokens()
        }
    }

    private func deleteLibraryItem(_ item: ReferenceUploadItem) async {
        try? await APIClient.shared.deleteUpload(id: item.id)
        withAnimation(.spring(response: 0.3)) {
            mediaLibraryItems.removeAll { $0.id == item.id }
            attachedReferences.removeAll { $0.uploadId == item.id }
            rebuildPromptTokens()
        }
    }

    // MARK: - Photo picker handler

    private func handlePickerSelection(_ pickerItem: PhotosPickerItem?) async {
        guard let item = pickerItem else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let contentTypes = item.supportedContentTypes
        let isVideo = contentTypes.contains(.movie) || contentTypes.contains(.mpeg4Movie)

        // Compute slot before appending
        let imageSlot = attachedReferences.filter { !$0.isVideo }.count + 1
        let videoSlot = attachedReferences.filter { $0.isVideo }.count + 1

        if isVideo {
            let tmpInput = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).tmp")
            try? data.write(to: tmpInput)
            let finalUrl = try? await transcodeToH264IfNeeded(url: tmpInput)
            let finalData = (try? Data(contentsOf: finalUrl ?? tmpInput)) ?? data
            let thumbUrl = finalUrl ?? tmpInput
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: thumbUrl))
            generator.appliesPreferredTrackTransform = true
            let thumbnail = (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init)

            // Add card in uploading state
            let token = "[Video\(videoSlot)]"
            let ref = AttachedReference(mimeType: "video/mp4", thumbnail: thumbnail, isUploading: true)
            let tempId = ref.id
            attachedReferences.append(ref)
            insertToken(token)

            // Upload
            if let response = try? await APIClient.shared.uploadReferenceMedia(
                data: finalData, mimeType: "video/mp4", fileName: "reference.mp4"
            ) {
                if let idx = attachedReferences.firstIndex(where: { $0.id == tempId }) {
                    attachedReferences[idx].uploadId = response.id
                    attachedReferences[idx].url = response.url
                    attachedReferences[idx].isUploading = false
                    // Add to library picker list
                    if let id = response.id {
                        mediaLibraryItems.insert(
                            ReferenceUploadItem(id: id, url: response.url, mimeType: "video/mp4"),
                            at: 0
                        )
                    }
                }
            } else {
                // Upload failed — remove card and token
                attachedReferences.removeAll { $0.id == tempId }
                rebuildPromptTokens()
            }
        } else {
            let thumbnail = UIImage(data: data)
            let token = "[Image\(imageSlot)]"
            let ref = AttachedReference(mimeType: "image/jpeg", thumbnail: thumbnail, isUploading: true)
            let tempId = ref.id
            attachedReferences.append(ref)
            insertToken(token)

            if let response = try? await APIClient.shared.uploadReferenceMedia(
                data: data, mimeType: "image/jpeg", fileName: "reference.jpg"
            ) {
                if let idx = attachedReferences.firstIndex(where: { $0.id == tempId }) {
                    attachedReferences[idx].uploadId = response.id
                    attachedReferences[idx].url = response.url
                    attachedReferences[idx].isUploading = false
                    if let id = response.id {
                        mediaLibraryItems.insert(
                            ReferenceUploadItem(id: id, url: response.url, mimeType: "image/jpeg"),
                            at: 0
                        )
                    }
                }
            } else {
                attachedReferences.removeAll { $0.id == tempId }
                rebuildPromptTokens()
            }
        }

        // Reset picker so it can fire again for the next image
        selectedPickerItem = nil
    }

    // MARK: - Reference management

    private func removeTopReference() {
        guard let ref = attachedReferences.last else { return }

        // Delete fresh uploads from server (library items stay in library)
        if let uploadId = ref.uploadId, !ref.fromLibrary {
            Task { try? await APIClient.shared.deleteUpload(id: uploadId) }
        }

        attachedReferences.removeLast()
        rebuildPromptTokens()
    }

    /// Rebuilds [ImageN]/[VideoN] tokens in the prompt to match current attachedReferences.
    /// Strips all existing tokens then re-appends based on current array order.
    private func rebuildPromptTokens() {
        var text = promptText
        // Strip ALL [anything] tokens — covers named ([sarah]) and positional ([Image1])
        if let re = try? NSRegularExpression(pattern: "\\s*\\[[^\\]]+\\]") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)

        var imageCount = 0
        var videoCount = 0
        for ref in attachedReferences {
            if ref.isVideo { videoCount += 1 } else { imageCount += 1 }
            text += " \(ref.compositionToken(imageSlot: imageCount, videoSlot: videoCount))"
        }
        promptText = text.trimmingCharacters(in: .whitespaces)
    }

    /// Returns the prompt with any custom-name tokens swapped to positional [ImageN]/[VideoN]
    /// so Replicate always receives the format it expects.
    private func resolvedPromptForSubmit() -> String {
        var text = promptText
        var imageCount = 0
        var videoCount = 0
        for ref in attachedReferences where ref.isReady {
            if ref.isVideo { videoCount += 1 } else { imageCount += 1 }
            if let name = ref.displayName, !name.isEmpty {
                let positional = ref.isVideo ? "[Video\(videoCount)]" : "[Image\(imageCount)]"
                text = text.replacingOccurrences(of: "[\(name)]", with: positional)
            }
        }
        return text
    }

    private func insertToken(_ token: String) {
        if promptText.isEmpty {
            promptText = token
        } else if promptText.hasSuffix(" ") {
            promptText += token
        } else {
            promptText += " \(token)"
        }
    }

    // MARK: - Submit dispatch

    private func dispatchGeneration() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let readyRefs = attachedReferences.filter { $0.isReady }
            let refImages = readyRefs.filter { !$0.isVideo }.map { $0.url }
            let refVideos = readyRefs.filter { $0.isVideo }.map { $0.url }
            let refUploadIds = readyRefs.compactMap { $0.uploadId }

            let submitPrompt = resolvedPromptForSubmit()
            let body: GenerationRequestBody
            if selectedMode == "AI Image" {
                body = GenerationRequestBody(
                    prompt: submitPrompt,
                    model: selectedModel,
                    mediaType: "image",
                    duration: nil,
                    resolution: nil,
                    aspectRatio: nil,
                    audioEnabled: nil,
                    imageAspectRatio: selectedImageResolution.rawValue,
                    referenceImages: refImages.isEmpty ? nil : refImages,
                    referenceVideos: refVideos.isEmpty ? nil : refVideos,
                    referenceUploadIds: refUploadIds.isEmpty ? nil : refUploadIds
                )
            } else {
                body = GenerationRequestBody(
                    prompt: submitPrompt,
                    model: selectedModel,
                    mediaType: "video",
                    duration: selectedDuration,
                    resolution: selectedResolution,
                    aspectRatio: selectedAspectRatio,
                    audioEnabled: audioEnabled,
                    width: nil,
                    height: nil,
                    referenceImages: refImages.isEmpty ? nil : refImages,
                    referenceVideos: refVideos.isEmpty ? nil : refVideos,
                    referenceUploadIds: refUploadIds.isEmpty ? nil : refUploadIds
                )
            }
            _ = try await APIClient.shared.submitGeneration(body: body)

            promptText = ""
            attachedReferences = []
            await generationManager.refresh()
            generationManager.startPolling()

        } catch let apiError as APIError {
            if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                errorMessage = "Prompt may not adhere to our community guidelines. Please try again."
            } else {
                errorMessage = "An error has occurred. Please try again."
            }
            await generationManager.refresh()
        } catch {
            print("[GenerateView] dispatch error: \(error)")
            errorMessage = "An error has occurred. Please try again."
            await generationManager.refresh()
        }
    }

    // MARK: - Card action handlers

    private func handleRemix(item: GenerationItem) {
        promptText = item.prompt ?? ""
        selectedModel = item.model
        selectedMode = item.isImage ? "AI Image" : "AI Video"
        if item.isImage {
            selectedImageResolution = ImageResolution.allCases.first {
                $0.rawValue == item.params.aspectRatio
            } ?? .square
        } else {
            selectedDuration = item.params.duration ?? 6
            selectedResolution = item.params.resolution ?? "720p"
            selectedAspectRatio = item.params.aspectRatio ?? "9:16"
            audioEnabled = item.params.audioEnabled ?? true
        }

        // Pre-fill references from original generation (treat as library items — no server delete on X)
        attachedReferences = []
        if let refs = item.referenceUrls {
            for ref in refs {
                let attached = AttachedReference(
                    mimeType: ref.isVideo ? "video/mp4" : "image/jpeg",
                    thumbnailURL: ref.isVideo ? nil : ref.url,
                    fromLibrary: true,
                    isUploading: false,
                    uploadId: nil,
                    url: ref.url
                )
                attachedReferences.append(attached)
            }
            // Prompt already contains tokens from the original generation
        }
        generationManager.pendingRemix = nil
        promptFocused = true
    }

    private func handleRegenerate(item: GenerationItem) async {
        let cost: Int
        if item.isImage {
            cost = ratesManager.imageCost(for: item.model)
        } else {
            let hasVideoRef = item.referenceUrls?.contains(where: { $0.isVideo }) ?? false
            cost = ratesManager.cost(
                model: item.model,
                durationSeconds: item.params.duration ?? 0,
                resolution: item.params.resolution ?? "720p",
                hasVideoReference: hasVideoRef
            )
        }
        guard creditManager.creditsBalance >= cost else { return }
        await dispatchRegenerate(item: item)
    }

    private func dispatchRegenerate(item: GenerationItem) async {
        guard let prompt = item.prompt else { return }
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
            referenceUploadIds: nil
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
}

// MARK: - AttachedReference

private struct AttachedReference: Identifiable {
    var id: String
    var uploadId: String?
    var url: String
    var mimeType: String
    var thumbnail: UIImage?
    var thumbnailURL: String?
    var fromLibrary: Bool
    var isUploading: Bool
    var displayName: String?   // nil = positional token; set = "[name]" shown in prompt

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isReady: Bool { !isUploading && !url.isEmpty }

    func compositionToken(imageSlot: Int, videoSlot: Int) -> String {
        if let name = displayName, !name.isEmpty { return "[\(name)]" }
        return isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
    }

    init(mimeType: String, thumbnail: UIImage? = nil, thumbnailURL: String? = nil,
         fromLibrary: Bool = false, isUploading: Bool = false,
         uploadId: String? = nil, url: String = "", displayName: String? = nil) {
        self.id = UUID().uuidString
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.thumbnailURL = thumbnailURL
        self.fromLibrary = fromLibrary
        self.isUploading = isUploading
        self.uploadId = uploadId
        self.url = url
        self.displayName = displayName
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
