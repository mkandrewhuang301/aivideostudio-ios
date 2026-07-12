// PresetInputSheet.swift
// Fantasia
// Schema-driven preset input modal (D-10). Renders a Preset's `input_schema` — N media slots,
// an optional free-text field, an optional style grid — plus a live credit-cost label and a
// Generate button. Presented as a `.fullScreenCover`/full sheet from HomeView's onSelectPreset
// closure (wired outside this plan) and, later, from a preset-badged feed card's Remix action
// (Plan 08), prefilled via `prefillSlots`.
//
// Preset Sheet Redesign: Higgsfield-style, iPhone-native layout — full-bleed cover loop on top,
// category eyebrow + bold title + server-driven description, adaptive upload area(s) (one large
// card for single-slot presets, two side-by-side labeled cards for two-slot presets), the
// existing style grid + optional text field restyled to match, an aspect-ratio control (selectable
// chips when the registry declares `sheet.aspect_ratios`, else a fixed caption row), and a sticky
// Generate bar with cost rendered inline next to a sparkle icon. All slot media handling (Menu,
// thumbnails, video-duration badge, 30s trim-confirm) is UNCHANGED — only its container styling
// was reworked to fit the new adaptive layout.
//
// CRITICAL (CLAUDE.md keyboard/composer freeze): this is a brand-new, standalone modal. It does
// NOT import or modify GenerateView or any of its frozen text-input/keyboard-avoidance
// internals (its custom highlighting text view, its keyboard-height reader, or its bottom
// inset layout). The optional text field below is a plain SwiftUI TextField. Slot pickers
// reuse the same three input sources as the composer's paperclip menu
// (PhotosPicker / CameraPicker / .fileImporter, D-19) and the same multipart upload endpoint
// (APIClient.uploadReferenceMedia), but every helper here is a fresh, local implementation
// (PresetMediaPrep below) rather than an edit to GenerateView.swift or MediaPrepService.swift —
// this plan's touched-file list is limited to PresetInputSheet.swift + APIClient.swift.
//
// D-11: the server-side expanded template prompt is never constructed or displayed here — the
// client sends only `preset_id` + `preset_input_upload_ids`; POST /api/generations expands the
// real prompt server-side (presetResolver middleware, backend-owned).

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

// Shared purple accent used across the app's primary CTAs (GenerationCardView, CreditStoreView,
// PresetTileView badges) — kept as a local literal here rather than importing a shared constant,
// consistent with how the rest of this file already inlines it.
private let presetAccent = Color(red: 0.545, green: 0.427, blue: 0.839)

struct PresetInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var theme
    @Environment(GenerationManager.self) private var generationManager
    @Environment(CreditManager.self) private var creditManager
    @Environment(RatesManager.self) private var ratesManager

    let preset: Preset

    @State private var slotInputs: [PresetSlotInput?]
    @State private var text: String = ""
    @State private var selectedStyleId: String?
    // Client-side only, purely organizational — never sent to the server, no auto-detection
    // from the uploaded photo (deliberate: see 2026-07-07 notes/
    // hairstyle-preset-style-images-gender-filter.md). Defaults to showing every style.
    @State private var styleGenderFilter: PresetStyleGenderTag?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    // Likeness consent for the upload-driven face presets (Motion Transfer / AI Influencer). These
    // animate an uploaded face, so we require the user to affirm they have the rights to it before
    // submitting — pairs with the server-side celebrity-likeness block (celebrityCheckMiddleware).
    @State private var consentAccepted = false
    // Aspect-ratio chip selection (only rendered when `preset.sheet?.aspectRatios` is non-empty —
    // GPT-Image-2 presets). Seeded from `sheet.defaultAspectRatio` in `init`; nil for every other
    // preset, which instead shows a fixed, non-interactive aspect/length/resolution caption.
    @State private var selectedAspectRatio: String?

    // Slot-picker plumbing — one shared picker set, targeted at `activeSlotIndex`.
    @State private var activeSlotIndex: Int?
    // Source chooser as a nested .sheet (not a Menu, not a confirmationDialog) — a Menu lifts its
    // label into the menu presentation, dimming/hiding the rest of the sheet (the "Upload media"
    // box appeared to vanish, user-reported 2026-07-08); a confirmationDialog fixed that but is
    // the utilitarian system action sheet, not the smooth native bottom-sheet slide-up requested
    // (2026-07-08). A small-detent .sheet gives the rounded-card spring animation while still
    // dimming (not hiding) the sheet content behind it.
    // .seeAllGenerations added 2026-07-12 (todo: add-previous-generations-to-add-media-picker) —
    // the sheet also shows a horizontal strip of recent generations above these 3 rows; "See All"
    // at the end of that strip opens GenerationPickerSheet's full grid. A past generation tapped
    // DIRECTLY in the strip doesn't go through this enum at all — see pendingGenerationPick below.
    private enum MediaSource { case photos, camera, files, seeAllGenerations }
    @State private var showSourceSheet = false
    // Set when a source row (or the strip's "See All" tile) is tapped, consumed in the source
    // sheet's onDismiss — presenting the chosen picker only AFTER this sheet is fully dismissed
    // avoids two presentations racing off the same view (presenting the picker while this sheet
    // is still animating away conflicts).
    @State private var pendingSource: MediaSource?
    // Set when a strip thumbnail is tapped directly — same one-tap-and-dismiss behavior as the 3
    // existing rows (mirrors pendingSource's dismiss-then-act handoff, but carries a specific
    // generation instead of routing through a picker sheet).
    @State private var pendingGenerationPick: GenerationItem?
    @State private var showGenerationPicker = false
    @State private var showPhotosPicker = false
    @State private var showCameraPicker = false
    @State private var showFileImporter = false
    @State private var selectedPickerItem: PhotosPickerItem?

    // Motion Transfer 30s confirm-trim (D-16/D-17/D-18).
    @State private var pendingTrim: PendingVideoTrim?

    /// - Parameters:
    ///   - preset: the registry row to render.
    ///   - prefillSlots: existing upload ids/urls/thumbnails to preload per slot index — used by
    ///     Remix (Plan 08) to reopen this same sheet prefilled from a prior run's stored inputs,
    ///     never by routing through the composer.
    init(preset: Preset, prefillSlots: [PresetSlotInput?] = []) {
        self.preset = preset
        let count = preset.inputSchema?.slots.count ?? 0
        var initial = Array<PresetSlotInput?>(repeating: nil, count: count)
        for (index, value) in prefillSlots.enumerated() where index < count {
            initial[index] = value
        }
        _slotInputs = State(initialValue: initial)
        _selectedAspectRatio = State(initialValue: preset.sheet?.defaultAspectRatio)
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    coverSection

                    VStack(alignment: .leading, spacing: 26) {
                        headerSection
                        slotsSection
                        textSection
                        styleGridSection
                        aspectRatioSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 140)
                }
            }
            .ignoresSafeArea(edges: .top)

            HStack {
                Spacer()
                closeButton
            }
            .padding(.top, 8)
            .padding(.trailing, 18)

            VStack(spacing: 10) {
                Spacer()
                if requiresLikenessConsent {
                    consentRow
                }
                generateBar
            }
        }
        .task {
            // Warm the backend as soon as the sheet opens — overlaps a cold Railway boot with the
            // user reading the sheet/picking a style, so the first slot upload isn't racing a
            // sleeping instance (same pattern as CreditStoreView.swift's pingHealth on open).
            await APIClient.shared.pingHealth()
        }
        .task {
            // So the "Add media" sheet's recent-generations strip has real data the FIRST time a
            // user opens it (e.g. straight from Home, before ever visiting Library/Generate) —
            // refreshIfStale(), NOT startPolling(): the latter starts a recurring 3s fetch loop
            // whenever any job anywhere is active, which fights with GenerationPickerSheet's own
            // pagination (see that file's 2026-07-12 fix). This is a one-shot staleness check,
            // same pattern Library uses.
            await generationManager.refreshIfStale()
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $selectedPickerItem,
            matching: activeSlotKind == "video" ? .videos : .images
        )
        .onChange(of: selectedPickerItem) { _, newValue in
            Task { await handlePhotosPickerSelection(newValue) }
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            CameraPicker(
                allowsVideo: activeSlotKind == "video",
                onCapture: { data, isVideo in
                    showCameraPicker = false
                    if let index = activeSlotIndex {
                        Task { await handlePickedMedia(data, isVideo: isVideo, forSlot: index) }
                    }
                },
                onCancel: { showCameraPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: activeSlotKind == "video" ? [.movie] : [.image]
        ) { result in
            guard case .success(let url) = result, let index = activeSlotIndex else { return }
            Task { await handleImportedFile(url, forSlot: index) }
        }
        .sheet(isPresented: $showSourceSheet, onDismiss: {
            // Present the chosen picker (or resume the picked generation's slot-fill) only AFTER
            // the source sheet is fully dismissed — doing either while this sheet is still
            // up/animating conflicts (both are presentations off this same view).
            switch pendingSource {
            case .photos:            showPhotosPicker = true
            case .camera:            showCameraPicker = true
            case .files:             showFileImporter = true
            case .seeAllGenerations: showGenerationPicker = true
            case nil:                break
            }
            pendingSource = nil
            if let picked = pendingGenerationPick, let index = activeSlotIndex {
                Task { await handleGenerationPicked(picked, forSlot: index) }
            }
            pendingGenerationPick = nil
        }) {
            sourceChooserSheet
                // Bumped 2026-07-12 alongside the rows/strip growing larger (54/44pt badges,
                // 80pt strip thumbnails vs. the previous 46/36 and 64).
                .presentationDetents([.height(recentMatchingGenerations.isEmpty
                    ? (UIImagePickerController.isSourceTypeAvailable(.camera) ? 400 : 340)
                    : (UIImagePickerController.isSourceTypeAvailable(.camera) ? 520 : 460))])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.background)
        }
        .sheet(isPresented: $showGenerationPicker) {
            if let index = activeSlotIndex, let kind = activeSlotKind {
                GenerationPickerSheet(mediaKind: kind) { item in
                    Task { await handleGenerationPicked(item, forSlot: index) }
                }
            }
        }
        .confirmationDialog(
            "This video is longer than 30 seconds",
            isPresented: Binding(
                get: { pendingTrim != nil },
                set: { if !$0 { cancelTrim() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Use first 30 seconds") { confirmTrim() }
            Button("Cancel", role: .cancel) { cancelTrim() }
        } message: {
            Text("Only the first 30 seconds of this video will be used.")
        }
        .alert("Couldn't complete that", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Cover (full-bleed poster+loop, ~42% height, bottom scrim)

    private var coverSection: some View {
        // Cover box (screenHeight * 0.42, full width) is proportionally much wider/shorter
        // than the source 9:16 loops — a center crop (the old default) chopped the subject's
        // hair off entirely (user-reported 2026-07-08). focalTop 0 keeps the whole top
        // (hairline in frame); no zoom (full source width shown).
        //
        // No bottom gradient: the user wants a HARD LINE between the cover image and the
        // header/background below it (2026-07-08 "blur between the image and the effect, I want
        // a hard line"), not the old [.clear, .clear, theme.background] fade. The .clipped()
        // frame edge gives that clean cut.
        //
        // usesPool: false — this sheet shows the SAME preset.id's video as the Home grid tile
        // behind it (sheets don't tear down the presenting view). Sharing the pool's slot meant
        // dismissing this sheet released+paused the tile's player too, freezing it (2026-07-08,
        // see PresetLoopBackground's usesPool doc comment). Standalone playback here can't
        // disrupt Home no matter when it mounts/dismisses.
        PresetLoopBackground(preset: preset, zoom: 1.0, focalTop: 0.0, usesPool: false)
            .allowsHitTesting(false)
            .frame(height: UIScreen.main.bounds.height * 0.42)
            .clipped()
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            // 2026-07-12 (user-requested): visible circle grown 32x32 → 40x40, with a comfortably
            // larger 46x46 tap frame around it (was previously untouched — no separate hit-target
            // expansion existed at this commit).
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Header (category eyebrow + title + description)

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let eyebrow = categoryEyebrow {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(presetAccent)
            }
            Text(preset.title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            if let description = preset.sheet?.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Small-caps category label derived from the registry `section` — display-only, never
    /// sent to the server. Not registry-driven copy (unlike `sheet.*`) since it mirrors the
    /// fixed taxonomy already used to group Home's tile sections (09.1-CONTEXT.md D-02).
    private var categoryEyebrow: String? {
        switch preset.section {
        case "video_effects": return "VIDEO EFFECT"
        case "photo_effects": return "PHOTO EFFECT"
        case "avatar_center": return "AVATAR"
        case "shows_vlogs": return "SHOWS & VLOGS"
        case "hero": return "FEATURED"
        default: return nil
        }
    }

    // MARK: - Slots

    /// One large card for a single-slot preset; two side-by-side labeled cards for a two-slot
    /// preset (Motion Transfer, AI Influencer, Polaroid). All Menu/thumbnail/duration-badge/
    /// trim-confirm logic lives in `slotTile` below, UNCHANGED from before this redesign.
    private var slotsSection: some View {
        let slots = preset.inputSchema?.slots ?? []
        return Group {
            if slots.count == 1, let slot = slots.first {
                slotTile(index: 0, slot: slot, style: .large)
            } else if slots.count > 2 {
                // Clothes Swap (09.1-12): person is the dominant subject — one large card up top
                // — followed by its outfit reference(s) as a compact row/grid below (1 required +
                // up to N optional "Add reference" tiles). Generic over slot count, not hardcoded
                // to exactly 4, so a future preset with a different outfit-slot count still lays
                // out correctly.
                VStack(alignment: .leading, spacing: 14) {
                    if let personSlot = slots.first {
                        VStack(alignment: .leading, spacing: 8) {
                            slotLabel(personSlot, index: 0)
                            slotTile(index: 0, slot: personSlot, style: .large)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(Array(slots.enumerated().dropFirst()), id: \.offset) { index, slot in
                            VStack(alignment: .leading, spacing: 8) {
                                slotLabel(slot, index: index)
                                slotTile(index: index, slot: slot, style: .compact)
                            }
                        }
                    }
                }
            } else if slots.count == 2 {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                        VStack(alignment: .leading, spacing: 8) {
                            slotLabel(slot, index: index)
                            slotTile(index: index, slot: slot, style: .compact)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func slotLabel(_ slot: PresetSlot, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(slot.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            if slot.optional {
                Text("Optional")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            // Optional slots that already hold a value get a small clear ("x") affordance —
            // required slots are always re-tappable via the Menu instead, so no clear button.
            if slot.optional, index < slotInputs.count, slotInputs[index] != nil {
                Button {
                    slotInputs[index] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private enum SlotTileStyle {
        case large    // single-slot presets — big Higgsfield-style "Upload media" card
        case compact  // two-slot presets — half-width, side-by-side
    }

    private func slotTile(index: Int, slot: PresetSlot, style: SlotTileStyle) -> some View {
        let input = index < slotInputs.count ? slotInputs[index] : nil
        let height: CGFloat = style == .large ? 220 : 160
        let hasFilledMedia = input?.thumbnail != nil

        // ZStack, not a single Button: the 2026-07-12 remove (x) button below must be a SIBLING
        // to the main tap-to-reopen-picker Button, not nested inside its label — a Button nested
        // inside another Button's label has ambiguous/unreliable tap routing in SwiftUI. Two
        // independent Buttons at the same ZStack level avoids that entirely.
        return ZStack(alignment: .topTrailing) {
            Button {
                activeSlotIndex = index
                showSourceSheet = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(theme.surface)
                        .overlay(
                            // Dashed border for the empty state (Higgsfield "Upload media" look) —
                            // a filled thumbnail switches to a plain hairline border instead.
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(
                                    theme.surfaceBorder,
                                    style: input?.thumbnail == nil
                                        ? StrokeStyle(lineWidth: 1.25, dash: [6, 5])
                                        : StrokeStyle(lineWidth: 1)
                                )
                        )

                    if let thumbnail = input?.thumbnail {
                        // Constrain BOTH dimensions (not just height) before scaledToFill, so the
                        // image zoom-crops to fill the entire tile regardless of its aspect ratio —
                        // height-only constraint left the width intrinsic, leaving side gaps on
                        // portrait images / overflow past the rounded corners on landscape ones
                        // (user-reported 2026-07-08). Color.clear sets the layout frame; the image is
                        // an overlay so scaledToFill's oversized intrinsic size can't affect layout
                        // (documented scaledToFill hit-test landmine).
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .overlay {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .allowsHitTesting(false)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(alignment: .topTrailing) {
                                if slot.kind == "video", let duration = input?.durationSeconds {
                                    Text(durationLabel(duration))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.black.opacity(0.55), in: Capsule())
                                        .padding(8)
                                }
                            }
                    } else if input?.isUploading == true {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: theme.textPrimary))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: slot.kind == "video" ? "video.badge.plus" : "photo.badge.plus")
                                .font(.system(size: style == .large ? 30 : 24, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                            Text(style == .large ? "Upload media" : "Tap to add")
                                .font((style == .large ? Font.subheadline : .caption).weight(.medium))
                                .foregroundStyle(theme.textSecondary)
                            if style == .large {
                                Text("Tap to upload \(slot.label.lowercased())")
                                    .font(.caption)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: height)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PressableButtonStyle())
            // Hit-test containment pattern for scaledToFill media (documented project landmine).
            .contentShape(RoundedRectangle(cornerRadius: 16))

            // 2026-07-12 (user-requested): a small remove (x) on any FILLED slot, not just
            // optional ones — previously the only "clear" affordance was slotLabel's x, which
            // only ever showed for slot.optional (Faceswap's two slots are both required, so it
            // never appeared there at all — the exact preset the user was testing).
            if hasFilledMedia {
                Button {
                    slotInputs[index] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var activeSlotKind: String? {
        guard let activeSlotIndex,
              let slots = preset.inputSchema?.slots,
              activeSlotIndex < slots.count else { return nil }
        return slots[activeSlotIndex].kind
    }

    // 2026-07-12 (todo: add-previous-generations-to-add-media-picker) — completed generations
    // matching the active slot's media type, newest first, capped for the strip (tapping "See
    // All" opens GenerationPickerSheet's full paginated grid for anything beyond this). Cap
    // dropped 10 → 5 (2026-07-12, user-requested "fewer images before See All") — pairs with the
    // strip's thumbnails also growing, since fewer, larger thumbnails fit the same strip width.
    private var recentMatchingGenerations: [GenerationItem] {
        guard let kind = activeSlotKind else { return [] }
        return Array(generationManager.generations.filter { item in
            item.status == .completed
                && !(item.completedMediaUrl ?? "").isEmpty
                && (kind == "video" ? !item.isImage : item.isImage)
        }.prefix(5))
    }

    // MARK: - Source chooser (nested small-detent .sheet — native bottom-sheet slide-up)
    //
    // Redesigned 2026-07-12 per .planning/sketches/002-add-media-sheet (winner: Variant D) +
    // the add-previous-generations-to-add-media-picker todo:
    //  1. A horizontal strip of recent past generations (matching the slot's media type) sits
    //     ABOVE the 3 device-source rows — tapping a thumbnail selects it immediately (one tap,
    //     same as "Take Photo"), no separate screen for the common case. "See All" at the strip's
    //     end opens the full GenerationPickerSheet grid for anything further back.
    //  2. The 3 rows themselves adopt Variant D's treatment: single-hue (purple only) layered
    //     badges instead of 3 unrelated flat-tint colors, and one deliberate size/weight
    //     asymmetry (Photo Library — most-used — is a larger "primary" row with an elevated
    //     background; Take Photo/Choose File are smaller "secondary" rows, no elevated fill).
    //     This is what the sketch's research flagged as the fix for the "reads as AI-generated
    //     template" look a uniform 3-equal-rows list has.
    private var sourceChooserSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add media")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 20)

            recentGenerationsStrip

            VStack(spacing: 8) {
                sourceRow(
                    icon: "photo.on.rectangle",
                    label: "Photo Library",
                    subtitle: "Choose from your camera roll",
                    isPrimary: true
                ) {
                    pendingSource = .photos
                    showSourceSheet = false
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    sourceRow(
                        icon: "camera",
                        label: activeSlotKind == "video" ? "Record Video" : "Take Photo",
                        subtitle: "Use your camera right now",
                        isPrimary: false
                    ) {
                        pendingSource = .camera
                        showSourceSheet = false
                    }
                }
                sourceRow(
                    icon: "folder",
                    label: "Choose File",
                    subtitle: "Browse files on your device",
                    isPrimary: false
                ) {
                    pendingSource = .files
                    showSourceSheet = false
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var recentGenerationsStrip: some View {
        if !recentMatchingGenerations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentMatchingGenerations) { item in
                            stripThumbnail(item)
                        }
                        seeAllTile
                    }
                    .padding(.vertical, 1)   // keeps the selection/hairline border from clipping
                }
            }
        }
    }

    private func stripThumbnail(_ item: GenerationItem) -> some View {
        Button {
            // Same one-tap-and-dismiss behavior as the 3 rows below — no extra confirmation step.
            pendingGenerationPick = item
            showSourceSheet = false
        } label: {
            ZStack {
                if item.isImage, let urlString = item.completedMediaUrl, let url = URL(string: urlString) {
                    CachedThumbnailImage(cacheKey: "addmedia-strip-\(item.id)", url: url)
                } else if let urlString = item.videoUrl, let url = URL(string: urlString) {
                    CachedVideoFrameThumbnail(cacheKey: "addmedia-strip-\(item.id)", videoURL: url)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var seeAllTile: some View {
        Button {
            pendingSource = .seeAllGenerations
            showSourceSheet = false
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 20, weight: .semibold))
                Text("See All")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.textSecondary)
            .frame(width: 80, height: 80)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func sourceRow(
        icon: String, label: String, subtitle: String, isPrimary: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                sourceBadge(icon: icon, isPrimary: isPrimary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(isPrimary ? .system(size: 18, weight: .bold) : .system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }
            .padding(.horizontal, isPrimary ? 18 : 16)
            .padding(.vertical, isPrimary ? 18 : 15)
            .background {
                if isPrimary {
                    RoundedRectangle(cornerRadius: 16).fill(theme.surfaceStrong)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // 2026-07-12 (user-requested): moved away from the single-hue purple "hierarchical" badge
    // (sketch Variant D's original treatment) back to distinct, recognizable colors per source —
    // user's own words: "SVGs instead of these generic purple icons." True SVG/vector app-icon
    // assets aren't something to embed here (Apple's real Photos/Camera/Files icons are their own
    // trademarked artwork, not available to bundle) — this instead gives each row its own
    // deliberate, distinct system color evoking the matching real app (blue ~ Photos, orange ~
    // Camera, green ~ Files), which is what actually reads as "distinct icons" rather than "one
    // generic tint" — while keeping the layered-gradient depth touch (not a flat single-tone
    // fill) since that part of the sketch's research still holds regardless of hue count.
    private func sourceBadge(icon: String, isPrimary: Bool) -> some View {
        let size: CGFloat = isPrimary ? 54 : 44
        let hue: Color = {
            switch icon {
            case "photo.on.rectangle": return Color(red: 0.04, green: 0.52, blue: 1.0)   // Photos-like blue
            case "camera":             return Color(red: 1.0, green: 0.58, blue: 0.0)    // Camera-like orange
            default:                   return Color(red: 0.20, green: 0.78, blue: 0.35)  // Files-like green
            }
        }()
        return RoundedRectangle(cornerRadius: size * 0.28)
            .fill(
                RadialGradient(
                    colors: [hue.opacity(0.95), hue.opacity(0.85), hue.opacity(0.55)],
                    center: UnitPoint(x: 0.34, y: 0.28),
                    startRadius: 0,
                    endRadius: size * 0.75
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: .center),
                        lineWidth: 1
                    )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    // MARK: - Optional text

    @ViewBuilder
    private var textSection: some View {
        if let textSchema = preset.inputSchema?.text {
            VStack(alignment: .leading, spacing: 8) {
                Text(textSchema.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                // Plain SwiftUI TextField — not the composer's custom highlighting text view.
                TextField("", text: $text, prompt: Text(textSchema.label).foregroundStyle(theme.textTertiary), axis: .vertical)
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(theme.surfaceBorder, lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Optional style grid

    // "All" always shown; Feminine/Masculine chips only appear when at least one style in this
    // preset's grid actually declares that tag — presets with no gender_tag data (or an
    // all-unisex grid) never show a filter row with nothing to filter.
    private var availableGenderFilters: [PresetStyleGenderTag] {
        guard let styles = preset.inputSchema?.styleGrid else { return [] }
        var tags: [PresetStyleGenderTag] = []
        if styles.contains(where: { $0.genderTag == .feminine }) { tags.append(.feminine) }
        if styles.contains(where: { $0.genderTag == .masculine }) { tags.append(.masculine) }
        return tags
    }

    private func filteredStyles(_ styles: [PresetStyle]) -> [PresetStyle] {
        guard let styleGenderFilter else { return styles }
        return styles.filter { $0.genderTag == styleGenderFilter || $0.genderTag == nil }
    }

    @ViewBuilder
    private var styleGridSection: some View {
        if let styles = preset.inputSchema?.styleGrid, !styles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Style")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                if !availableGenderFilters.isEmpty {
                    HStack(spacing: 8) {
                        genderFilterChip(label: "All", isSelected: styleGenderFilter == nil) {
                            styleGenderFilter = nil
                        }
                        ForEach(availableGenderFilters, id: \.self) { tag in
                            genderFilterChip(label: tag == .feminine ? "Feminine" : "Masculine", isSelected: styleGenderFilter == tag) {
                                styleGenderFilter = tag
                            }
                        }
                    }
                }

                let visibleStyles = filteredStyles(styles)
                if visibleStyles.count > 6 {
                    // Two fixed rows, horizontal scroll — compact when a category has many
                    // styles (hairstyle has 12; user-requested 2026-07-08).
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: [GridItem(.fixed(94), spacing: 10), GridItem(.fixed(94), spacing: 10)], spacing: 10) {
                            ForEach(visibleStyles, id: \.id) { style in
                                styleCell(style)
                            }
                        }
                        .padding(.horizontal, 2)   // keeps the selection stroke from clipping at the edges
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                        ForEach(visibleStyles, id: \.id) { style in
                            styleCell(style)
                        }
                    }
                }
            }
        }
    }

    /// One style-grid cell (thumbnail + selection stroke + label). Fixed width so it lays out
    /// identically whether hosted in the vertical LazyVGrid (≤6 styles) or the horizontal
    /// 2-row LazyHGrid (>6 styles) above.
    private func styleCell(_ style: PresetStyle) -> some View {
        Button {
            selectedStyleId = (selectedStyleId == style.id) ? nil : style.id
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.surface)
                    .frame(height: 72)
                    .overlay {
                        if let thumbURL = style.thumbURL {
                            CachedThumbnailImage(cacheKey: "\(preset.id)-style-\(style.id)", url: thumbURL)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                selectedStyleId == style.id ? theme.textPrimary : theme.surfaceBorder,
                                lineWidth: selectedStyleId == style.id ? 2 : 1
                            )
                    )
                Text(style.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 90)
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func genderFilterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.white : theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isSelected ? presetAccent : theme.surface)
                )
                .overlay(
                    Capsule().stroke(theme.surfaceBorder, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Aspect ratio (selectable chips for GPT-Image-2 presets, else a fixed caption)

    @ViewBuilder
    private var aspectRatioSection: some View {
        if let ratios = preset.sheet?.aspectRatios, !ratios.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Aspect ratio")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if let resolutionLabel = preset.sheet?.resolutionLabel {
                        Text(resolutionLabel)
                            .font(.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                HStack(spacing: 10) {
                    ForEach(ratios, id: \.self) { ratio in
                        aspectChip(ratio)
                    }
                }
            }
        } else if let caption = fixedAspectCaption {
            VStack(alignment: .leading, spacing: 6) {
                Text("Output")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    private func aspectChip(_ ratio: String) -> some View {
        let isSelected = (selectedAspectRatio ?? preset.sheet?.defaultAspectRatio) == ratio
        return Button {
            selectedAspectRatio = ratio
        } label: {
            VStack(spacing: 6) {
                aspectRatioIcon(ratio)
                    .foregroundStyle(isSelected ? presetAccent : theme.textSecondary)
                Text(ratio)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? presetAccent : theme.surfaceBorder, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// Small rectangle glyph shaped to the chip's own ratio (e.g. tall for "2:3", wide for "3:2")
    /// — a lightweight custom "icon" rather than pulling in SF Symbols that don't exist per-ratio.
    private func aspectRatioIcon(_ ratio: String) -> some View {
        let components = ratio.split(separator: ":").compactMap { Double($0) }
        let w = components.count == 2 ? components[0] : 1
        let h = components.count == 2 ? components[1] : 1
        let maxDim: CGFloat = 20
        let size = w >= h
            ? CGSize(width: maxDim, height: maxDim * CGFloat(h / w))
            : CGSize(width: maxDim * CGFloat(w / h), height: maxDim)
        return RoundedRectangle(cornerRadius: 3)
            .stroke(lineWidth: 1.5)
            .frame(width: size.width, height: size.height)
    }

    /// Combines the registry's fixed aspect/duration/resolution labels into one caption for
    /// input-driven presets (no chip selector) — e.g. "Matches your video · Up to 30s · 720p".
    private var fixedAspectCaption: String? {
        guard let sheet = preset.sheet else { return nil }
        let parts = [sheet.aspectLabel, sheet.durationLabel, sheet.resolutionLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Generate bar

    // Likeness-rights attestation for the face presets — required before Generate enables (see
    // requiresLikenessConsent / isValid). Tapping anywhere on the row toggles the checkbox.
    private var consentRow: some View {
        Button {
            consentAccepted.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: consentAccepted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(consentAccepted ? presetAccent : theme.textSecondary)
                Text("I have the rights to this face and it isn't a real person's likeness used without permission.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .accessibilityAddTraits(consentAccepted ? [.isSelected] : [])
    }

    private var generateBar: some View {
        VStack(spacing: 6) {
            // Script-expansion presets (e.g. gorilla-vlogs) take an extra LLM hop before dispatch —
            // surface the server-provided caption while submitting instead of a second screen/modal
            // (UI-SPEC "Loading — gorilla script-expansion"). Purely additive to the existing
            // spinner-in-capsule submitting state below; no new sheet architecture.
            if isSubmitting, let preparingLabel = preset.sheet?.preparingLabel, !preparingLabel.isEmpty {
                Text(preparingLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(presetAccent)
                    Text("\(displayCost)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: displayCost)
                    Text("credits")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer()

                Button {
                    Task { await generate() }
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Generate")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(width: 120, height: 44)
                    .foregroundStyle(.white)
                    .background {
                        if isValid && !isSubmitting {
                            Capsule().fill(LinearGradient.brandPrimary)
                        } else {
                            Capsule().fill(theme.surfaceStrong)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!isValid || isSubmitting)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            theme.elevatedBackground
                .shadow(color: .black.opacity(0.12), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Cost (D-18)

    /// Live credit cost shown before Generate. Flat presets read the registry's static cost.
    /// Per-second presets (Motion Transfer) compute from the picked video's REAL duration,
    /// capped at the registry's `max_seconds` (D-16/D-17) if the user confirmed the trim.
    /// Motion Transfer (media_type == "avatar") reads the authoritative live rate parsed from
    /// GET /rates by RatesManager (Plan 05, D-18) rather than the registry's own snapshot value,
    /// since RatesManager is the single live source of truth the composer itself already uses.
    private var displayCost: Int {
        guard let cost = preset.cost else { return 0 }
        switch cost {
        case .flat(let credits):
            return credits
        case .perSecond(let creditsPerSec, let maxSeconds):
            let rawSeconds = videoSlotDurationSeconds ?? 0
            let cappedSeconds = maxSeconds.map { min(rawSeconds, Double($0)) } ?? rawSeconds
            if preset.mediaType == "avatar" {
                return Int(ceil(cappedSeconds * ratesManager.dreamactorRate))
            }
            return Int(ceil(cappedSeconds * creditsPerSec))
        }
    }

    /// The real (capped) picked-video duration to actually SEND to the server for per-second
    /// presets — nil for flat-cost presets. Mirrors `displayCost`'s `cappedSeconds` derivation
    /// exactly, since the server must bill the same duration the cost label displayed. Fixes a
    /// gap where this value was previously computed for display only and never transmitted
    /// (server silently defaulted to a flat 5s regardless of the real duration shown) — D-23.
    private var estimatedDurationSecondsForSubmission: Double? {
        guard case .perSecond(_, let maxSeconds)? = preset.cost else { return nil }
        let rawSeconds = videoSlotDurationSeconds ?? 0
        return maxSeconds.map { min(rawSeconds, Double($0)) } ?? rawSeconds
    }

    private var videoSlotDurationSeconds: Double? {
        guard let slots = preset.inputSchema?.slots else { return nil }
        for (index, slot) in slots.enumerated() where slot.kind == "video" {
            if index < slotInputs.count, let duration = slotInputs[index]?.durationSeconds {
                return duration
            }
        }
        return nil
    }

    /// The registry's per-second cap (Motion Transfer's 30s driving-video cap, D-16) — generic
    /// over any future per-second preset that declares `max_seconds`, not hardcoded to 30.
    private var capSecondsForActiveSlot: Double? {
        guard case .perSecond(_, let maxSeconds)? = preset.cost, let maxSeconds else { return nil }
        return Double(maxSeconds)
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard let schema = preset.inputSchema else { return false }
        for (index, slot) in schema.slots.enumerated() {
            let input = index < slotInputs.count ? slotInputs[index] : nil
            // 09.1-12 (Clothes Swap): an `optional` slot may stay empty, but if the user started
            // filling it, it must finish uploading before Generate is enabled — same rule as
            // required slots, just scoped to "in progress", not "must have a value".
            if slot.optional {
                if input?.isUploading == true { return false }
                continue
            }
            guard let input, input.uploadId != nil, !input.isUploading else { return false }
        }
        if let textSchema = schema.text, textSchema.required,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if requiresLikenessConsent && !consentAccepted { return false }
        return true
    }

    /// True for the upload-driven face presets (Motion Transfer / AI Influencer), which require a
    /// likeness-rights attestation before Generate is enabled.
    private var requiresLikenessConsent: Bool {
        preset.mediaType == "avatar" || preset.mediaType == "character_replace"
    }

    // MARK: - Slot media handlers

    private func handlePhotosPickerSelection(_ item: PhotosPickerItem?) async {
        guard let item, let index = activeSlotIndex else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let isVideo = item.supportedContentTypes.contains(.movie) || item.supportedContentTypes.contains(.mpeg4Movie)
        await handlePickedMedia(data, isVideo: isVideo, forSlot: index)
        selectedPickerItem = nil
    }

    private func handleImportedFile(_ url: URL, forSlot index: Int) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let isVideo = contentType?.conforms(to: .movie) ?? false
        await handlePickedMedia(data, isVideo: isVideo, forSlot: index)
    }

    // "My Generations" source (2026-07-12) — downloads the picked generation's own presigned
    // media URL, then routes through the exact same handlePickedMedia pipeline as every other
    // source (see GenerationPickerSheet's doc comment for why: per-second presets need real
    // client-side trimming, not just a billing-duration cap, and only handlePickedMedia's video
    // branch does that).
    private func handleGenerationPicked(_ item: GenerationItem, forSlot index: Int) async {
        guard let slots = preset.inputSchema?.slots, index < slots.count else { return }
        while slotInputs.count <= index { slotInputs.append(nil) }
        slotInputs[index] = PresetSlotInput(isUploading: true)

        guard let urlString = item.completedMediaUrl, let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url) else {
            slotInputs[index] = nil
            errorMessage = "Couldn't load this generation. Try again."
            return
        }
        await handlePickedMedia(data, isVideo: !item.isImage, forSlot: index)
    }

    /// Shared entry point for all three slot-picker sources (Photos / Camera / Files, D-19).
    private func handlePickedMedia(_ data: Data, isVideo: Bool, forSlot index: Int) async {
        guard let slots = preset.inputSchema?.slots, index < slots.count else { return }
        while slotInputs.count <= index { slotInputs.append(nil) }
        slotInputs[index] = PresetSlotInput(isUploading: true)

        if isVideo {
            guard let written = try? await PresetMediaPrep.shared.writeAndProbeDuration(data) else {
                slotInputs[index] = nil
                errorMessage = "Couldn't read the selected video. Try a different file."
                return
            }

            if let cap = capSecondsForActiveSlot, written.durationSeconds > cap {
                // D-17: don't reject — ask the user to confirm the first-30s trim before we
                // spend CPU re-encoding. Slot stays in its "uploading" placeholder state until
                // confirm/cancel resolves it.
                pendingTrim = PendingVideoTrim(
                    slotIndex: index,
                    url: written.url,
                    fallbackData: data,
                    durationSeconds: written.durationSeconds
                )
                return
            }

            await finishVideoSlot(
                index: index,
                url: written.url,
                fallbackData: data,
                billedDuration: written.durationSeconds,
                capSeconds: nil
            )
        } else {
            // Decode/downscale/re-encode to real JPEG first — Photos hands back full-res HEIC,
            // which the upload below mislabels as image/jpeg without this step (slow payload,
            // and gpt-image-2 can't decode the mislabeled bytes downstream — root cause of the
            // "takes forever then Couldn't complete that" report).
            let prepared = await PresetMediaPrep.shared.prepareImage(data)
            guard let response = try? await APIClient.shared.uploadReferenceMedia(
                data: prepared.data, mimeType: "image/jpeg", fileName: "preset-input.jpg"
            ) else {
                slotInputs[index] = nil
                errorMessage = "Couldn't upload this image. Try again."
                return
            }
            slotInputs[index] = PresetSlotInput(
                uploadId: response.id,
                url: response.url,
                thumbnail: prepared.thumbnail,
                isUploading: false,
                durationSeconds: nil
            )
        }
    }

    private func finishVideoSlot(index: Int, url: URL, fallbackData: Data, billedDuration: Double, capSeconds: Double?) async {
        let prepared = await PresetMediaPrep.shared.prepareVideo(url: url, fallbackData: fallbackData, capSeconds: capSeconds)
        guard let response = try? await APIClient.shared.uploadReferenceMedia(
            data: prepared.data, mimeType: "video/mp4", fileName: "preset-input.mp4"
        ) else {
            slotInputs[index] = nil
            errorMessage = "Couldn't upload this video — it may be too large. Try a shorter or lower-resolution clip."
            return
        }
        slotInputs[index] = PresetSlotInput(
            uploadId: response.id,
            url: response.url,
            thumbnail: prepared.thumbnail,
            isUploading: false,
            durationSeconds: capSeconds ?? billedDuration
        )
    }

    private func confirmTrim() {
        guard let pending = pendingTrim else { return }
        pendingTrim = nil
        Task {
            await finishVideoSlot(
                index: pending.slotIndex,
                url: pending.url,
                fallbackData: pending.fallbackData,
                billedDuration: pending.durationSeconds,
                capSeconds: capSecondsForActiveSlot ?? 30
            )
        }
    }

    private func cancelTrim() {
        guard let pending = pendingTrim else { return }
        slotInputs[pending.slotIndex] = nil
        pendingTrim = nil
    }

    // MARK: - Generate (D-10/D-11)

    private func generate() async {
        guard isValid, let schema = preset.inputSchema else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        // 09.1-12: `map`, NOT `compactMap` — must stay index-aligned to schema.slots so the
        // server (presetResolver) can tell "slot 2 was skipped" (nil) apart from "slot 2 shifted
        // left because slot 1 was skipped" (which compactMap would silently produce).
        let uploadIds: [String?] = schema.slots.indices.map { index in
            index < slotInputs.count ? slotInputs[index]?.uploadId : nil
        }
        let hasAnyUpload = uploadIds.contains { $0 != nil }

        // Preset Sheet Redesign: only presets that declare `sheet.aspectRatios` show a chip
        // selector (GPT-Image-2 image presets) — every other preset's aspect is fixed
        // server-side (shown as a read-only caption), so `selectedRatio` stays nil for them and
        // both fields below fall through to nil, exactly as before this redesign.
        let selectedRatio = selectedAspectRatio ?? preset.sheet?.defaultAspectRatio
        let isImagePreset = preset.mediaType == "image"

        // D-11: the client never constructs or sends the expanded template — only preset_id +
        // the slot upload ids. The server's presetResolver middleware owns prompt/model/media_type.
        let body = GenerationRequestBody(
            prompt: "",
            model: preset.model ?? "",
            mediaType: preset.mediaType,
            duration: nil,
            resolution: nil,
            aspectRatio: (!isImagePreset) ? selectedRatio : nil,
            audioEnabled: nil,
            imageAspectRatio: isImagePreset ? selectedRatio : nil,
            imageQuality: nil,
            referenceImages: nil,
            referenceVideos: nil,
            referenceUploadIds: nil,
            referenceImageUploadIds: nil,
            referenceVideoUploadIds: nil,
            referenceImageGenerationIds: nil,
            referenceVideoGenerationIds: nil,
            presetId: preset.presetId,
            presetInputUploadIds: hasAnyUpload ? uploadIds : nil,
            estimatedDurationSeconds: estimatedDurationSecondsForSubmission
        )

        // Optimistic UI (mirrors GenerateView.dispatchGeneration): drop a pending placeholder
        // into GenerationManager immediately — the run then rides the existing pending-card
        // machinery (polling, GenerationCardView) in the Generate feed (D-11). On success we post
        // .generationSubmitted so MainTabView switches to the Generate feed (D-D, 09.2-13).
        let placeholderId = "local-" + UUID().uuidString
        let placeholder = GenerationItem(
            localPlaceholderId: placeholderId,
            model: preset.model ?? "",
            // Image-OUTPUT presets (plain image AND faceswap) render as a still. Faceswap's DB
            // media_type is 'faceswap' server-side, but its output is an image (09.2-13, D-F) —
            // without this the optimistic placeholder would show a video card that never loads.
            mediaType: (preset.mediaType == "image" || preset.mediaType == "faceswap") ? .image : .video,
            prompt: nil,
            params: GenerationParams(
                resolution: nil,
                duration: nil,
                aspectRatio: nil,
                audioEnabled: nil,
                hasReference: hasAnyUpload ? true : nil,
                width: nil,
                height: nil,
                // Stamp preset identity so the pending card renders as the preset ("Faceswap")
                // with its badge/thumbnails immediately, instead of flashing "No prompt" + the
                // raw model until the authoritative server row (which carries preset_id) lands.
                presetId: preset.presetId,
                presetInputUploadIds: hasAnyUpload ? uploadIds : nil
            ),
            costCredits: displayCost,
            referenceUrls: nil,
            createdAt: Date()
        )
        generationManager.insertLocalPlaceholder(placeholder)

        do {
            let submitted = try await APIClient.shared.submitGeneration(body: body)
            // Promote the optimistic placeholder to the real server id instead of removing it and
            // hoping the next poll re-fetches the row (that race left the feed empty when the
            // fetch missed the just-created row — replica lag). The pending card now carries the
            // real id, so polling updates it in place through to completion.
            generationManager.promoteLocalPlaceholder(localId: placeholderId, toRealId: submitted.generationId)
            generationManager.startPolling(forceRefresh: true)
            await creditManager.fetchBalance()
            // D-D: on ANY preset submit, switch to the Generate feed (tab 1) so the user sees the
            // loading card. MainTabView observes this and sets selectedTab = 1.
            NotificationCenter.default.post(name: .generationSubmitted, object: nil)
            dismiss()
        } catch let apiError as APIError {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            if case .unexpectedResponse(_, let code) = apiError, code == "INSUFFICIENT_CREDITS" {
                errorMessage = "Insufficient credits."
                await creditManager.fetchBalance()
            } else if case .unexpectedResponse(_, let code) = apiError, code == "content_policy_violation" {
                errorMessage = "This may not adhere to our community guidelines. Please try again."
            } else if case .unexpectedResponse(_, let code) = apiError, code == "celebrity_likeness_blocked" {
                errorMessage = "This image looks like a real public figure. To protect against unauthorized likenesses, we can't animate it. You weren't charged."
            } else {
                print("[PresetInputSheet] submit rejected: \(apiError)")
                errorMessage = "An error has occurred. Please try again."
            }
        } catch {
            generationManager.removeLocalPlaceholder(id: placeholderId)
            errorMessage = "An error has occurred. Please try again."
        }
    }
}

// MARK: - Slot input state

/// Per-slot fill state. Public (not private) so a future Remix flow (Plan 08) can construct
/// `prefillSlots` from a stored generation's `preset_input_upload_ids` + re-signed URLs.
struct PresetSlotInput {
    var uploadId: String?
    var url: String?
    var thumbnail: UIImage?
    var isUploading: Bool = false
    var durationSeconds: Double?   // video slots only — real AVAsset duration (D-18)
}

private struct PendingVideoTrim {
    let slotIndex: Int
    let url: URL
    let fallbackData: Data
    let durationSeconds: Double
}

// MARK: - Off-main-actor media prep (mirrors MediaPrepService.swift's shape)
//
// A separate small actor rather than an edit to MediaPrepService.swift, which is out of this
// plan's touched-file scope (per orchestrator instructions, only PresetInputSheet.swift +
// APIClient.swift are committed by this plan). Same rationale as that file's own doc comment:
// SwiftUI's `View` protocol infers @MainActor on this struct's methods, so file I/O / duration
// probing / HEVC transcode / thumbnail extraction must happen inside a plain (non-MainActor)
// actor to avoid stuttering the UI while a slot uploads.
private actor PresetMediaPrep {
    static let shared = PresetMediaPrep()

    struct WrittenVideo {
        let url: URL
        let durationSeconds: Double
    }

    func writeAndProbeDuration(_ data: Data) async throws -> WrittenVideo {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
        try data.write(to: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        return WrittenVideo(url: url, durationSeconds: duration)
    }

    struct PreparedVideo {
        let data: Data
        let thumbnail: UIImage?
    }

    struct PreparedImage {
        let data: Data
        let thumbnail: UIImage?
    }

    /// Decode (handles HEIC/PNG/etc. — Photos returns HEIC on-device, but this file's upload path
    /// hardcodes mimeType "image/jpeg"), downscale so the longest side ≤ maxDimension, and
    /// re-encode as real JPEG so the bytes actually match the declared mime and the payload is
    /// small/fast to upload. Falls back to the original data if decoding fails.
    func prepareImage(_ data: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) async -> PreparedImage {
        guard let image = UIImage(data: data) else { return PreparedImage(data: data, thumbnail: nil) }
        let longest = max(image.size.width, image.size.height)
        let scaled: UIImage
        if longest > maxDimension {
            let f = maxDimension / longest
            let newSize = CGSize(width: image.size.width * f, height: image.size.height * f)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            scaled = image
        }
        let jpeg = scaled.jpegData(compressionQuality: quality) ?? data
        return PreparedImage(data: jpeg, thumbnail: scaled)
    }

    /// Optionally trims to the first `capSeconds` (D-16/D-17 confirmed trim), transcodes
    /// HEVC→H.264 if needed, and extracts a poster thumbnail.
    func prepareVideo(url: URL, fallbackData: Data, capSeconds: Double?) async -> PreparedVideo {
        var workingURL = url
        if let capSeconds {
            workingURL = (try? await Self.trim(url: url, toSeconds: capSeconds)) ?? url
        }
        workingURL = (try? await Self.transcodeToH264IfNeeded(url: workingURL)) ?? workingURL
        let finalData = (try? Data(contentsOf: workingURL)) ?? fallbackData
        let thumbnail = Self.extractThumbnail(from: workingURL)
        return PreparedVideo(data: finalData, thumbnail: thumbnail)
    }

    private static func extractThumbnail(from url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return (try? generator.copyCGImage(at: .zero, actualTime: nil)).map(UIImage.init)
    }

    private static func trim(url: URL, toSeconds seconds: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let cap = CMTime(seconds: seconds, preferredTimescale: 600)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return url
        }
        session.outputURL = tmpURL
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, cap))
        try await session.exportAsync()
        return tmpURL
    }

    private static func transcodeToH264IfNeeded(url: URL) async throws -> URL {
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
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "PresetMediaPrep", code: -1)
        }
        session.outputURL = tmpURL
        session.outputFileType = .mp4
        try await session.exportAsync()
        return tmpURL
    }
}

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
