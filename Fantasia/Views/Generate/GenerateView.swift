// GenerateView.swift
// Fantasia
// Chat-style generation hub: prompt bar pinned at bottom, generations scroll upward above it.
// Empty state shows inspiration chips. No separate Feed tab — everything lives here.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct GenerateView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(RatesManager.self) private var ratesManager
    @Environment(DrawerManager.self) private var drawer
    @Environment(ThemeManager.self) private var theme
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    // Perf: these were previously compiled fresh inside highlightedPrompt (recomputed on every
    // body render, i.e. every keystroke), atomicTokenDeletion, and rebuildPromptTokens. Hoisted
    // to compile-once static constants — same patterns, no behavior change.
    private static let bracketTokenRegex = try? NSRegularExpression(pattern: #"\[[^\]]+\]"#)
    private static let bracketTokenWithLeadingSpaceRegex = try? NSRegularExpression(pattern: "\\s*\\[[^\\]]+\\]")
    private static let mentionTriggerRegex = try? NSRegularExpression(pattern: #"@(\w*)$"#)

    @State private var promptText = ""
    // Cursor/selection in the prompt field — the @-mention trigger needs to know where the
    // caret actually is, since editing text earlier in the prompt leaves the caret short of
    // promptText's end (e.g. after a previously inserted [Image1] token).
    @State private var promptTextRange: NSRange?
    @State private var promptTextHeight: CGFloat = 22
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
    @State private var showPhotosPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false

    // Rename sheet
    @State private var renamingItem: ReferenceUploadItem? = nil
    @State private var renameText = ""

    // "Name as reference" — promotes a past generation's output into the permanent
    // reference library (distinct from renamingItem, which renames an existing upload)
    @State private var namingReferenceFromGeneration: GenerationItem? = nil
    @State private var newReferenceName = ""

    // Media library + @-mention state
    @State private var mentionQuery: String? = nil
    @State private var showMentionSuggestions = false

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

    private var mentionSuggestions: [MentionCandidate] {
        guard let q = mentionQuery, !q.isEmpty else { return defaultMentionSuggestions }
        // When filtering, unnamed uploads are hidden (nothing to match against); the synthetic
        // "latest generation" entry has no name either, so it only ever appears in the
        // unfiltered (just-typed-@) list below.
        return mediaLibrary.items
            .filter { ($0.displayName ?? "").localizedCaseInsensitiveContains(q) }
            .map { .upload($0) }
    }

    /// Suggestions shown right after typing "@", before any filter text — in priority order:
    /// (1) the most recent upload overall, (2) the most recent *image* upload if different from
    /// #1, (3) the latest completed generation, then (4) everything else. mediaLibraryItems is
    /// already newest-first (server returns desc(created_at); new uploads are inserted at index 0),
    /// so "most recent" is just .first.
    private var defaultMentionSuggestions: [MentionCandidate] {
        var result: [MentionCandidate] = []
        var usedUploadIds = Set<String>()

        if let mostRecent = mediaLibrary.items.first {
            result.append(.upload(mostRecent))
            usedUploadIds.insert(mostRecent.id)
        }
        if let mostRecentImage = mediaLibrary.items.first(where: { !$0.isVideo }),
           !usedUploadIds.contains(mostRecentImage.id) {
            result.append(.upload(mostRecentImage))
            usedUploadIds.insert(mostRecentImage.id)
        }
        if let latestGeneration = generationManager.generations.first(where: {
            $0.status == .completed && !($0.completedMediaUrl ?? "").isEmpty
        }) {
            result.append(.generation(latestGeneration))
        }
        for item in mediaLibrary.items where !usedUploadIds.contains(item.id) {
            result.append(.upload(item))
        }
        return result
    }

    private var isAnyUploading: Bool {
        attachedReferences.contains { $0.isUploading }
    }

    private var selectedModelRequiresImage: Bool {
        (ModelCatalog.video + ModelCatalog.image)
            .first(where: { $0.id == selectedModel })?.requiresImage ?? false
    }

    private var missingRequiredImage: Bool {
        guard selectedModelRequiresImage else { return false }
        return !attachedReferences.contains { !$0.isVideo }
    }

    private var isSubmitDisabled: Bool {
        isSubmitting || hasInsufficientCredits || isAnyUploading || missingRequiredImage
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
            // Tap-to-dismiss lives on the background layer alone (not a screen-wide gesture)
            // so it only fires when a tap lands on genuinely empty space — SwiftUI hit-tests
            // top-down, so buttons, the history list, and the prompt bar all still consume
            // their own taps first. A screen-wide simultaneousGesture here previously covered
            // the prompt bar too, which both dismissed the keyboard on every line-to-line tap
            // in a multiline prompt AND fought with the paperclip/options/remove-reference
            // buttons for the touch.
            background
                .onTapGesture { promptFocused = false }

            VStack(spacing: 0) {
                topBar

                if generationManager.generations.isEmpty && !generationManager.hasLoadedOnce {
                    // Initial history fetch still in flight — show a spinner instead of the
                    // "What will you create?" empty state, which was misleadingly flashing
                    // for returning users while their (non-empty) history was still loading.
                    Spacer()
                    ProgressView()
                        .tint(.white.opacity(0.6))
                    Spacer()
                } else if generationManager.generations.isEmpty {
                    Spacer()
                    centerContent
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Plain VStack (not Lazy): this list is a single bounded page of
                            // history, not an infinite feed. Eagerly measuring every card is
                            // what makes defaultScrollAnchor(.bottom) below land on the exact
                            // bottom — LazyVStack doesn't size off-screen variable-height rows
                            // ahead of time, so the anchor's initial offset came out wrong.
                            VStack(spacing: 12) {
                                ForEach(generationManager.generations.reversed()) { item in
                                    GenerationCardView(
                                        item: item,
                                        onTapDetail: { selectedItem = item },
                                        onRemix: { handleRemix(item: item) },
                                        onRegenerate: { Task { await handleRegenerate(item: item) } },
                                        onReference: { handleReference(item: item) },
                                        onNameAsReference: { handleNameAsReference(item: item) },
                                        onDelete: { Task { await handleDelete(item: item) } }
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }
                        .defaultScrollAnchor(.bottom)
                        .onChange(of: generationManager.generations.first?.id) { _, _ in
                            scrollToNewest(proxy: proxy)
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    promptFocused = false
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if showMentionSuggestions && !mentionSuggestions.isEmpty {
                    // Opacity-only removal (not .move(edge: .bottom)) — the slide used to carry
                    // this ~220pt panel down over the Options/Hide button while fading out,
                    // swallowing taps on it mid-animation. allowsHitTesting keeps the outgoing
                    // view from intercepting taps at all during its transition.
                    mentionSuggestionList
                        .allowsHitTesting(showMentionSuggestions)
                        .transition(.opacity)
                }
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
                promptBar
            }
            .frame(maxWidth: .infinity)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showMentionSuggestions)
            .padding(.bottom, promptFocused ? 2 : 65)
            .background(
                VStack(spacing: 0) {
                    Color.clear.frame(height: 40)
                    theme.elevatedBackground
                }
                .ignoresSafeArea(edges: .bottom)
            )
        }
        .onChange(of: promptText) { old, new in
            // Atomic token deletion: if user deleted one char inside [token], remove whole token
            if let (snapped, removedInner) = atomicTokenDeletion(old: old, new: new) {
                promptText = snapped
                if let inner = removedInner { dereferenceToken(inner) }
                return
            }

            // @-mention trigger: detect @word immediately before the caret, not just at the
            // very end of the string — otherwise editing text earlier in the prompt (before a
            // previously inserted [Image1]-style token) leaves the caret short of promptText's
            // end, and the old end-anchored check would silently never match again.
            // NSRegularExpression anchors "$" to the end of the search range by default (not
            // the whole string), so bounding the range at the caret makes "@(\w*)$" match
            // "@word" immediately before the caret rather than only at promptText's true end.
            let caretEnd = promptCursorIndex(in: new) ?? new.endIndex
            let searchRange = NSRange(new.startIndex..<caretEnd, in: new)
            if let match = Self.mentionTriggerRegex?.firstMatch(in: new, range: searchRange),
               let r = Range(match.range, in: new) {
                let q = String(new[r].dropFirst())
                mentionQuery = q
                if !showMentionSuggestions {
                    showMentionSuggestions = true
                    Task { await mediaLibrary.load() }
                }
            } else {
                mentionQuery = nil
                showMentionSuggestions = false
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
            if let refItem = generationManager.pendingReference {
                attachReference(from: refItem)
                generationManager.pendingReference = nil
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
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker(
                allowsVideo: !selectedModelRequiresImage,
                onCapture: { data, isVideo in
                    showCameraPicker = false
                    Task { await handleAttachedData(data, isVideo: isVideo) }
                },
                onCancel: { showCameraPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: selectedModelRequiresImage ? [.image] : [.image, .movie]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await handleImportedFile(url) }
        }
        .sheet(isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            NameReferenceSheet(
                placeholder: renamingItem.map { defaultSlotPlaceholder(for: $0) } ?? "",
                text: $renameText,
                onSave: { name in
                    guard let item = renamingItem else { return }
                    let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
                    Task { await applyRename(to: item, name: trimmed) }
                    renamingItem = nil
                },
                onCancel: { renamingItem = nil }
            )
            .presentationDetents([.height(230)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: Binding(
            get: { namingReferenceFromGeneration != nil },
            set: { if !$0 { namingReferenceFromGeneration = nil } }
        )) {
            NameReferenceSheet(
                placeholder: namingReferenceFromGeneration.map { $0.isImage ? "Image" : "Video" } ?? "",
                text: $newReferenceName,
                onSave: { name in
                    guard let item = namingReferenceFromGeneration else { return }
                    let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
                    Task { await saveGenerationAsReference(item: item, name: trimmed) }
                    namingReferenceFromGeneration = nil
                },
                onCancel: { namingReferenceFromGeneration = nil }
            )
            .presentationDetents([.height(230)])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $selectedItem) { item in
            GenerationDetailPagerView(
                items: generationManager.generations,
                currentId: item.id,
                isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } })
            )
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            theme.elevatedBackground
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
            Button { drawer.open() } label: {
                VStack(spacing: 5) {
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                    Rectangle().frame(width: 22, height: 2)
                }
                .foregroundStyle(theme.textPrimary)
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
                    .foregroundStyle(theme.textPrimary)
                    .kerning(-0.16)
            }

            Spacer()

            Button {
                showProfileSheet = true
            } label: {
                HStack(spacing: 12) {
                    Text("\(creditManager.creditsBalance)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
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
        .background(theme.elevatedBackground.ignoresSafeArea(edges: .top))
    }

    // MARK: - Center inspiration content

    private var centerContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("What will you create?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("Tap an idea or describe your own")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
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
                                .foregroundStyle(theme.textSecondary)
                            Text(item.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(theme.textPrimary.opacity(0.92))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(theme.surfaceBorder, lineWidth: 1))
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
            } else if missingRequiredImage {
                HStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("Attach an image to use this model")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(theme.textSecondary)
            } else if isAnyUploading {
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accent))
                        .scaleEffect(0.6)
                    Text("Uploading…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                    Text("\(generationCost)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.textPrimary.opacity(0.85))
                        .contentTransition(.numericText())
                        .animation(.snappy, value: generationCost)
                    Text("credits")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasInsufficientCredits ? "Insufficient credits" :
            missingRequiredImage ? "Attach an image to use this model" :
            "Estimated cost \(generationCost) credits"
        )
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        ZStack(alignment: .topTrailing) {
            promptBarContent
            if !promptText.isEmpty {
                clearPromptButton
                    .padding(.trailing, 50)
                    .offset(y: 4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: promptText.isEmpty)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var clearPromptButton: some View {
        Button {
            clearPrompt()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textPrimary.opacity(0.85))
                .frame(width: 20, height: 20)
                .background(theme.surface, in: Circle())
                .overlay(Circle().stroke(theme.surfaceBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var promptBarContent: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                // Left column: paperclip + card stack
                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        Button {
                            showPhotosPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showCameraPicker = true
                            } label: {
                                Label(selectedModelRequiresImage ? "Take Photo" : "Take Photo or Video", systemImage: "camera")
                            }
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .photosPicker(
                        isPresented: $showPhotosPicker,
                        selection: $selectedPickerItem,
                        matching: selectedModelRequiresImage ? .images : .any(of: [.images, .videos])
                    )

                    if !attachedReferences.isEmpty {
                        referenceCardStack
                    }
                }
                .padding(.leading, 10)
                .padding(.top, 10)
                .padding(.bottom, 2)

                // Prompt text — single UITextView layout applies [token] highlighting directly
                // to its text storage, so the caret and the drawn glyphs share one layout engine
                // and can never diverge (the old two-layer ghost-text ZStack let SwiftUI's Text
                // and the TextField wrap long words at different points, landing the caret
                // mid-word). UITextView handles its own internal scrolling past maxHeight.
                ZStack(alignment: .topLeading) {
                    if promptText.isEmpty {
                        Text("Describe a scene...")
                            .font(.body)
                            .foregroundStyle(theme.textTertiary)
                            .allowsHitTesting(false)
                            .padding(.top, 0.5)
                    }
                    HighlightingTextView(
                        text: $promptText,
                        selectedRange: $promptTextRange,
                        isFocused: Binding(get: { promptFocused }, set: { promptFocused = $0 }),
                        contentHeight: $promptTextHeight,
                        accentColor: UIColor(accent),
                        textColor: UIColor(theme.textPrimary)
                    )
                    .frame(height: max(22, promptTextHeight))
                }
                .padding(.leading, 4)
                .padding(.trailing, 15)
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

            Rectangle()
                .fill(theme.divider)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)

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
                    .foregroundStyle(hasNonDefaultSettings ? theme.textPrimary : theme.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hasNonDefaultSettings ? theme.surfaceStrong : theme.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(hasNonDefaultSettings ? theme.surfaceStrongBorder : theme.surfaceBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Spacer()
                creditCostLabel
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
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.surfaceStrongBorder, lineWidth: 1))
    }

    // MARK: - Reference card stack (below paperclip)
    // Cards fan to the right: index 0 = leftmost/oldest, last = rightmost/newest (top).

    private var referenceCardStack: some View {
        let visible = Array(attachedReferences.suffix(3))
        let totalWidth = 40 + CGFloat(max(0, visible.count - 1)) * 3
        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, ref in
                referenceCard(ref)
                    .offset(x: CGFloat(index) * 3, y: 0)
                    .zIndex(Double(index))
            }
        }
        .frame(width: totalWidth, height: 54)
    }

    @ViewBuilder
    private func referenceCard(_ ref: AttachedReference) -> some View {
        let label = attachedReferenceLabel(ref)
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 3) {
                // Thumbnail
                Group {
                    if ref.isUploading {
                        ZStack {
                            Color.white.opacity(0.08)
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.6)))
                                .scaleEffect(0.5)
                        }
                    } else if let thumb = ref.thumbnail {
                        // Pin frame to the chip and drop the scaledToFill overflow from hit
                        // testing — otherwise the oversized layout frame steals taps meant for
                        // neighboring chips (see GenerationCardView media buttons).
                        Color.clear
                            .overlay {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .allowsHitTesting(false)
                            }
                            .clipped()
                            .contentShape(Rectangle())
                    } else if let urlStr = ref.thumbnailURL ?? (ref.isVideo ? nil : ref.url),
                              let url = URL(string: urlStr) {
                        // Perf: uploadId (when present) is a stable server-side id, unlike the
                        // presigned URL which rotates per-fetch and would defeat AsyncImage's
                        // (nonexistent) caching. See CachedThumbnailImage.
                        CachedThumbnailImage(cacheKey: (ref.uploadId ?? ref.id) + "-ref", url: url)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "video.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.2), lineWidth: 0.5))

                // Name label
                Text(label)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 40)
            }

            Button { removeReference(ref) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .offset(x: 5, y: -16)
        }
        .contextMenu(menuItems: {
            if !ref.isUploading,
               let uploadId = ref.uploadId,
               let libItem = mediaLibrary.items.first(where: { $0.id == uploadId }) {
                Button("Rename") {
                    renamingItem = libItem
                    renameText = libItem.displayName ?? ""
                }
            } else if !ref.isUploading,
                      ref.uploadId == nil,
                      let generationId = ref.sourceGenerationId,
                      let sourceItem = generationManager.generations.first(where: { $0.id == generationId }) {
                // Attached straight from a generation's output (no reference_uploads row yet) —
                // route through the same "Name as reference" flow as the generation card's
                // long-press, which creates that row and then backfills this chip.
                Button("Name as reference") {
                    handleNameAsReference(item: sourceItem)
                }
            }
            Button("Remove", role: .destructive) { removeReference(ref) }
        })
    }

    private func attachedReferenceLabel(_ ref: AttachedReference) -> String {
        if let name = ref.displayName, !name.isEmpty { return name }
        var imageCount = 0
        var videoCount = 0
        for r in attachedReferences {
            if r.isVideo { videoCount += 1 } else { imageCount += 1 }
            if r.id == ref.id {
                return ref.isVideo ? "Video \(videoCount)" : "Image \(imageCount)"
            }
        }
        return ref.isVideo ? "Video" : "Image"
    }

    // MARK: - @-mention inline suggestion list

    private var mentionSuggestionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if mediaLibrary.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding()
                } else {
                    ForEach(Array(mentionSuggestions.enumerated()), id: \.element.id) { idx, candidate in
                        Button {
                            commitMention(candidate)
                        } label: {
                            HStack(spacing: 10) {
                                libraryItemThumbnail(cacheKey: candidate.id, isVideo: candidate.isVideo, url: candidate.thumbnailURL, size: 40)
                                Text(candidate.displayLabel(in: mediaLibrary.items))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(candidate.hasCustomName ? .white : .white.opacity(0.55))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            switch candidate {
                            case .upload(let item):
                                Button("Rename") {
                                    renamingItem = item
                                    renameText = item.displayName ?? ""
                                    mentionQuery = nil
                                    showMentionSuggestions = false
                                }
                                Button("Delete", role: .destructive) {
                                    mentionQuery = nil
                                    showMentionSuggestions = false
                                    Task { await deleteLibraryItem(item) }
                                }
                            case .generation(let item):
                                Button("Name as reference") {
                                    mentionQuery = nil
                                    showMentionSuggestions = false
                                    handleNameAsReference(item: item)
                                }
                            }
                        }
                        if candidate.id != mentionSuggestions.last?.id {
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 220)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func libraryItemThumbnail(cacheKey: String, isVideo: Bool, url: String?, size: CGFloat = 64) -> some View {
        let radius = size * 0.125
        ZStack {
            if isVideo {
                LinearGradient(
                    colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                             Color(red: 0.416, green: 0.561, blue: 0.878)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "video.fill")
                    .font(.system(size: size * 0.31, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                // Perf: cacheKey is the mention candidate's stable DB id (upload or generation
                // id) — see CachedThumbnailImage for why this replaces AsyncImage here.
                CachedThumbnailImage(cacheKey: cacheKey + "-lib", url: url.flatMap(URL.init(string:)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    /// The name this item will effectively be called if the rename sheet is submitted blank —
    /// shown as the sheet's placeholder so the user knows the default before they type anything.
    private func defaultSlotPlaceholder(for item: ReferenceUploadItem) -> String {
        var count = 0
        for lib in mediaLibrary.items {
            if lib.isVideo == item.isVideo { count += 1 }
            if lib.id == item.id { return item.isVideo ? "Video \(count)" : "Image \(count)" }
        }
        return item.isVideo ? "Video" : "Image"
    }

    // MARK: - Library actions

    /// Finds the "@query" the user just typed, searching only up to the caret so a stray
    /// identical "@query" substring elsewhere in the prompt (after the caret) can't be
    /// matched instead — the same caret-bounding fix as the trigger detection above.
    private func rangeOfActiveMention(query q: String) -> Range<String.Index>? {
        let caretEnd = promptCursorIndex(in: promptText) ?? promptText.endIndex
        return promptText[..<caretEnd].range(of: "@\(q)", options: .backwards)
    }

    private func commitMention(_ candidate: MentionCandidate) {
        guard let q = mentionQuery else { return }

        switch candidate {
        case .upload(let item):
            let token: String
            if let name = item.displayName, !name.isEmpty {
                token = "[\(name)]"
            } else {
                let imageSlot = attachedReferences.filter { !$0.isVideo && $0.uploadId != item.id }.count + 1
                let videoSlot = attachedReferences.filter { $0.isVideo && $0.uploadId != item.id }.count + 1
                token = item.isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
            }

            if let range = rangeOfActiveMention(query: q) {
                promptText.replaceSubrange(range, with: token)
            }

            if !attachedReferences.contains(where: { $0.uploadId == item.id }) {
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

        case .generation(let item):
            // Same shape as attachReference(from:), plus the @-mention token insertion that
            // flow doesn't need (the "Reference" button never touches the prompt text).
            guard item.status == .completed, let urlString = item.completedMediaUrl, !urlString.isEmpty else { break }
            let isVideo = !item.isImage
            let alreadyAttached = attachedReferences.contains { $0.url == urlString }

            if !alreadyAttached {
                let imageSlot = attachedReferences.filter { !$0.isVideo }.count + 1
                let videoSlot = attachedReferences.filter { $0.isVideo }.count + 1
                let token = isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
                if let range = rangeOfActiveMention(query: q) {
                    promptText.replaceSubrange(range, with: token)
                }
                let ref = AttachedReference(
                    mimeType: isVideo ? "video/mp4" : "image/jpeg",
                    thumbnailURL: isVideo ? nil : urlString,
                    fromLibrary: true,
                    isUploading: false,
                    uploadId: nil,
                    url: urlString,
                    sourceGenerationId: item.id
                )
                attachedReferences.append(ref)
            } else if let range = rangeOfActiveMention(query: q) {
                promptText.replaceSubrange(range, with: "")
            }
        }

        mentionQuery = nil
        showMentionSuggestions = false
    }

    private func applyRename(to item: ReferenceUploadItem, name: String) async {
        try? await APIClient.shared.renameUpload(id: item.id, displayName: name)
        let resolved = name.isEmpty ? nil : name
        mediaLibrary.rename(id: item.id, to: resolved)
        if let idx = attachedReferences.firstIndex(where: { $0.uploadId == item.id }) {
            attachedReferences[idx].displayName = resolved
            rebuildPromptTokens()
        }
    }

    private func deleteLibraryItem(_ item: ReferenceUploadItem) async {
        try? await APIClient.shared.deleteUpload(id: item.id)
        withAnimation(.spring(response: 0.3)) {
            mediaLibrary.remove(id: item.id)
            attachedReferences.removeAll { $0.uploadId == item.id }
            rebuildPromptTokens()
        }
    }

    // MARK: - Attachment handlers

    private func handlePickerSelection(_ pickerItem: PhotosPickerItem?) async {
        guard let item = pickerItem else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        let contentTypes = item.supportedContentTypes
        let isVideo = contentTypes.contains(.movie) || contentTypes.contains(.mpeg4Movie)
        await handleAttachedData(data, isVideo: isVideo)

        // Reset picker so it can fire again for the next image
        selectedPickerItem = nil
    }

    private func handleImportedFile(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }

        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let isVideo = contentType?.conforms(to: .movie) ?? false
        await handleAttachedData(data, isVideo: isVideo)
    }

    /// Uploads a raw attachment and adds its reference card + prompt token. Shared by the
    /// photo library, camera, and file import sources behind the paperclip menu.
    private func handleAttachedData(_ data: Data, isVideo: Bool) async {
        // Compute slot before appending
        let imageSlot = attachedReferences.filter { !$0.isVideo }.count + 1
        let videoSlot = attachedReferences.filter { $0.isVideo }.count + 1

        if isVideo {
            // Perf: file write, duration probe, transcode, final-data read, and thumbnail
            // extraction all happen off the main actor inside MediaPrepService (a plain actor,
            // not @MainActor) — this used to run inline here and stutter the UI on attach.
            guard let written = try? await MediaPrepService.shared.writeAndProbeDuration(data) else {
                showError("Couldn't read the selected video. Try a different file.")
                return
            }

            // Replicate caps total reference-video duration at 15s across all attached videos.
            let newDuration = written.durationSeconds
            let existingDuration = attachedReferences
                .filter { $0.isVideo }
                .reduce(0.0) { $0 + ($1.durationSeconds ?? 0) }
            guard existingDuration + newDuration <= 15 else {
                showError("Reference video is too long — reference videos can't total more than 15 seconds.")
                try? FileManager.default.removeItem(at: written.url)
                return
            }

            let prepared = await MediaPrepService.shared.prepareForUpload(inputURL: written.url, fallbackData: data)
            let finalData = prepared.data
            let thumbnail = prepared.thumbnail

            // Add card in uploading state
            let token = "[Video\(videoSlot)]"
            let ref = AttachedReference(mimeType: "video/mp4", thumbnail: thumbnail, isUploading: true, durationSeconds: newDuration)
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
                        mediaLibrary.insert(
                            ReferenceUploadItem(id: id, url: response.url, mimeType: "video/mp4")
                        )
                    }
                }
            } else {
                // Upload failed — remove card and token, and tell the user why instead of failing silently
                attachedReferences.removeAll { $0.id == tempId }
                rebuildPromptTokens()
                showError("Couldn't upload reference video — it may be too large. Try a shorter or lower-resolution clip.")
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
                        mediaLibrary.insert(
                            ReferenceUploadItem(id: id, url: response.url, mimeType: "image/jpeg")
                        )
                    }
                }
            } else {
                attachedReferences.removeAll { $0.id == tempId }
                rebuildPromptTokens()
            }
        }
    }

    // MARK: - Reference management

    private func removeTopReference() {
        guard let ref = attachedReferences.last else { return }
        removeReference(ref)
    }

    private func removeReference(_ ref: AttachedReference) {
        cancelUploadIfNeeded(ref)
        attachedReferences.removeAll { $0.id == ref.id }
        rebuildPromptTokens()
    }

    /// Clears the whole prompt: text plus every attached reference. Used by the "clear text"
    /// button — without this, attached references silently survived a text clear (no visible
    /// token pointing at them) and still got sent along with whatever the user typed next.
    private func clearPrompt() {
        for ref in attachedReferences { cancelUploadIfNeeded(ref) }
        attachedReferences.removeAll()
        promptText = ""
    }

    private func cancelUploadIfNeeded(_ ref: AttachedReference) {
        if let uploadId = ref.uploadId, !ref.fromLibrary {
            Task { try? await APIClient.shared.deleteUpload(id: uploadId) }
        }
    }

    /// The caret's insertion-point index within `text`, or nil if there's a range selection
    /// or the field hasn't reported a selection yet (e.g. right after a programmatic edit).
    private func promptCursorIndex(in text: String) -> String.Index? {
        guard let range = promptTextRange, range.length == 0 else { return nil }
        // promptTextRange can be stale relative to `text` when promptText was just changed
        // programmatically (e.g. removing a reference rebuilds the prompt) rather than by a
        // live keystroke — using an out-of-bounds offset here crashes deep inside Foundation's
        // UTF-16 index conversion, so fall back to "unknown cursor" instead of trusting it blindly.
        guard range.location >= 0, range.location <= text.utf16.count else { return nil }
        return String.Index(utf16Offset: range.location, in: text)
    }

    /// Detects a single-character deletion that landed inside a [token] and returns
    /// the snapped text (whole token removed) plus the token's inner content for dereferencing.
    private func atomicTokenDeletion(old: String, new: String) -> (text: String, inner: String?)? {
        let oldNS = old as NSString
        let newNS = new as NSString
        guard newNS.length == oldNS.length - 1 else { return nil }

        // Find the position (in old) of the deleted character
        var diffPos = 0
        while diffPos < newNS.length && oldNS.character(at: diffPos) == newNS.character(at: diffPos) {
            diffPos += 1
        }

        guard let re = Self.bracketTokenRegex else { return nil }
        for match in re.matches(in: old, range: NSRange(location: 0, length: oldNS.length)) {
            let start = match.range.location
            let end = start + match.range.length
            guard diffPos >= start && diffPos < end else { continue }

            // Deleted char was inside this token — snap to removing the whole thing
            guard let tokenRange = Range(match.range, in: old) else { continue }
            let inner = String(String(old[tokenRange]).dropFirst().dropLast())

            // Eat one flanking space to avoid double-spaces
            var removeRange = match.range
            if removeRange.location > 0 && oldNS.character(at: removeRange.location - 1) == 32 {
                removeRange.location -= 1
                removeRange.length += 1
            } else if end < oldNS.length && oldNS.character(at: end) == 32 {
                removeRange.length += 1
            }

            var result = old
            if let r = Range(removeRange, in: old) { result.removeSubrange(r) }
            return (result, inner)
        }
        return nil
    }

    /// Removes the attachment whose prompt token had the given inner content.
    /// For named refs ([bob] → inner="bob"), matches by displayName.
    /// For positional refs ([Image1] → inner="Image1"), matches by slot index then rebuilds.
    private func dereferenceToken(_ inner: String) {
        // Named token
        if let idx = attachedReferences.firstIndex(where: {
            let name = ($0.displayName ?? "").trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name.caseInsensitiveCompare(inner) == .orderedSame
        }) {
            attachedReferences.remove(at: idx)
            return
        }

        // Positional token: "Image2" or "Video1"
        let isVideo = inner.hasPrefix("Video")
        let prefix = isVideo ? "Video" : "Image"
        if inner.hasPrefix(prefix), let n = Int(inner.dropFirst(prefix.count)), n >= 1 {
            let indices = attachedReferences.indices.filter {
                attachedReferences[$0].isVideo == isVideo &&
                (attachedReferences[$0].displayName ?? "").isEmpty
            }
            if n - 1 < indices.count {
                attachedReferences.remove(at: indices[n - 1])
                rebuildPromptTokens()
            }
        }
    }

    /// Rebuilds [ImageN]/[VideoN] tokens in the prompt to match current attachedReferences.
    /// Strips all existing tokens then re-appends based on current array order.
    private func rebuildPromptTokens() {
        var text = promptText
        // Strip ALL [anything] tokens — covers named ([sarah]) and positional ([Image1])
        if let re = Self.bracketTokenWithLeadingSpaceRegex {
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
                    imageQuality: nil,
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
                    imageAspectRatio: nil,
                    imageQuality: nil,
                    referenceImages: refImages.isEmpty ? nil : refImages,
                    referenceVideos: refVideos.isEmpty ? nil : refVideos,
                    referenceUploadIds: refUploadIds.isEmpty ? nil : refUploadIds
                )
            }
            _ = try await APIClient.shared.submitGeneration(body: body)

            promptText = ""
            attachedReferences = []
            // forceRefresh: the just-created item isn't in the cached array yet, so the
            // staleness guard in startPolling() must be bypassed here regardless of how
            // recently the list was last fetched (was a separate explicit refresh() call before).
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()

        } catch let apiError as APIError {
            if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                showError("Prompt may not adhere to our community guidelines. Please try again.")
            } else {
                showError("An error has occurred. Please try again.")
            }
            await generationManager.refresh()
        } catch {
            print("[GenerateView] dispatch error: \(error)")
            showError("An error has occurred. Please try again.")
            await generationManager.refresh()
        }
    }

    private func showError(_ message: String) {
        withAnimation { errorMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { errorMessage = nil }
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

    // Reference — attach this generation's own output as a new reference input,
    // without touching the current prompt or settings. Unlike Remix (which
    // reloads the original prompt/settings/references for editing), this lets
    // the user build on the *result* of a past generation.
    private func handleReference(item: GenerationItem) {
        attachReference(from: item)
    }

    private func attachReference(from item: GenerationItem) {
        guard item.status == .completed else { return }
        let urlString = item.isImage ? item.completedMediaUrl : item.videoUrl
        guard let urlString, !urlString.isEmpty else { return }
        let isVideo = !item.isImage
        let imageSlot = attachedReferences.filter { !$0.isVideo }.count + 1
        let videoSlot = attachedReferences.filter { $0.isVideo }.count + 1
        let token = isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
        let attached = AttachedReference(
            mimeType: isVideo ? "video/mp4" : "image/jpeg",
            thumbnailURL: item.isImage ? urlString : nil,
            fromLibrary: true,
            isUploading: false,
            uploadId: nil,
            url: urlString,
            sourceGenerationId: item.id
        )
        attachedReferences.append(attached)
        insertToken(token)
        promptFocused = true
    }

    // Long-press "Name as reference" — promotes this generation's output into the permanent
    // reference library (server copies the R2 object so it's independently owned and never
    // expires), unlike the "Reference" button which only attaches a short-lived presigned URL
    // to the current draft.
    private func handleNameAsReference(item: GenerationItem) {
        guard item.status == .completed else { return }
        newReferenceName = ""
        namingReferenceFromGeneration = item
    }

    private func saveGenerationAsReference(item: GenerationItem, name: String) async {
        guard let response = try? await APIClient.shared.createReferenceFromGeneration(
            generationId: item.id, displayName: name
        ), let id = response.id else {
            showError("Couldn't save this as a reference.")
            return
        }
        let resolvedName = response.displayName ?? (name.isEmpty ? nil : name)
        withAnimation(.spring(response: 0.3)) {
            mediaLibrary.insert(
                ReferenceUploadItem(
                    id: id,
                    url: response.url,
                    mimeType: response.mimeType ?? (item.isImage ? "image/jpeg" : "video/mp4"),
                    displayName: resolvedName
                )
            )
        }
        // If this generation's output is already attached to the current draft (e.g. via the
        // "Reference" button or an @-mention), it was attached with uploadId: nil since no
        // reference_uploads row existed yet — now that we've just created one, back-fill it so
        // the chip picks up the name/token and future long-presses use the normal rename path.
        if let idx = attachedReferences.firstIndex(where: { $0.sourceGenerationId == item.id && $0.uploadId == nil }) {
            attachedReferences[idx].uploadId = id
            attachedReferences[idx].displayName = resolvedName
            rebuildPromptTokens()
        }
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
            aspectRatio: item.isImage ? nil : item.params.aspectRatio,
            audioEnabled: item.params.audioEnabled,
            imageAspectRatio: item.isImage ? item.params.aspectRatio : nil,
            imageQuality: nil,
            referenceImages: refImages,
            referenceVideos: refVideos,
            referenceUploadIds: nil
        )
        do {
            _ = try await APIClient.shared.submitGeneration(body: body)
            generationManager.startPolling(forceRefresh: true)
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

// MARK: - NameReferenceSheet

/// Shared naming UI for both "rename an existing upload" and "name this generation as a
/// reference" flows. The leading "@" is a static prefix (not editable) so the field reads as
/// "@name" — teaching the user that whatever they type here is what they'll type after "@" in
/// the prompt bar to recall this reference later. The placeholder shows the positional default
/// (e.g. "Image 1") the item falls back to if saved blank.
private struct NameReferenceSheet: View {
    let placeholder: String
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    var body: some View {
        VStack(spacing: 18) {
            Text("Name this reference")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 22)

            HStack(spacing: 2) {
                Text("@")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)
                TextField(placeholder, text: $text)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .focused($focused)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .padding(.horizontal, 20)

            Text("Type \"@\(text.isEmpty ? placeholder : text)\" in a prompt to use it again.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button {
                    onSave(text)
                } label: {
                    Text("Save")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            Spacer(minLength: 0)
        }
        .background(Color(red: 0.1, green: 0.095, blue: 0.12))
        .onAppear { focused = true }
    }
}

// MARK: - MentionCandidate

/// An entry in the @-mention suggestion list — either a saved reference_uploads item, or a
/// synthetic candidate wrapping a live GenerationItem (e.g. "latest generation"). GenerationItem
/// has no display_name of its own, so it's never eligible for name-filtered search results;
/// it only ever appears in the default (just-typed-@, no filter text) suggestion list.
private enum MentionCandidate: Identifiable {
    case upload(ReferenceUploadItem)
    case generation(GenerationItem)

    var id: String {
        switch self {
        case .upload(let item): return "upload-\(item.id)"
        case .generation(let item): return "generation-\(item.id)"
        }
    }

    var isVideo: Bool {
        switch self {
        case .upload(let item): return item.isVideo
        case .generation(let item): return !item.isImage
        }
    }

    var thumbnailURL: String? {
        switch self {
        case .upload(let item): return item.isVideo ? nil : item.url
        case .generation(let item): return item.isImage ? item.completedMediaUrl : nil
        }
    }

    var hasCustomName: Bool {
        if case .upload(let item) = self { return item.displayName != nil }
        return false
    }

    /// mediaLibraryItems is passed in so unnamed uploads can compute the same "Video N"/"Image N"
    /// positional label GenerateView already shows elsewhere (librarySlotLabel).
    func displayLabel(in mediaLibraryItems: [ReferenceUploadItem]) -> String {
        switch self {
        case .upload(let item):
            if let name = item.displayName { return name }
            var count = 0
            for lib in mediaLibraryItems {
                if lib.isVideo == item.isVideo { count += 1 }
                if lib.id == item.id { return item.isVideo ? "Video \(count)" : "Image \(count)" }
            }
            return item.isVideo ? "Video" : "Image"
        case .generation:
            return "Latest generation"
        }
    }
}

// MARK: - CachedThumbnailImage

/// AsyncImage replacement that caches by a caller-supplied stable key instead of the URL —
/// presigned URLs rotate on every fetch, which defeats AsyncImage's built-in (URL-keyed, and
/// otherwise nonexistent beyond in-flight dedup) caching for the same underlying asset.
/// Downscales to a small thumbnail size before caching (these are always shown at ≤64pt).
private struct CachedThumbnailImage: View {
    let cacheKey: String
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                // Same frame/hit-test containment as the reference chip thumbnails above.
                Color.clear
                    .overlay {
                        Image(uiImage: image).resizable().scaledToFill()
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .contentShape(Rectangle())
            } else {
                Color.white.opacity(0.08)
            }
        }
        .task(id: cacheKey) {
            guard image == nil else { return }
            if let cached = await ThumbnailCache.shared.image(for: cacheKey) { image = cached; return }
            guard let url, let (data, _) = try? await URLSession.shared.data(from: url),
                  let downloaded = UIImage(data: data) else { return }
            let thumb = downloaded.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? downloaded
            ThumbnailCache.shared[cacheKey] = thumb
            image = thumb
        }
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
    var durationSeconds: Double?   // video references only — used to enforce Replicate's 15s total cap
    // Set when this reference's media came directly from a generation's output (via the
    // "Reference" button or an @-mention on a live generation) rather than an existing
    // reference_uploads row. uploadId is nil until the user names it — see saveGenerationAsReference.
    var sourceGenerationId: String?

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isReady: Bool { !isUploading && !url.isEmpty }

    func compositionToken(imageSlot: Int, videoSlot: Int) -> String {
        if let name = displayName, !name.isEmpty { return "[\(name)]" }
        return isVideo ? "[Video\(videoSlot)]" : "[Image\(imageSlot)]"
    }

    init(mimeType: String, thumbnail: UIImage? = nil, thumbnailURL: String? = nil,
         fromLibrary: Bool = false, isUploading: Bool = false,
         uploadId: String? = nil, url: String = "", displayName: String? = nil,
         durationSeconds: Double? = nil, sourceGenerationId: String? = nil) {
        self.id = UUID().uuidString
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.thumbnailURL = thumbnailURL
        self.fromLibrary = fromLibrary
        self.isUploading = isUploading
        self.uploadId = uploadId
        self.url = url
        self.displayName = displayName
        self.durationSeconds = durationSeconds
        self.sourceGenerationId = sourceGenerationId
    }
}

#Preview {
    NavigationStack { GenerateView() }
        .environment(CreditManager())
        .environment(AuthManager())
        .environment(GenerationManager())
        .environment(MediaLibraryManager())
        .environment(ThemeManager())
        .preferredColorScheme(.dark)
}
