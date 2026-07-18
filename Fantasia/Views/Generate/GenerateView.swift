// GenerateView.swift
// Fantasia
// Chat-style generation hub: prompt bar pinned at bottom, generations scroll upward above it.
// Empty state shows inspiration chips. No separate Feed tab — everything lives here.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// Tracks the top-load-trigger row's position within the history ScrollView so we know when
// it has scrolled into the visible viewport, without relying on onAppear (which fires
// immediately for offscreen rows in a non-lazy VStack — see Issue 2 in fix-ux-batch2-plan.md).
private struct HistoryTopOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct GenerateView: View {
    @Environment(CreditManager.self) private var creditManager
    @Environment(AuthManager.self) private var authManager
    @Environment(GenerationManager.self) private var generationManager
    @Environment(RatesManager.self) private var ratesManager
    @Environment(DrawerManager.self) private var drawer
    @Environment(ThemeManager.self) private var theme
    @Environment(MediaLibraryManager.self) private var mediaLibrary

    // Perf: previously compiled fresh inside highlightedPrompt (recomputed on every body render,
    // i.e. every keystroke) and rebuildPromptTokens. Hoisted to a compile-once static constant —
    // same pattern, no behavior change.
    private static let bracketTokenWithLeadingSpaceRegex = try? NSRegularExpression(pattern: "\\s*\\[[^\\]]+\\]")
    private static let mentionTriggerRegex = try? NSRegularExpression(pattern: #"@(\w*)$"#)

    @State private var promptText = ""
    // Cursor/selection in the prompt field — the @-mention trigger needs to know where the
    // caret actually is, since editing text earlier in the prompt leaves the caret short of
    // promptText's end (e.g. after a previously inserted [Image1] token).
    @State private var promptTextRange: NSRange?
    @State private var promptTextHeight: CGFloat = 22
    // Fixed top inset for the composer's first text line, replacing the old ZStack
    // center-alignment: centering a `max(44, promptTextHeight)`-tall box made the top gap shrink
    // toward 0 once text wrapped to a 2nd line (content height crossed the 44pt floor, so the
    // centering slack that used to pad the top disappeared). (44 - single-line height 22) / 2.
    private let promptFirstLineTopInset: CGFloat = 11
    @State private var showProfileSheet = false
    @State private var promptFocused: Bool = false
    // Keyboard scroll-to-dismiss: minimum downward drag over the history list before the
    // keyboard drops (2026-07-12 fix — replaces .scrollDismissesKeyboard(.immediately), which
    // has no distance threshold and fired on virtually any scroll motion). Tune by feel.
    private let keyboardDismissSwipeThreshold: CGFloat = 50
    @State private var keyboardDismissTriggeredThisGesture = false

    // D-18: option state with defaults
    @State private var selectedMode = "AI Video"
    @State private var selectedModel = "bytedance/seedance-2.0-mini"
    @State private var selectedDuration = 6
    @State private var selectedResolution = "720p"
    @State private var selectedAspectRatio = "9:16"
    @State private var audioEnabled = true
    @State private var selectedImageResolution: ImageResolution = .square

    // Preset registry lookup — used only by attachReference(from:) to detect presets whose true
    // output aspect is data-dependent (sheet.aspect_label "Matches your photo/video") before
    // trusting their stored params.aspectRatio (see applyAspectRatioFromReference call site).
    // Bundled fallback + snapshot cache (PresetRegistryManager), so this is instant on cold start.
    @State private var presetRegistry = PresetRegistryManager()

    // Multi-reference attachment state
    @State private var selectedPickerItem: PhotosPickerItem?
    private let maxReferences = 3
    @State private var attachedReferences: [AttachedReference] = []
    // Keys are a token's inner text (lowercased, no brackets) — feeds HighlightingTextView's
    // inline pill rendering (Issue 6). Rebuilt whenever a reference is added/removed/renamed.
    @State private var tokenThumbnails: [String: UIImage] = [:]
    @State private var tokenThumbnailsGeneration = 0
    @State private var showPhotosPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false

    // Rename an existing upload (distinct from generationManager.pendingNameAsReference,
    // which promotes a past generation's output into a brand-new reference — see
    // NameAsReferenceAlertModifier).
    @State private var renamingItem: ReferenceUploadItem? = nil
    @State private var renameText = ""

    // Media library + @-mention state.
    // showReferencePanel now drives an inline suggestion list pinned ABOVE the composer with the
    // keyboard STAYING UP (reverted from the T8b bottom keyboard-dismiss grid, commit 735d73d, on
    // 2026-07-13) — keeping the keyboard up is what lets the user keep typing "@name" so
    // mentionSuggestions filters live. The bottom-grid version is snapshotted at
    // ~/.planning/backups/GenerateView.reference-bottom-panel.2026-07-13.swift.
    @State private var mentionQuery: String? = nil
    @State private var showReferencePanel = false

    // Paywall and submit state
    @State private var showPaywall = false
    @State private var isSubmitting = false
    @State private var errorMessage: String? = nil

    // Card actions
    @State private var selectedItem: GenerationItem? = nil
    @State private var isLoadingOlderHistory = false
    @State private var confirmDeleteItem: GenerationItem? = nil
    @State private var deletingItemIds: Set<String> = []
    // Swipe-to-delete confirmation for reference uploads in the @-mention list (parallel to the
    // GenerationItem card-delete state above, but for ReferenceUploadItem).
    @State private var confirmDeleteReference: ReferenceUploadItem? = nil

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)

    private var hasVideoReference: Bool {
        attachedReferences.contains { $0.isVideo }
    }

    private var mentionSuggestions: [MentionCandidate] {
        guard let q = mentionQuery, !q.isEmpty else { return defaultMentionSuggestions }
        // Match against the VISIBLE label (displayLabel), not the raw displayName — an unnamed
        // upload shows as its positional "Image 1"/"Video 2" label, so typing "i" must match those
        // rows the user actually sees (the old code matched displayName only, so unnamed items were
        // invisible to the filter — the "Image 1 disappears when I type i" report, 2026-07-13).
        //
        // PREFIX-ONLY (anchored): typing "i" matches "Image 1" but must NOT surface "commercial"
        // just because it contains an "i" mid-word (the "shows something unrelated" half of the
        // same report). Results stay in mediaLibrary order (newest-first), which is deterministic —
        // not the random-looking set the pre-fix substring match produced.
        let items = mediaLibrary.items
        return items
            .filter { item in
                let label = MentionCandidate.upload(item).displayLabel(in: items)
                return label.range(of: q, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
            }
            .map { .upload($0) }
    }

    /// The gray inline-completion suffix drawn after the caret: the remaining characters of the
    /// TOP suggestion's visible label beyond what the user has already typed. Empty when there's no
    /// active mention, no suggestion, or the query already spans the whole label. Because the filter
    /// is prefix-only, the top suggestion always starts with the query, so `dropFirst(q.count)` is
    /// the true remainder (label's own casing preserved). This is what Return commits.
    private var mentionGhostSuffix: String {
        guard showReferencePanel,
              let q = mentionQuery, !q.isEmpty,
              let top = mentionSuggestions.first else { return "" }
        let label = top.displayLabel(in: mediaLibrary.items)
        guard label.count > q.count,
              label.range(of: q, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
        else { return "" }
        return String(label.dropFirst(q.count))
    }

    /// Return-key / ghost accept: commit the TOP suggestion (the one the ghost previews), exactly
    /// as tapping its row would. No-op if the list is empty.
    private func acceptTopMentionCompletion() {
        guard showReferencePanel, let top = mentionSuggestions.first else { return }
        commitMention(top)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
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
        if let latestGeneration = generationManager.feedGenerations.first(where: {
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
        isSubmitting || isAnyUploading
    }

    private var generationCost: Int {
        if selectedMode == "AI Image" {
            return ratesManager.imageCost(for: selectedModel)
        }
        return ratesManager.cost(
            model: selectedModel,
            durationSeconds: selectedDuration,
            resolution: selectedResolution,
            hasVideoReference: hasVideoReference,
            audioEnabled: audioEnabled
        )
    }

    private var hasInsufficientCredits: Bool {
        creditManager.entitlementLevel != .none && creditManager.creditsBalance < generationCost
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
                .onTapGesture {
                    // Dismissing the keyboard also closes the inline @-mention list via
                    // onChange(of: promptFocused) above — no separate panel teardown needed.
                    promptFocused = false
                }
                // Covers the empty-history state (centerContent/chips, no ScrollView present) —
                // the ScrollView case below has its own copy of this same drag-to-dismiss check
                // since the ScrollView sits on top of this background and claims the touch there.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { _ in
                            if promptFocused { promptFocused = false }
                        }
                )

            VStack(spacing: 0) {
                topBar

                if generationManager.feedGenerations.isEmpty && !generationManager.hasLoadedOnce {
                    // Initial history fetch still in flight — show a spinner instead of the
                    // "What will you create?" empty state, which was misleadingly flashing
                    // for returning users while their (non-empty) history was still loading.
                    Spacer()
                    ProgressView()
                        .tint(.white.opacity(0.6))
                    Spacer()
                } else if generationManager.feedGenerations.isEmpty {
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
                                if generationManager.nextCursor != nil {
                                    // Reports its position instead of using onAppear — onAppear
                                    // fires immediately for offscreen rows in a non-lazy VStack.
                                    Color.clear
                                        .frame(height: 1)
                                        .background(
                                            GeometryReader { geo in
                                                Color.clear.preference(
                                                    key: HistoryTopOffsetKey.self,
                                                    value: geo.frame(in: .named("generateHistoryScroll")).minY
                                                )
                                            }
                                        )
                                }
                                ForEach(generationManager.feedGenerations.reversed()) { item in
                                    SwipeToDeleteRow(
                                        onRequestDelete: { confirmDeleteItem = item },
                                        isHeldOpen: confirmDeleteItem?.id == item.id || deletingItemIds.contains(item.id)
                                    ) {
                                        GenerationCardView(
                                            item: item,
                                            onTapDetail: { selectedItem = item },
                                            onRemix: { handleRemix(item: item) },
                                            onRegenerate: { Task { await handleRegenerate(item: item) } },
                                            onReference: { handleReference(item: item) },
                                            onNameAsReference: { handleNameAsReference(item: item) },
                                            onDelete: { Task { await handleDelete(item: item) } },
                                            onRequestDelete: { confirmDeleteItem = item }
                                        )
                                    }
                                    .id(item.id)
                                    // Deleted card exits stage-left (handleDelete wraps the
                                    // removal in withAnimation); insertions just fade so new
                                    // pending cards don't slide in from the edge.
                                    .transition(.asymmetric(
                                        insertion: .opacity,
                                        removal: .move(edge: .leading).combined(with: .opacity)
                                    ))
                                }
                            }
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                        }
                        .coordinateSpace(name: "generateHistoryScroll")
                        .onPreferenceChange(HistoryTopOffsetKey.self) { minY in
                            guard let minY, minY > 0, minY < 700 else { return }
                            Task { await loadOlderHistory(proxy: proxy) }
                        }
                        // FIX (2026-07-12): .defaultScrollAnchor(.bottom) REMOVED — it was the
                        // actual cause of cards shifting up when focusing the composer at the
                        // true bottom of the list (confirmed via research: SwiftUI ScrollView
                        // legitimately observes a sibling's growing safeAreaInset region, and a
                        // BOTTOM anchor re-pins the last item above that region on every resize,
                        // including the composer's keyboard-driven growth — not a bug, just the
                        // wrong anchor choice for this screen. An `.ignoresSafeArea(.keyboard,
                        // edges: .bottom)` attempt on the list's container did NOT fix this —
                        // confirmed on-device — because the region being observed isn't tagged
                        // `.keyboard`, it's the composer's own safeAreaInset region growing for
                        // any reason). With NO persistent anchor, ScrollView defaults to a TOP
                        // anchor: a shrinking visible area (keyboard rising) just clips the
                        // bottom rather than re-pinning everything above it — matches the "list
                        // stays static, keyboard covers whatever's at the bottom" behavior every
                        // other app has. The list's own dynamic bottom padding/inset (still
                        // correctly avoiding the composer's current height at rest) is UNCHANGED
                        // — only the re-pin-on-resize behavior is gone.
                        //
                        // This removes the one thing .defaultScrollAnchor(.bottom) ALSO did:
                        // set the list's INITIAL scroll position on first appearance (confirmed —
                        // no other code did this; the existing .onAppear only calls
                        // startPolling()/remix/reference prefill). Replaced below with a
                        // one-time, UN-ANIMATED scroll — deliberately NOT scrollToNewest() (that
                        // helper wraps proxy.scrollTo in withAnimation, which is correct for a
                        // NEW generation sliding into an already-visible list, but was WRONG here:
                        // reusing it made every screen appearance visibly slide the whole list up
                        // from the top on a 0.3s animation — a brand-new, jarring "duplicate
                        // prompt box sliding down" artifact that didn't exist under the old
                        // .defaultScrollAnchor(.bottom) (which positioned correctly on frame one,
                        // silently, with zero visible motion — confirmed as a regression by the
                        // user 2026-07-13, fixed same day). A bare proxy.scrollTo call outside
                        // withAnimation jumps instantly, matching that original silent behavior.
                        .onAppear {
                            if let id = generationManager.feedGenerations.first?.id {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                        // Keyboard dismiss on scroll is handled by the .simultaneousGesture
                        // DragGesture below (keyboardDismissSwipeThreshold), NOT
                        // .scrollDismissesKeyboard — that modifier has no distance-threshold knob
                        // (fires on virtually any scroll motion, felt like a tap) and, per
                        // .planning/notes/keyboard-composer-architecture.md, was masking a
                        // separate bug where the composer's own animation never actually ran
                        // (modifier-order defect, fixed 2026-07-12) — the keyboard was snapping
                        // down in a single frame regardless of which scrollDismissesKeyboard mode
                        // was set. Do not re-add .scrollDismissesKeyboard here.
                        // Pull-to-refresh: manual fallback for server state (Bug C). SwiftUI
                        // supplies the spinner + haptic; refresh() reconciles deletions and adds
                        // any new items via mergeLatest. Does not touch keyboard/composer.
                        .refreshable {
                            await generationManager.refresh()
                        }
                        .onChange(of: generationManager.feedGenerations.first?.id) { _, _ in
                            scrollToNewest(proxy: proxy)
                        }
                        // Brackets an active scroll drag with isInteracting so
                        // GenerationManager.mergeLatest() buffers new items instead of
                        // prepending mid-scroll (ported from the old FeedView pattern). Also owns
                        // keyboard-dismiss-on-scroll (2026-07-12, see keyboardDismissSwipeThreshold)
                        // now that .scrollDismissesKeyboard has been removed above.
                        // minimumDistance MUST stay >= 20: a 0-distance DragGesture on a
                        // ScrollView engages on touch-down and wins arbitration on a quick flick
                        // from rest, blocking the scroll (see LibraryView + GenerationManager
                        // .isInteracting doc comment).
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                                .onChanged { value in
                                    generationManager.isInteracting = true
                                    // The inline @-mention list stays open only while the keyboard
                                    // is up, so the keyboard-dismiss branch below (which flips
                                    // promptFocused → false) also closes the list via
                                    // onChange(of: promptFocused) — no separate teardown needed here.

                                    // Keyboard dismiss: requires a deliberate downward swipe past
                                    // keyboardDismissSwipeThreshold, not the near-instant trigger
                                    // .scrollDismissesKeyboard(.immediately) had. Guarded by
                                    // keyboardDismissTriggeredThisGesture so it fires exactly once
                                    // per drag, not on every pixel past the threshold. promptFocused
                                    // is set inside withAnimation so it's explicitly covered
                                    // regardless of the composer's own .animation(value:) scope —
                                    // see GenerateView.swift's promptFocused animation modifier and
                                    // .planning/notes/keyboard-composer-architecture.md.
                                    if promptFocused,
                                       !keyboardDismissTriggeredThisGesture,
                                       value.translation.height > keyboardDismissSwipeThreshold {
                                        keyboardDismissTriggeredThisGesture = true
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)) {
                                            promptFocused = false
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    generationManager.isInteracting = false
                                    keyboardDismissTriggeredThisGesture = false
                                }
                        )
                    }
                }
            }
        }
        // Keyboard positioning: SwiftUI's built-in avoidance ALONE lifts the bottom safeAreaInset
        // composer above the keyboard (Config C — see .planning/notes/keyboard-composer-architecture.md).
        // Do NOT add .ignoresSafeArea(.keyboard) + manual keyboardOverlap padding here: that
        // double-counts the lift and reopens the big gap between the prompt bar and the keyboard.
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if showReferencePanel && !mentionSuggestions.isEmpty {
                    // Inline @-mention suggestion list pinned above the composer, shown WHILE the
                    // keyboard is up so typing "@name" filters mentionSuggestions live. Opacity-only
                    // transition (not .move) so the ~220pt list can't slide down over the prompt bar
                    // and swallow taps mid-animation. See showReferencePanel's declaration note.
                    mentionSuggestionList
                        .allowsHitTesting(showReferencePanel)
                        .transition(.opacity)
                }
                if let msg = errorMessage {
                    Text(msg)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.red, lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .transition(.opacity)
                }
                promptBar
            }
            .frame(maxWidth: .infinity)
            // Constant base padding only — SwiftUI's keyboard avoidance adds the keyboard lift on
            // top (Config C). Focused: 6pt breathing room above the keyboard. Unfocused: 65pt to
            // clear the custom tab bar. This is the FROZEN composer position — the @-mention list
            // now lives ABOVE the composer (keyboard stays up), so the composer keeps its normal
            // focused/unfocused padding whether or not the list is open. See
            // .planning/notes/keyboard-composer-architecture.md.
            //
            // FIX (2026-07-12): this .padding() MUST stay BEFORE the two .animation(value:)
            // modifiers below — SwiftUI's .animation(_, value:) only covers modifier changes that
            // are already part of the view chain ABOVE it (source order = wrap order). With the
            // animation modifiers written first and this padding after (the original bug), the
            // padding change fell OUTSIDE both animations' scope and snapped instantly — measured
            // via frame-by-frame screen-recording analysis at 1 frame (~16ms), zero interpolation,
            // despite a correctly-tuned spring sitting right next to it. Do NOT move this padding
            // back above the animation modifiers.
            .padding(.bottom, promptFocused ? 6 : 65)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showReferencePanel)
            // MUST exactly match UIKit's keyboard animation curve (mass 3 / stiffness 1000 /
            // damping 500). The composer's dismiss motion is (keyboard lift → 0, system-timed)
            // plus (padding 6 → 65, this animation). Identical curves ⇒ strictly monotonic
            // descent, lowest point at the end. ANY slower curve here makes the padding lag the
            // keyboard, so the composer dips below its resting spot and bounces back up at the
            // end of dismiss (tried 2026-07-06, reverted). Do not retune independently.
            .animation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500), value: promptFocused)
            .background(
                VStack(spacing: 0) {
                    Color.clear.frame(height: 40)
                    theme.elevatedBackground
                }
                .ignoresSafeArea(edges: .bottom)
            )
            // No dismiss-on-drag gesture here by design — swiping down anywhere inside the
            // composer (text box, paperclip column, divider gap, options row) must never dismiss
            // the keyboard; only the history ScrollView's threshold-gated drag gesture (outside
            // the composer, see keyboardDismissSwipeThreshold) does that now (2026-07-12 — was
            // .scrollDismissesKeyboard(.immediately) before the swipe-threshold/haptic fix). See
            // .planning/notes/keyboard-composer-architecture.md.
        }
        .onChange(of: promptText) { old, new in
            // Atomic token deletion now happens inside HighlightingTextView's UITextView
            // delegate (shouldChangeTextIn) — see onTokenDeleted below — so it never round-trips
            // through this onChange.

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
                // Keep the keyboard UP and surface the inline suggestion list above the composer.
                // Because the keyboard stays up, every subsequent keystroke re-runs this handler and
                // updates mentionQuery, so mentionSuggestions filters live as the user types "@name"
                // (reverted from T8b's keyboard-dismiss bottom grid, 2026-07-13).
                mentionQuery = q
                if !showReferencePanel {
                    Task { await mediaLibrary.load() }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = true }
                }
            } else {
                // Trigger no longer matches (user deleted the "@", typed a space, or moved the
                // caret away): clear the query and hide the list. The keyboard was never touched,
                // so there's no dismiss race to guard against here.
                mentionQuery = nil
                if showReferencePanel {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
                }
            }
        }
        .onChange(of: promptFocused) { _, focused in
            // The inline suggestion list lives above the composer and only makes sense while the
            // keyboard is up (that's what enables live "@name" filtering). When the keyboard is
            // dismissed — background tap, swipe-to-dismiss over the history, etc. — close the list
            // too. The typed "@query" is intentionally LEFT in the prompt so the user can refocus
            // and keep going; a re-focus that still has "@…" before the caret re-triggers the
            // onChange(of: promptText) handler above and reopens the list.
            guard !focused, showReferencePanel else { return }
            mentionQuery = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
        }
        .onChange(of: selectedPickerItem) { _, newItem in
            guard newItem != nil else { return }
            Task { await handlePickerSelection(newItem) }
        }
        // Keyed on id + displayName so both attach/remove and rename trigger a rebuild — the
        // composer's inline pills (Issue 6) need to reflect either kind of change.
        .onChange(of: attachedReferences.map { "\($0.id)|\($0.displayName ?? "")" }, initial: true) { _, _ in
            rebuildTokenThumbnails()
        }
        .task { await presetRegistry.loadIfNeeded() }
        .onAppear {
            generationManager.startPolling()
            if let remix = generationManager.pendingRemix {
                applyRemix(from: remix)
                generationManager.pendingRemix = nil
            }
            if let refItem = generationManager.pendingReference {
                attachReference(from: refItem)
                generationManager.pendingReference = nil
            }
        }
        // Covers the case where GenerateView is already on-screen (detail sheet opened from
        // history while already on this tab) — onAppear above doesn't re-fire on sheet dismiss,
        // so the notification path is needed too. Nil-ing pendingRemix/pendingReference after
        // consumption makes firing from both places harmless.
        .onReceive(NotificationCenter.default.publisher(for: .remixGenerationRequested)) { _ in
            if let remix = generationManager.pendingRemix {
                applyRemix(from: remix)
                generationManager.pendingRemix = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .referenceGenerationRequested)) { _ in
            if let refItem = generationManager.pendingReference {
                attachReference(from: refItem)
                generationManager.pendingReference = nil
            }
        }
        .onChange(of: mediaLibrary.lastSavedReference) { _, saved in
            // If the just-named generation's raw output was already attached to the current
            // draft (via the "Reference" button or an @-mention), it was attached with
            // uploadId: nil since no reference_uploads row existed yet — back-fill it now so
            // the chip picks up the name/token and future long-presses use the rename path.
            guard let saved,
                  let idx = attachedReferences.firstIndex(where: {
                      $0.sourceGenerationId == saved.generationId && $0.uploadId == nil
                  }) else { return }
            attachedReferences[idx].uploadId = saved.uploadId
            attachedReferences[idx].displayName = saved.displayName
            rebuildPromptTokens()
        }
        .onDisappear { generationManager.stopPolling() }
        .onReceive(NotificationCenter.default.publisher(for: .generationCompleted)) { _ in
            Task { await generationManager.refresh() }
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileCreditSheet(isPresented: $showProfileSheet)
                .environment(creditManager)
                .environment(authManager)
                .presentationDetents([.fraction(0.62)])
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
        .alert("Rename Reference", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField(renamingItem.map { defaultSlotPlaceholder(for: $0) } ?? "", text: $renameText)
                .autocorrectionDisabled()
            Button("Save") {
                guard let item = renamingItem else { return }
                let trimmed = String(renameText.trimmingCharacters(in: .whitespaces).prefix(40))
                Task { await applyRename(to: item, name: trimmed) }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) { renamingItem = nil }
        } message: {
            Text("Use [name] in prompts to reference this media.")
        }
        .sheet(item: $selectedItem) { item in
            GenerationDetailPagerView(
                items: generationManager.feedGenerations,
                currentId: item.id,
                isPresented: Binding(get: { selectedItem != nil }, set: { if !$0 { selectedItem = nil } })
            )
        }
        // Swipe-to-delete confirmation (Issue 4) — shared by every SwipeToDeleteRow. The row
        // stays revealed (isHeldOpen) while this is up — Messages pattern. Uses .alert (not
        // .confirmationDialog): a 2-button alert lays Cancel/Delete side-by-side in a single compact
        // centered box — wider + shorter than the action sheet's tall vertical button stack
        // (2026-07-13 request).
        .alert(
            confirmDeleteItem.map { $0.isImage ? "Delete this image?" : "Delete this video?" } ?? "Delete this video?",
            isPresented: Binding(
                get: { confirmDeleteItem != nil },
                set: { if !$0 { confirmDeleteItem = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmDeleteItem = nil }
            Button("Delete", role: .destructive) {
                if let item = confirmDeleteItem {
                    deletingItemIds.insert(item.id)
                    Task { await handleDelete(item: item) }
                }
                confirmDeleteItem = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        // Reference-upload delete confirmation — the @-mention list's swipe-to-delete and
        // long-press → Delete both route here. deleteLibraryItem already animates the removal and
        // detaches the reference from the current draft. Same compact .alert shape as above.
        .alert(
            confirmDeleteReference.map { ($0.isVideo ? "Delete this video?" : "Delete this image?") } ?? "Delete this reference?",
            isPresented: Binding(
                get: { confirmDeleteReference != nil },
                set: { if !$0 { confirmDeleteReference = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmDeleteReference = nil }
            Button("Delete", role: .destructive) {
                if let item = confirmDeleteReference {
                    Task { await deleteLibraryItem(item) }
                }
                confirmDeleteReference = nil
            }
        } message: {
            Text("This removes it from your references. This cannot be undone.")
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
                CircularCreditIndicator(fillRatio: creditManager.fillRatio, size: 32)
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
            if isAnyUploading {
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: accent))
                        .scaleEffect(0.6)
                    Text("Uploading…")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                // Always shows the cost, even with insufficient credits or a missing required
                // image — those become temporary tap-time errors (see showError in the submit
                // action) rather than a persistent label state.
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
        .accessibilityLabel("Estimated cost \(generationCost) credits")
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
                    // Scoped to just this button (not the whole ZStack): an .animation(value:)
                    // on the shared parent also reaches the placeholder Text inside
                    // promptBarContent, which used to need a `.transaction { $0.animation = nil }`
                    // escape hatch to avoid fading with this button. That escape hatch
                    // unconditionally stripped animation from EVERY transaction reaching the
                    // placeholder — including the composer's own keyboard-position spring — so
                    // the placeholder snapped instantly instead of riding the composer up/down
                    // with the keyboard. Scoping the fade here removes the need for that hatch.
                    .animation(.easeOut(duration: 0.15), value: promptText.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var clearPromptButton: some View {
        Button {
            clearPrompt()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textPrimary.opacity(0.85))
                .frame(width: 24, height: 24)
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
                            guard attachedReferences.count < maxReferences else {
                                showError("You can attach up to \(maxReferences) references.")
                                return
                            }
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
                            .offset(y: 3)
                    }
                    // The menu pops upward from this bottom-anchored button, and iOS renders
                    // upward-popping menus bottom-to-top by default — .fixed keeps declared
                    // order (Photos / Camera / Files) rendering top-to-bottom regardless.
                    .menuOrder(.fixed)
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
                // .top alignment with a single shared `promptFirstLineTopInset` padding wrapping
                // the whole ZStack (not ZStack-centering inside `max(44, promptTextHeight)`):
                // centering made the gap above line 1 depend on line count — it shrank toward 0
                // once wrapped text made the content height cross the 44pt floor, since there was
                // no more slack to center into. A constant top inset keeps line 1 at the same
                // offset regardless of how many lines follow. The inset MUST be a single padding
                // wrapping both the placeholder and the text view (not one `.padding` per child) —
                // two separately-applied paddings looked equivalent but didn't land identically:
                // the UITextView's caret rendered visibly higher than the placeholder text.
                // Wrapping VStack leaves the ZStack's own frame/padding untouched (placeholder/
                // caret positioning stays exactly as tuned above) and adds a separate, purely
                // decorative-turned-tappable spacer below it that stretches to match the row's
                // height (set by the taller paperclip/button columns). Taps landing there focus
                // the composer instead of falling through to the background's dismiss-tap — that
                // dead zone previously belonged to no view at all. Doesn't overlap the ZStack's
                // own bounds, so HighlightingTextView's native tap-to-place-caret is unaffected.
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if promptText.isEmpty {
                            Text("Describe a scene...")
                                .font(.body)
                                .foregroundStyle(theme.textTertiary)
                                .allowsHitTesting(false)
                                // No `.transaction { $0.animation = nil }` here (removed 2026-07-06):
                                // that used to be needed to opt this placeholder out of the
                                // clear-button's fade animation, but it unconditionally stripped
                                // animation from EVERY transaction reaching this view — including
                                // the composer's own keyboard-position spring — so the placeholder
                                // snapped instantly instead of moving with the composer on
                                // focus/dismiss. The fade animation is now scoped directly to
                                // clearPromptButton in `promptBar`, so this Text no longer needs an
                                // escape hatch and freely inherits the composer's real positioning
                                // animation.
                        }
                        HighlightingTextView(
                            text: $promptText,
                            selectedRange: $promptTextRange,
                            isFocused: Binding(get: { promptFocused }, set: { promptFocused = $0 }),
                            contentHeight: $promptTextHeight,
                            accentColor: UIColor(accent),
                            textColor: UIColor(theme.textPrimary),
                            tokenThumbnails: tokenThumbnails,
                            onTokenDeleted: { inner in dereferenceToken(inner) },
                            // Inline @-mention autocomplete: gray ghost suffix of the top suggestion
                            // drawn at the caret; Return commits it (instead of a newline). See
                            // mentionGhostSuffix / acceptTopMentionCompletion.
                            ghostText: mentionGhostSuffix,
                            onAcceptCompletion: acceptTopMentionCompletion
                        )
                    }
                    .padding(.top, promptFirstLineTopInset)
                    // Explicit content-driven height (restored 2026-07-07): promptTextHeight is
                    // the UITextView's content height already capped at its maxHeight by
                    // recalcHeight, so this floors at 44 and tops out at the cap — giving the box a
                    // STABLE bounded height so the UITextView scrolls internally past ~4 lines.
                    // Regression it fixes: today's edit dropped this frame in favor of
                    // sizeThatFits/.fixedSize sizing, which left promptTextHeight as dead state that
                    // still churned every layout pass (glitchy, wouldn't scroll). +inset so the
                    // 11pt top padding above isn't clipped off the last line. Keeps the .topLeading
                    // placeholder fix intact.
                    .frame(height: max(44, promptTextHeight + promptFirstLineTopInset), alignment: .top)
                    // leading 0 (was 4) moves the prompt text closer to the paperclip; trailing -8
                    // (was 15, then 8, then 5, then 2) pushes the wrap/cutoff further right so text gets more width.
                    .padding(.leading, 0)
                    .padding(.trailing, -8)
                    // Placeholder+caret vertical position: smaller top padding = higher (was 16→10→4).
                    // Bottom 4 (was 14) shrinks the gap between the last text line and the divider.
                    // See .planning/notes/keyboard-composer-architecture.md.
                    .padding(.top, 4)
                    .padding(.bottom, 4)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { promptFocused = true }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                // Submit + credit cost, stacked so the cost sits directly under the arrow.
                // spacing 4 (was 6): compensates the arrow button's +2pt frame growth below so
                // creditCostLabel's position is unchanged even though the button got bigger.
                VStack(alignment: .trailing, spacing: 4) {
                    Button {
                        promptFocused = false
                        guard creditManager.entitlementLevel != .none else {
                            showPaywall = true
                            return
                        }
                        // Temporary tap-time errors — no placeholder card is created and the
                        // composer (prompt/references) is left untouched because we return
                        // before dispatchGeneration() ever runs.
                        guard !hasInsufficientCredits else {
                            showError("Insufficient credits")
                            return
                        }
                        guard !missingRequiredImage else {
                            showError("Attach an image to use this model")
                            return
                        }
                        // A ref whose upload/backfill failed leaves its [ImageN] token in the prompt
                        // with no URL to back it — block submit rather than silently dropping it
                        // (Issue 4b: previously dispatchGeneration filtered these out unannounced).
                        guard !attachedReferences.contains(where: { !$0.isReady }) else {
                            showError("A reference didn't finish uploading — remove it or wait and try again.")
                            return
                        }
                        guard !isSubmitDisabled else { return }
                        Task { await dispatchGeneration() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.545, green: 0.427, blue: 0.839),
                                             Color(red: 0.357, green: 0.561, blue: 0.851)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .clipShape(Circle())
                            .opacity((isSubmitDisabled || hasInsufficientCredits || missingRequiredImage) ? 0.5 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitDisabled)
                    // Nudges the button down a couple px without moving creditCostLabel below it
                    // (offset is a render-time transform, doesn't consume VStack layout space).
                    .offset(y: 2)

                    creditCostLabel
                        .offset(y: 3)
                }
                .padding(.trailing, 10)
                .padding(.bottom, 4)
                // Bottom-anchored (not top) so the arrow+credits track the bottom of the row as
                // the text box grows across lines (up to its ~4-line max), landing next to the
                // divider instead of staying stranded near the top on a tall prompt.
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            Rectangle()
                .fill(theme.divider)
                .frame(height: 0.5)
                .padding(.horizontal, 12)
                // 1 (was 2) — tighter gap between the prompt text and the pills row.
                .padding(.vertical, 1)

            // Always-visible settings pill row — Options/Hide toggle removed (D-decision:
            // one always-visible horizontally-scrollable row, no collapse state).
            GenerationOptionsPanel(
                selectedMode: $selectedMode,
                selectedModel: $selectedModel,
                selectedDuration: $selectedDuration,
                selectedResolution: $selectedResolution,
                selectedAspectRatio: $selectedAspectRatio,
                audioEnabled: $audioEnabled,
                selectedImageResolution: $selectedImageResolution
            )
            .padding(.top, 2)
            .padding(.bottom, 6)
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
                referenceCard(ref, isTop: index == visible.count - 1)
                    .offset(x: CGFloat(index) * 3, y: 0)
                    .zIndex(Double(index))
            }
        }
        .frame(width: totalWidth, height: 52)
    }

    // Cards fan with only a 3pt offset, so the underlying thumbnails just peek out at the left
    // edge. Only the frontmost (top) card shows its X + name label — otherwise every stacked
    // card renders its own full-width label at the same spot, piling into illegible overlapping
    // text (e.g. "Image 1"/"Image 2" mashing into "Iimage 12"). The label space is still reserved
    // (opacity, not removal) on the hidden cards so all thumbnails stay vertically aligned.
    @ViewBuilder
    private func referenceCard(_ ref: AttachedReference, isTop: Bool) -> some View {
        let label = attachedReferenceLabel(ref)
        VStack(spacing: 2) {
            // X sits on the thumbnail only — keeping it in an outer ZStack that also wrapped
            // the name label pinned it to the full card height and made the label overlap the
            // media.
            ZStack(alignment: .topTrailing) {
                Group {
                    if ref.isUploading, let thumb = ref.thumbnail {
                        // Show the already-available thumbnail immediately with a subtle spinner
                        // overlay, rather than hiding it behind a full blank spinner while the
                        // upload is still in flight.
                        Color.clear
                            .overlay {
                                Image(uiImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .allowsHitTesting(false)
                            }
                            .clipped()
                            .contentShape(Rectangle())
                            .overlay {
                                ZStack {
                                    Color.black.opacity(0.25)
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.5)
                                }
                            }
                    } else if ref.isUploading {
                        // No thumbnail yet (e.g. a video still being prepared).
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

                if isTop {
                    Button { removeReference(ref) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    .offset(x: 4, y: -4)
                }
            }
            .frame(width: 40, height: 40)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .frame(width: 40)
                .opacity(isTop ? 1 : 0)
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
                return ref.isVideo ? "Video_\(videoCount)" : "Image_\(imageCount)"
            }
        }
        return ref.isVideo ? "Video" : "Image"
    }

    // MARK: - @-mention inline suggestion list
    // Pinned above the composer WITH THE KEYBOARD UP (see showReferencePanel's declaration note).
    // A compact vertical list — not the T8b bottom thumbnail grid — so it fits between the top of
    // the prompt box and the keyboard and reads naturally while the user keeps typing "@name" to
    // filter. Tapping a row commits the token via commitMention and closes the list; the keyboard
    // is never touched, so typing simply continues. Upload rows swipe left to delete (same
    // SwipeToDeleteRow as the history cards) and long-press for rename/delete; a footer advertises
    // both affordances.
    private var mentionSuggestionList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if mediaLibrary.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(theme.textSecondary)
                            Text("Loading…")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                        .padding()
                    } else {
                        ForEach(mentionSuggestions, id: \.id) { candidate in
                            VStack(spacing: 0) {
                                switch candidate {
                                case .upload(let item):
                                    // Swipe-left-to-delete, mirroring the generation cards but with
                                    // a tighter reveal for the compact row. Held open while its
                                    // confirmation alert is up (Messages pattern).
                                    SwipeToDeleteRow(
                                        onRequestDelete: { confirmDeleteReference = item },
                                        isHeldOpen: confirmDeleteReference?.id == item.id,
                                        cornerRadius: 10,
                                        trailingInset: 0,
                                        revealWidth: 96,
                                        threshold: 64
                                    ) {
                                        mentionRow(candidate)
                                    }
                                case .generation:
                                    mentionRow(candidate)
                                }
                                if candidate.id != mentionSuggestions.last?.id {
                                    Divider().overlay(theme.divider)
                                }
                            }
                        }
                    }
                }
            }
            // Cap at ~3 rows (each row = 40pt thumbnail + 9pt×2 vertical padding ≈ 58pt), so the
            // list shows exactly 3 assets before scrolling — was 220 (~3.7 rows). (2026-07-13)
            .frame(maxHeight: 176)

            // Discoverability: statically advertise the row gestures so users know they exist
            // without having to find them by accident (2026-07-13 request). Hidden while loading /
            // empty since there's nothing to act on.
            if !mediaLibrary.isLoading, !mentionSuggestions.isEmpty {
                Divider().overlay(theme.divider)
                Text("Swipe to delete · Long press to rename")
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
        }
        .background(theme.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 14)
    }

    /// One tappable suggestion row (thumbnail + label). Opaque background so a leftward swipe
    /// reveals the red delete pane only in the vacated strip, not through the row itself.
    private func mentionRow(_ candidate: MentionCandidate) -> some View {
        Button {
            // commitMention replaces the "@query" run with the token, so the trigger regex stops
            // matching and onChange(of: promptText) would hide the list on its own — we close it
            // here immediately for snappiness.
            commitMention(candidate)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
        } label: {
            HStack(spacing: 10) {
                libraryItemThumbnail(cacheKey: candidate.id, isVideo: candidate.isVideo, url: candidate.thumbnailURL, size: 40)
                Text(candidate.displayLabel(in: mediaLibrary.items))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(candidate.hasCustomName ? theme.textPrimary : theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(theme.elevatedBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            switch candidate {
            case .upload(let item):
                Button("Rename") {
                    renamingItem = item
                    renameText = item.displayName ?? ""
                    mentionQuery = nil
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
                }
                Button("Delete", role: .destructive) {
                    confirmDeleteReference = item
                }
            case .generation(let item):
                Button("Name as reference") {
                    mentionQuery = nil
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showReferencePanel = false }
                    handleNameAsReference(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func libraryItemThumbnail(cacheKey: String, isVideo: Bool, url: String?, size: CGFloat = 64) -> some View {
        let radius = size * 0.125
        ZStack {
            if isVideo {
                // Video reference uploads have no stored preview frame (see MentionCandidate.
                // thumbnailURL — nil for .upload), so they keep the generic placeholder. A
                // generation's completedMediaUrl IS playable media we already have, so extract
                // an actual frame from it instead of showing the same placeholder for every
                // video candidate (fixes "Last Generation" always rendering as a plain icon).
                if let urlStr = url, let videoURL = URL(string: urlStr) {
                    CachedVideoFrameThumbnail(cacheKey: cacheKey + "-lib", videoURL: videoURL)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.608, green: 0.490, blue: 0.906),
                                 Color(red: 0.416, green: 0.561, blue: 0.878)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "video.fill")
                        .font(.system(size: size * 0.31, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
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
            if lib.id == item.id { return item.isVideo ? "Video_\(count)" : "Image_\(count)" }
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
        showReferencePanel = false
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

    /// Snaps a measured pixel size to the closest of the app's 5 supported aspect ratios (matches
    /// the backend's VALID_VIDEO_ASPECT_RATIOS and ImageResolution's cases exactly) — used when we
    /// only have a raw attachment's pixel dimensions, not a known/declared ratio.
    private func closestAspectRatio(for size: CGSize) -> String {
        guard size.width > 0, size.height > 0 else { return selectedAspectRatio }
        let measured = size.width / size.height
        let candidates: [(String, CGFloat)] = [
            ("16:9", 16.0 / 9.0), ("9:16", 9.0 / 16.0), ("1:1", 1.0),
            ("4:3", 4.0 / 3.0), ("3:4", 3.0 / 4.0),
        ]
        return candidates.min { abs($0.1 - measured) < abs($1.1 - measured) }!.0
    }

    /// Applies a resolved aspect ratio to both mode's state so it carries over if the user
    /// switches between AI Video / AI Image afterward. Callers only invoke this for the FIRST
    /// reference attached in a fresh draft — later references (or a manual change the user made
    /// in between) are never overridden.
    private func applyAspectRatioFromReference(_ ratio: String) {
        selectedAspectRatio = ratio
        selectedImageResolution = ImageResolution.allCases.first { $0.rawValue == ratio } ?? selectedImageResolution
    }

    /// Uploads a raw attachment and adds its reference card + prompt token. Shared by the
    /// photo library, camera, and file import sources behind the paperclip menu.
    private func handleAttachedData(_ data: Data, isVideo: Bool) async {
        // Central cap enforcement — covers camera + file-import sources too, not just the picker.
        guard attachedReferences.count < maxReferences else {
            showError("You can attach up to \(maxReferences) references.")
            return
        }
        // Captured before any append below — only the first reference in a fresh draft should
        // set the generation's aspect ratio (see applyAspectRatioFromReference).
        let isFirstReference = attachedReferences.isEmpty
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

            // The extracted poster frame is already correctly oriented (extractThumbnail sets
            // appliesPreferredTrackTransform), so its .size is the video's true display aspect —
            // no separate natural-size probe needed.
            if isFirstReference, let size = thumbnail?.size {
                applyAspectRatioFromReference(closestAspectRatio(for: size))
            }

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
            if isFirstReference, let size = thumbnail?.size {
                applyAspectRatioFromReference(closestAspectRatio(for: size))
            }
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

    /// Rebuilds the tokenThumbnails dict the composer's inline pills read from (Issue 6). Keys
    /// mirror compositionToken's inner text (lowercased, no brackets) so a pill for "[Image1]"
    /// looks up "image1" and one for "[bob]" looks up "bob". Thumbnails already in memory
    /// populate synchronously; anything else is fetched async and merged in once ready.
    private func rebuildTokenThumbnails() {
        var result: [String: UIImage] = [:]
        var pendingImages: [(inner: String, cacheKey: String, url: URL, refId: String)] = []
        var pendingVideos: [(inner: String, cacheKey: String, url: URL, refId: String)] = []
        var imageCount = 0
        var videoCount = 0
        for ref in attachedReferences {
            if ref.isVideo { videoCount += 1 } else { imageCount += 1 }
            let token = ref.compositionToken(imageSlot: imageCount, videoSlot: videoCount)
            let inner = String(token.dropFirst().dropLast()).lowercased()
            let cacheKey = (ref.uploadId ?? ref.id) + "-tokenpill"
            if let thumb = ref.thumbnail {
                result[inner] = thumb
            } else if ref.isVideo, !ref.url.isEmpty, let url = URL(string: ref.url) {
                pendingVideos.append((inner, cacheKey, url, ref.id))
            } else if let url = URL(string: ref.thumbnailURL ?? ref.url) {
                pendingImages.append((inner, cacheKey, url, ref.id))
            }
        }
        tokenThumbnails = result
        // Generation guard: a slow fetch from a previous rebuild can land after a newer rebuild
        // and insert a stale image under a reused inner-text key (e.g. remix restores "bob" then
        // a different image is attached under the same token before the old fetch resolves).
        tokenThumbnailsGeneration += 1
        let gen = tokenThumbnailsGeneration
        for item in pendingImages {
            Task {
                if let cached = await ThumbnailCache.shared.image(for: item.cacheKey) {
                    guard gen == tokenThumbnailsGeneration else { return }
                    applyFetchedTokenThumbnail(cached, inner: item.inner, refId: item.refId, cacheKey: item.cacheKey)
                    return
                }
                guard let (data, _) = try? await URLSession.shared.data(from: item.url),
                      let downloaded = UIImage(data: data) else { return }
                let thumb = downloaded.preparingThumbnail(of: CGSize(width: 80, height: 80)) ?? downloaded
                guard gen == tokenThumbnailsGeneration else { return }
                applyFetchedTokenThumbnail(thumb, inner: item.inner, refId: item.refId, cacheKey: item.cacheKey)
            }
        }
        for item in pendingVideos {
            Task {
                if let cached = await ThumbnailCache.shared.image(for: item.cacheKey) {
                    guard gen == tokenThumbnailsGeneration else { return }
                    applyFetchedTokenThumbnail(cached, inner: item.inner, refId: item.refId, cacheKey: item.cacheKey)
                    return
                }
                guard let extracted = await MediaPrepService.shared.thumbnailFromVideo(at: item.url) else { return }
                let thumb = extracted.preparingThumbnail(of: CGSize(width: 80, height: 80)) ?? extracted
                guard gen == tokenThumbnailsGeneration else { return }
                applyFetchedTokenThumbnail(thumb, inner: item.inner, refId: item.refId, cacheKey: item.cacheKey)
            }
        }
    }

    /// Merges a fetched thumbnail into the inline-pill dict and backfills the paperclip chip
    /// when the reference row is still showing a generic video placeholder.
    private func applyFetchedTokenThumbnail(_ thumb: UIImage, inner: String, refId: String, cacheKey: String) {
        ThumbnailCache.shared[cacheKey] = thumb
        tokenThumbnails[inner] = thumb
        if let idx = attachedReferences.firstIndex(where: { $0.id == refId }),
           attachedReferences[idx].thumbnail == nil {
            attachedReferences[idx].thumbnail = thumb
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

        // Captured before the composer is cleared, so a failed dispatch can restore them.
        let capturedPrompt = promptText
        let capturedReferences = attachedReferences
        let isImageMode = selectedMode == "AI Image"
        let readyRefs = capturedReferences.filter { $0.isReady }
        let readyImageRefs = readyRefs.filter { !$0.isVideo }
        let readyVideoRefs = readyRefs.filter { $0.isVideo }
        let refImages = readyImageRefs.map { $0.url }
        let refVideos = readyVideoRefs.map { $0.url }
        let refUploadIds = readyRefs.compactMap { $0.uploadId }
        // Aligned by index to refImages/refVideos — backend re-signs wherever an id is present,
        // preferring the upload row (freshest) over the source generation's own R2 key.
        let refImageUploadIds = readyImageRefs.map { $0.uploadId }
        let refVideoUploadIds = readyVideoRefs.map { $0.uploadId }
        let refImageGenerationIds = readyImageRefs.map { $0.uploadId == nil ? $0.sourceGenerationId : nil }
        let refVideoGenerationIds = readyVideoRefs.map { $0.uploadId == nil ? $0.sourceGenerationId : nil }
        let submitPrompt = resolvedPromptForSubmit()

        let body: GenerationRequestBody
        if isImageMode {
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
                referenceUploadIds: refUploadIds.isEmpty ? nil : refUploadIds,
                referenceImageUploadIds: refImageUploadIds.isEmpty ? nil : refImageUploadIds,
                referenceVideoUploadIds: refVideoUploadIds.isEmpty ? nil : refVideoUploadIds,
                referenceImageGenerationIds: refImageGenerationIds.isEmpty ? nil : refImageGenerationIds,
                referenceVideoGenerationIds: refVideoGenerationIds.isEmpty ? nil : refVideoGenerationIds
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
                referenceUploadIds: refUploadIds.isEmpty ? nil : refUploadIds,
                referenceImageUploadIds: refImageUploadIds.isEmpty ? nil : refImageUploadIds,
                referenceVideoUploadIds: refVideoUploadIds.isEmpty ? nil : refVideoUploadIds,
                referenceImageGenerationIds: refImageGenerationIds.isEmpty ? nil : refImageGenerationIds,
                referenceVideoGenerationIds: refVideoGenerationIds.isEmpty ? nil : refVideoGenerationIds
            )
        }

        // Optimistic UI: clear the composer and drop in a pending placeholder card before the
        // network round trip (moderation + credit deduction + DB insert + enqueue) resolves —
        // that trip used to leave the composer sitting untouched for ~3s with zero feedback.
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: selectedModel,
            mediaType: isImageMode ? .image : .video,
            prompt: submitPrompt.isEmpty ? nil : submitPrompt,
            params: GenerationParams(
                resolution: isImageMode ? nil : selectedResolution,
                duration: isImageMode ? nil : selectedDuration,
                aspectRatio: isImageMode ? selectedImageResolution.rawValue : selectedAspectRatio,
                audioEnabled: isImageMode ? nil : audioEnabled,
                hasReference: readyRefs.isEmpty ? nil : true,
                width: nil,
                height: nil
            ),
            costCredits: 0,
            referenceUrls: readyRefs.isEmpty ? nil : readyRefs.map { GenerationReference(url: $0.url, isVideo: $0.isVideo) },
            createdAt: Date()
        )
        promptText = ""
        attachedReferences = []
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            let submitted = try await APIClient.shared.submitGeneration(body: body)

            // Promote the optimistic placeholder to the real server id rather than removing it and
            // relying on the next poll re-fetching the row — an immediate re-fetch can miss the
            // just-created row (read-replica lag), leaving the feed empty. The pending card now
            // carries the real id, so polling updates it in place through to completion.
            generationManager.promoteLocalPlaceholder(localId: placeholderId, toRealId: submitted.generationId)
            // forceRefresh: kick the polling loop immediately so status transitions are picked up.
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()

        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            promptText = capturedPrompt
            attachedReferences = capturedReferences
            if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                showError("Prompt may not adhere to our community guidelines. Please try again.")
            } else if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                // Balance went stale between the client-side pre-flight check and dispatch
                // (e.g. a concurrent generation on another device) — resync so the composer's
                // insufficient-credits check reflects the real server-confirmed balance.
                showError("Insufficient credits")
                await creditManager.fetchBalance()
            } else {
                print("[GenerateView] submit rejected: \(apiError)")
                showError("An error has occurred. Please try again.")
            }
            await generationManager.refresh()
        } catch {
            print("[GenerateView] dispatch error: \(error)")
            generationManager.removeLocalPlaceholder(id: placeholderId)
            promptText = capturedPrompt
            attachedReferences = capturedReferences
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
        applyRemix(from: item)
    }

    /// Restores a generation's prompt, model/mode/params, and attached references into the
    /// composer. Shared by the card's Remix button and the detail-sheet Remix/Regen path (via
    /// pendingRemix) — the latter used to hand-roll a partial restore that never touched
    /// attachedReferences, silently dropping the generation's references.
    private func applyRemix(from item: GenerationItem) {
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
    // without touching the current prompt or other settings. Unlike Remix (which
    // reloads the original prompt/settings/references for editing), this lets
    // the user build on the *result* of a past generation. The one setting this DOES
    // touch: if this is the first reference in an otherwise-fresh draft, the new
    // generation's aspect ratio defaults to match it exactly (item.params.aspectRatio is
    // already one of the 5 supported values — no measuring/snapping needed, unlike a raw
    // picked attachment in handleAttachedData). Still freely changeable afterward.
    private func handleReference(item: GenerationItem) {
        attachReference(from: item)
    }

    private func attachReference(from item: GenerationItem) {
        guard item.status == .completed else { return }
        let urlString = item.isImage ? item.completedMediaUrl : item.videoUrl
        guard let urlString, !urlString.isEmpty else { return }
        let isVideo = !item.isImage
        let isFirstReference = attachedReferences.isEmpty
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
        // FIX (2026-07-12): item.params.aspectRatio is NOT reliable for every preset. Presets
        // whose registry sheet.aspect_label reads "Matches your photo/video" (e.g. Animate Old
        // Photo) never send an aspect_ratio to the backend, which silently defaults the stored
        // value to 16:9 (video) / 1:1 (image) regardless of the source media's real orientation
        // (generations.ts: `aspect_ratio ?? '16:9'` / `imageAspectRatio ?? '1:1'`) — trusting it
        // here would snap the composer to a known-wrong ratio. Only trust the stored value for
        // plain composer generations and presets with a genuinely fixed/selected aspect; skip
        // (leave whatever's already selected) for the data-dependent ones rather than apply a
        // wrong one — there's no reliable pixel-measurable source at this point (the item's own
        // completed media would need a full download+decode to measure, unlike a fresh
        // attachment in handleAttachedData which already has the bytes in hand).
        let sourceAspectIsDataDependent: Bool = {
            guard let presetId = item.params.presetId else { return false }
            let label = presetRegistry.presets.first { $0.presetId == presetId }?.sheet?.aspectLabel ?? ""
            return label.localizedCaseInsensitiveContains("matches")
        }()
        if isFirstReference, !sourceAspectIsDataDependent, let ratio = item.params.aspectRatio {
            applyAspectRatioFromReference(ratio)
        }
        promptFocused = true
    }

    // Long-press "Name as reference" — promotes this generation's output into the permanent
    // reference library (server copies the R2 object so it's independently owned and never
    // expires), unlike the "Reference" button which only attaches a short-lived presigned URL
    // to the current draft. The actual save + chip backfill are handled by
    // NameAsReferenceAlertModifier (hosted in MainTabView) and the .onChange(of:
    // mediaLibrary.lastSavedReference) above, since this trigger can also fire from Library,
    // the detail sheet, and the fullscreen image viewer — not just this screen.
    private func handleNameAsReference(item: GenerationItem) {
        guard item.status == .completed else { return }
        generationManager.pendingNameAsReference = item
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
                hasVideoReference: hasVideoRef,
                audioEnabled: item.params.audioEnabled ?? true
            )
        }
        guard creditManager.creditsBalance >= cost else { return }
        await dispatchRegenerate(item: item)
    }

    private func dispatchRegenerate(item: GenerationItem) async {
        guard let prompt = item.prompt else { return }
        // FIX (2026-07-12): used to send only item.referenceUrls?.first — dropped every reference
        // past the first while still billing/behaving as if the full set was used. Send all of them,
        // split by type, same as dispatchGeneration()'s attachedReferences split.
        let refImages = item.referenceUrls?.filter { !$0.isVideo }.map { $0.url }
        let refVideos = item.referenceUrls?.filter { $0.isVideo }.map { $0.url }
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
            referenceImages: (refImages?.isEmpty ?? true) ? nil : refImages,
            referenceVideos: (refVideos?.isEmpty ?? true) ? nil : refVideos,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: nil,
            referenceVideoGenerationIds: nil
        )

        // FIX (2026-07-12): this used to have no optimistic placeholder and swallow every error
        // silently (print-only) — a failed or slow regenerate gave the user nothing to look at.
        // Mirrors dispatchGeneration()'s placeholder/promote/error pattern, but deliberately does
        // NOT touch promptText/attachedReferences — Regenerate never edits the composer's own
        // draft, unlike Remix (applyRemix).
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: item.model,
            mediaType: item.isImage ? .image : .video,
            prompt: prompt,
            params: item.params,
            costCredits: 0,
            referenceUrls: item.referenceUrls,
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            let submitted = try await APIClient.shared.submitGeneration(body: body)
            generationManager.promoteLocalPlaceholder(localId: placeholderId, toRealId: submitted.generationId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                showError("Insufficient credits")
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                showError("Prompt may not adhere to our community guidelines. Please try again.")
            } else {
                print("[GenerateView] regenerate rejected: \(apiError)")
                showError("An error has occurred. Please try again.")
            }
        } catch {
            print("[GenerateView] regenerate error: \(error)")
            generationManager.removeLocalPlaceholder(id: placeholderId)
            showError("An error has occurred. Please try again.")
        }
    }

    private func handleDelete(item: GenerationItem) async {
        do {
            try await APIClient.shared.deleteGeneration(id: item.id)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                generationManager.removeGeneration(id: item.id)
            }
        } catch {
            // A failed delete used to fail completely silently — the row just sprang back
            // closed with zero explanation, which reads as "nothing happened" or "it's stuck"
            // if the user doesn't notice the closing animation. Surface it like every other
            // network failure in this view (showError banner).
            print("[GenerateView] delete error: \(error)")
            showError("Couldn't delete — check your connection and try again.")
        }
        deletingItemIds.remove(item.id)
    }

    private func scrollToNewest(proxy: ScrollViewProxy) {
        guard let id = generationManager.feedGenerations.first?.id else { return }
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .bottom) }
    }

    // Loads the next (older) page and re-anchors the scroll position on the item that was
    // previously the oldest loaded one, so the newly-inserted older cards appear above it
    // instead of the view jumping.
    private func loadOlderHistory(proxy: ScrollViewProxy) async {
        guard !isLoadingOlderHistory, generationManager.nextCursor != nil else { return }
        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }
        let anchorID = generationManager.feedGenerations.last?.id
        await generationManager.loadNextPage()
        if let anchorID {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

// MARK: - SwipeToDeleteRow

/// Standard iOS drag-to-delete for a plain VStack-in-ScrollView (no free .swipeActions here).
/// Nothing is rendered at rest — a red trash pane grows behind the card's trailing edge only
/// while the finger drags left, with a haptic tick when the drag crosses the delete threshold.
/// Releasing past the threshold asks for confirmation (the card springs back while the alert
/// shows); confirming slides the card off-screen via the row transition at the call site.
/// There is deliberately no persistent "open" state: rows are stateless at rest, so a stuck
/// reveal is impossible.
private struct SwipeToDeleteRow<Content: View>: View {
    var onRequestDelete: () -> Void
    var isHeldOpen: Bool = false
    // Styling knobs so the same swipe interaction fits both the large generation cards (defaults)
    // and the compact @-mention reference rows (smaller reveal, tighter corner, no trailing inset).
    var cornerRadius: CGFloat = 16
    var trailingInset: CGFloat = 16
    var revealWidth: CGFloat = 130
    var threshold: CGFloat = 90
    @ViewBuilder var content: () -> Content

    // ⚠️ Fast-flick-from-rest fix (2026-07-06): the swipe is driven by a UIKit
    // UIPanGestureRecognizer (HorizontalSwipeToDeletePan below), NOT a SwiftUI DragGesture.
    // Do not convert this back to a SwiftUI gesture.
    //
    // Why: a SwiftUI DragGesture attached to CONTENT INSIDE the ScrollView competes with the
    // ScrollView's own pan for the touch. On iOS 18, a fast flick from rest covers the drag's
    // minimumDistance within the first touch sample or two, so the row's drag recognized
    // BEFORE the scroll pan could claim — the drag then did nothing visually (vertical
    // direction lock) and the flick was completely eaten: no scroll, no reveal. Slow drags
    // were unaffected (the scroll pan claims at ~10pt and wins that race). Bisect-confirmed
    // on device: raising minimumDistance 20 -> 30 did NOT fix it; fully disabling the gesture
    // made the feed perfectly smooth. The scroll-attached gestures elsewhere (e.g.
    // GenerationManager.isInteracting buffering, min 20) only observe and never compete —
    // they are a different, safe case.
    //
    // The UIKit pan is gated in gestureRecognizerShouldBegin to horizontal-dominant leftward
    // velocity, so for any vertical movement it FAILS instantly and never enters the race —
    // this is how UIKit swipe-rows (Mail/Messages) coexist with their table's scroll natively.
    // See .planning/notes/2026-07-06-generate-fast-swipe-investigation.md.
    @State private var dragWidth: CGFloat = 0

    private var deleteThreshold: CGFloat { threshold }   // release past this = ask to delete
    private var maxReveal: CGFloat { revealWidth }

    // Leftward only, rubber-banding past maxReveal instead of tracking the finger 1:1.
    // While a confirmation is up for this row (isHeldOpen), stay parked at full reveal
    // instead of springing home (Messages pattern).
    private var offset: CGFloat {
        if isHeldOpen && dragWidth == 0 { return -maxReveal }
        guard dragWidth < 0 else { return 0 }
        if dragWidth < -maxReveal { return -maxReveal + (dragWidth + maxReveal) * 0.25 }
        return dragWidth
    }

    private var isPastThreshold: Bool { offset <= -deleteThreshold }

    var body: some View {
        content()
            .offset(x: offset)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHeldOpen)
            .background(alignment: .trailing) {
                if offset < 0 {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.red.opacity(isPastThreshold ? 1.0 : 0.85))
                        .overlay {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.white)
                                .scaleEffect(isPastThreshold ? 1.2 : 1.0)
                                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPastThreshold)
                                .opacity(min(1, -offset / 60))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .frame(width: -offset)
                        // Aligns the pane with the content face (GenerationCardView has its own 16pt
                        // inset; the flat mention rows pass 0).
                        .padding(.trailing, trailingInset)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: isPastThreshold) { _, crossed in crossed }
            .gesture(
                HorizontalSwipeToDeletePan(
                    onChanged: { translationX in
                        dragWidth = min(translationX, 0)
                    },
                    onEnded: { translationX in
                        if translationX <= -deleteThreshold {
                            onRequestDelete()
                        }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragWidth = 0
                        }
                    }
                )
            )
    }
}

/// UIKit-backed leftward swipe recognizer for SwipeToDeleteRow. Exists because a SwiftUI
/// DragGesture on scroll content eats fast flicks from rest on iOS 18 (see SwipeToDeleteRow's
/// header comment — bisect-confirmed on device 2026-07-06). The pan begins ONLY when the
/// initial velocity is horizontal-dominant and leftward; for anything else (i.e. every scroll
/// gesture) it fails instantly in gestureRecognizerShouldBegin, so it never competes with the
/// ScrollView's pan for the touch — native UIKit swipe-row behavior.
private struct HorizontalSwipeToDeletePan: UIGestureRecognizerRepresentable {
    var onChanged: (CGFloat) -> Void
    /// Called with the final x translation on a completed pan, and with 0 on cancel/failure
    /// (so the row always springs home).
    var onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        switch recognizer.state {
        case .changed:
            onChanged(recognizer.translation(in: view).x)
        case .ended:
            onEnded(recognizer.translation(in: view).x)
        case .cancelled, .failed:
            onEnded(0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // The direction gate — consulted once, when the pan would begin (~10pt of movement,
        // when velocity is meaningful). Vertical or rightward movement -> instant failure,
        // so scroll flicks never even see this recognizer in their arbitration.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let v = pan.velocity(in: view)
            return abs(v.x) > abs(v.y) && v.x < 0
        }

        // Never blocks other recognizers (scroll pan, context-menu long-press, taps).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
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
        // Unlike upload items (no stored preview frame for videos), a generation's
        // completedMediaUrl is playable media we already have — image or video — so it always
        // has something to render a real thumbnail from (see libraryItemThumbnail's video
        // branch, which extracts a frame when a URL is present).
        case .generation(let item): return item.completedMediaUrl
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
                if lib.id == item.id { return item.isVideo ? "Video_\(count)" : "Image_\(count)" }
            }
            return item.isVideo ? "Video" : "Image"
        case .generation:
            return "Last Generation"
        }
    }
}

// MARK: - CachedThumbnailImage

/// AsyncImage replacement that caches by a caller-supplied stable key instead of the URL —
/// presigned URLs rotate on every fetch, which defeats AsyncImage's built-in (URL-keyed, and
/// otherwise nonexistent beyond in-flight dedup) caching for the same underlying asset.
/// Downscales to a small thumbnail size before caching (these are always shown at ≤64pt).
/// Internal (not private) — also used by GenerationCardView's mini reference thumbnails.
struct CachedThumbnailImage: View {
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

// MARK: - CachedVideoFrameThumbnail

/// Poster-frame counterpart to `CachedThumbnailImage`, for mention candidates whose media is a
/// video (e.g. the "Last Generation" synthetic entry) rather than a stored image URL. Extracts
/// a frame directly from the video via `MediaPrepService` (works for both remote and local
/// URLs) instead of downloading + decoding the whole clip. Internal (not private) — also used by
/// GenerationPickerSheet's video cells.
struct CachedVideoFrameThumbnail: View {
    let cacheKey: String
    let videoURL: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
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
            guard let extracted = await MediaPrepService.shared.thumbnailFromVideo(at: videoURL) else { return }
            let thumb = extracted.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? extracted
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
