// ClipPillView.swift
// Fantasia
// Phase 13, Plan 12: one clip rendered as a filmstrip pill (SC2) — select / edge-handle trim /
// delete. Gesture layering reproduces Spike 001's CuePillView.swift verbatim
// (.planning/spikes/001-caption-timing-drag/Sources/CuePillView.swift, VALIDATED on-device):
// `.contentShape(Rectangle()).onTapGesture{onSelect()}.highPriorityGesture(...)`, plus a
// `.highPriorityGesture` on each 22pt-wide invisible edge-handle overlay — SwiftUI's topmost-
// view-at-touch-point hit-testing is what keeps a pill's own gestures / background-scrub from
// stealing each other's touches, no manual gesture-priority juggling needed.
//
// 22pt edge handles / this pill's 58pt height are EXEMPT from the 44pt HIG minimum (13-UI-SPEC.md
// "Continuous-drag hit targets" exception) — validated on-device by Spike 001, do not enlarge.
//
// 13-20 i5: real media previews. Video clips render a filmstrip — one AVAssetImageGenerator
// frame per 46pt cell spanning the pill's width, cached in a tiny in-memory NSCache (distinct
// from ThumbnailCache.shared, which is keyed one-image-per-generation-id and persists to disk —
// this needs many small per-clip/per-cell frames that never need to survive an app relaunch).
// Image clips render a single AsyncImage fill. While loading or on failure, the original
// gradient+glyph placeholder still shows.
//
// 13-22 i12: CapCut-style long-press reorder REPLACES the old plain-drag body reorder entirely.
// A plain drag on a clip's body no longer attaches to anything here — it falls through to
// TimelineTrackView's background scrubGesture (CapCut behavior: dragging a clip scrubs). Only a
// LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture()) engages reorder mode;
// TimelineTrackView (the caller, which alone knows the full clip list) owns ALL cross-clip state
// (reorderingClipId/liveOrder/slot math) — this view only reports lift/drag/end events up and
// renders itself differently (collapsed uniform square, floating+scaled+shadowed if it's the
// dragged one) based on the `isReordering`/`isBeingDragged`/`dragOffsetX` inputs the caller feeds
// back down.

import SwiftUI
import AVFoundation
import UIKit

struct ClipPillView: View {
    let clip: ProjectClip
    let pxPerSecond: Double
    let isSelected: Bool
    /// F5 (Plan 13-21): true for the duration of an active pinch gesture — while true, the
    /// filmstrip keeps rendering at its LAST COMMITTED cell count instead of recomputing on every
    /// live magnification delta (which would otherwise thrash AVAssetImageGenerator on every
    /// frame of the pinch). Cell count recomputes/reloads once the pinch ends.
    let isZooming: Bool
    /// 13-22 i12: true for EVERY clip while ANY clip is in reorder mode — collapses this pill to
    /// the uniform 46×58 square regardless of whether IT is the one being dragged.
    let isReordering: Bool
    /// 13-22 i12: true ONLY for the one clip currently lifted — applies the floating/scaled/
    /// shadowed/z-raised treatment + the duration badge.
    let isBeingDragged: Bool
    /// 13-22 i12: the CALLER's computed visual offset for the dragged clip (already compensated
    /// for however much its own slot has shifted in the caller's `liveOrder` — see
    /// TimelineTrackView.draggedClipVisualOffsetX's doc comment). Ignored unless `isBeingDragged`.
    let dragOffsetX: CGFloat
    /// 13-23 J7: the collapsed square's width while reordering. TimelineTrackView's viewport-space
    /// reorder overlay scales this DOWN when many clips must fit on screen; the default 46 is the
    /// original uniform square (used by the hidden in-content row, whose collapsed size no longer
    /// matters visually).
    var reorderSlotWidth: CGFloat = 46
    /// The timeline owns scrub recognition. It rejects a tap that ends immediately after that
    /// same touch moved, while leaving this pill gesture-free for plain-drag scrub fall-through.
    var shouldAcceptTap: () -> Bool = { true }
    let onSelect: () -> Void
    /// Fires once on edge-handle release with the clip's final (trimStart, trimEnd) in seconds —
    /// the caller PATCHes `trim_start_seconds`/`trim_end_seconds`.
    let onTrimChange: (Double, Double) -> Void
    /// 13-22 i12: fires once the long-press succeeds (before any drag movement) — the caller
    /// enters reorder mode, selects this clip, and gives the medium haptic.
    let onReorderLift: () -> Void
    /// Fires on every drag-phase change once reorder mode is active, with the RAW horizontal
    /// translation plus the finger's current/start x positions in the timeline coordinate space.
    let onReorderChanged: (_ translation: CGFloat, _ location: CGFloat, _ startLocation: CGFloat) -> Void
    /// Fires once, on release (or cancellation) — the caller commits the drop (or no-ops if
    /// nothing moved) and exits reorder mode.
    let onReorderEnded: () -> Void

    @State private var leftDragStartTrim: Double? = nil
    @State private var rightDragStartTrim: Double? = nil
    // 13-22 i4: commit-on-release — onChanged only updates these LOCAL preview values (pill
    // width/offset render from them); onTrimChange fires ONCE in .onEnded with the final values.
    // Previously onTrimChange fired on every onChanged, which drove a network PATCH +
    // syncProjectFromManager() (full composition rebuild) per finger movement — the "generates at
    // the divider and slides over" video glitch. nil = idle, render from `clip`'s committed values.
    @State private var previewTrimStart: Double? = nil
    @State private var previewTrimEnd: Double? = nil
    @State private var filmstripFrames: [Int: UIImage] = [:]
    // 13-24 K2 / F5: px-per-second used for SOURCE cell layout+loads. Frozen while pinching so
    // cells don't thrash; resyncs when isZooming flips false.
    @State private var committedPxPerSecond: Double = 44
    /// 13-24 K1: GestureState resets on EVERY termination path (end/cancel/interrupt) — drives
    /// the guaranteed reorder exit that bare `.onEnded` can miss.
    @GestureState private var reorderGestureActive = false

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)      // #8C59FF

    // Tiny in-memory-only cache — deliberately NOT ThumbnailCache.shared (see file header).
    private static let filmstripCache = NSCache<NSString, UIImage>()
    private let cellWidth: CGFloat = 46

    private var trimStart: Double { previewTrimStart ?? clip.trimStartSeconds }
    private var trimEnd: Double {
        previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
    }
    private var duration: Double { max(0, trimEnd - trimStart) }
    /// Timeline geometry stays proportional all the way down to the 0.2s trim minimum. The old
    /// 30pt floor made the handle visually freeze while its time kept changing. The independent
    /// 22pt handle overlays remain the continuous-drag touch targets.
    private var width: Double { Self.timelineWidth(duration: duration, pxPerSecond: pxPerSecond) }
    private var effectiveWidth: Double { isReordering ? reorderSlotWidth : width }
    private var committedDuration: Double {
        max(0, (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds) - clip.trimStartSeconds)
    }
    private var committedWidth: Double {
        Self.timelineWidth(duration: committedDuration, pxPerSecond: pxPerSecond)
    }
    /// A left-edge preview must not simultaneously shrink its HStack slot: doing both moved the
    /// next clip underneath the selected pill. Keep the committed slot stable and align the live
    /// inner pill to its trailing edge until the single magnetic ripple on release.
    private var layoutWidth: Double {
        leftDragStartTrim != nil && !isReordering ? committedWidth : effectiveWidth
    }

    static func timelineWidth(duration: Double, pxPerSecond: Double) -> Double {
        max(duration * pxPerSecond, 1)
    }

    /// 13-24 K2: layout zoom for the SOURCE strip (frozen mid-pinch).
    private var layoutPxPerSecond: Double { isZooming ? committedPxPerSecond : pxPerSecond }
    private var originalDuration: Double { max(clip.originalDurationSeconds ?? duration, duration, 0.1) }
    /// Cells cover the full source, independent of trim window.
    private var sourceCellCount: Int {
        max(1, Int((originalDuration * layoutPxPerSecond / Double(cellWidth)).rounded(.up)))
    }
    private var zoomBucket: Int { Int(layoutPxPerSecond.rounded()) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.16, green: 0.14, blue: 0.22))

            mediaContent
        }
        // Establish the uniform slot before clipping. `scaledToFill` can otherwise paint beyond a
        // content-sized clip and then escape a frame applied later in the modifier chain.
        .frame(width: effectiveWidth, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // 13-26 M3: strokeBorder — see AudioPillView's identical fix comment (a centered stroke
        // rendered 1pt past the pill frame on every side, breaking edge alignment with the rows
        // below when selected).
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? accent : .clear, lineWidth: 2)
        )
        // 13-22 i3: with the clip row's HStack spacing now 0 (adjacent clips, CapCut has no gaps),
        // this 1pt leading-edge divider is what visually separates consecutive pills instead of a
        // real gap (harmless on the very first clip too — nothing sits immediately left of it).
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
        }
        // 13-22 i12: floating/scaled/shadowed/z-raised treatment for the ONE dragged clip; every
        // OTHER clip (including this one when idle) stays flat. The collapse/expand of
        // `effectiveWidth` above and this scale/shadow both animate via the `.animation` below.
        .scaleEffect(isBeingDragged ? 1.06 : 1.0)
        .shadow(color: .black.opacity(isBeingDragged ? 0.4 : 0), radius: isBeingDragged ? 10 : 0, y: isBeingDragged ? 4 : 0)
        .zIndex(isBeingDragged ? 10 : 0)
        .overlay(alignment: .top) {
            if isBeingDragged {
                durationBadge.offset(y: -22)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard shouldAcceptTap() else { return }
            onSelect()
        }
        // Item 4 (Andrew review, 2026-07-17) — ROOT CAUSE of "selected clip freezes horizontal
        // swiping": `.highPriorityGesture` doesn't just win ties against this SAME view's other
        // recognizers (tap vs. drag) — per Apple's own docs it gives a gesture "precedence over
        // OTHER gestures in the hierarchy," which blocks TimelineTrackView's ancestor scrub/tracks
        // DragGesture from EVER getting a chance to recognize a touch that started on a pill, for
        // the WHOLE touch session, even after this LongPress.sequenced(before: Drag) ultimately
        // FAILS (a quick swipe blows past the long-press's movement tolerance well before the
        // 0.5s threshold). A failed highPriorityGesture does not hand the touch back mid-session —
        // the ancestor gesture never started tracking it in the first place, so the swipe just
        // dies. This reproduces on EVERY clip (selected or not), not only a selected one — the
        // 22pt edge handles below are the part that's actually selected-gated, and are NOT part of
        // this bug (they intentionally win with minimumDistance:0 the moment a touch starts on
        // them; that's correct trim behavior, left untouched).
        //
        // Fix: `.simultaneousGesture` instead of `.highPriorityGesture` lets the ancestor's
        // scrubGesture/tracksGesture (TimelineTrackView.swift) watch the SAME touch concurrently
        // rather than being shut out. This is safe specifically because those two ancestor
        // gestures ALREADY guard `reorderingClipId == nil` at the top of their `onChanged` (added
        // for exactly this scenario, but never effective before since the pill's
        // `.highPriorityGesture` prevented them from running at all) — so a quick swipe scrubs
        // normally, and the instant a genuine 0.5s hold promotes this clip into reorder mode
        // (`onReorderLift` sets `reorderingClipId`), the ancestor gestures' own guard makes their
        // `onChanged` a no-op for the rest of that touch, so reordering and scrubbing can never
        // fire concurrently from the same drag.
        .simultaneousGesture(reorderGesture)
        .overlay(alignment: .leading) {
            if isSelected && !isReordering { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected && !isReordering { handle.highPriorityGesture(rightHandleGesture) }
        }
        .offset(x: isBeingDragged ? dragOffsetX : 0)
        .frame(
            width: layoutWidth,
            height: 58,
            alignment: leftDragStartTrim != nil && !isReordering ? .trailing : .leading
        )
        .animation(.spring(duration: 0.25), value: isReordering)
        .task(id: "\(clip.id)-\(clip.url ?? "")-\(sourceCellCount)-\(zoomBucket)") {
            guard clip.mediaType != "image" else { return }
            await loadFilmstripIfNeeded()
        }
        .onAppear { committedPxPerSecond = pxPerSecond }
        // F5 / K2: pinch ended — resync layout px so cells resample at the new zoom bucket.
        .onChange(of: isZooming) { wasZooming, nowZooming in
            if nowZooming {
                leftDragStartTrim = nil
                rightDragStartTrim = nil
                previewTrimStart = nil
                previewTrimEnd = nil
            } else if wasZooming {
                committedPxPerSecond = pxPerSecond
            }
        }
        // 13-24 K1: when GestureState resets (any exit path), always tear down reorder mode.
        .onChange(of: reorderGestureActive) { _, active in
            if !active { onReorderEnded() }
        }
    }

    // MARK: - Media preview (13-20 i5, extended 13-22 i12)

    @ViewBuilder
    private var mediaContent: some View {
        if isReordering {
            // i12: "first filmstrip cell as its thumb, clipped" — a single un-stretched frame
            // filling the uniform square, not the multi-cell stretched strip below.
            reorderThumb
        } else if clip.mediaType == "image" {
            if let urlString = clip.url, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderGlyph
                    }
                }
            } else {
                placeholderGlyph
            }
        } else if !filmstripFrames.isEmpty {
            // 13-24 K2: SOURCE-anchored strip — cells are fixed to source time from t=0; the pill
            // is a WINDOW (offset + clipped frame). Trim left slides the strip; trim right only
            // changes the window width. No stretch. Mid-pinch: layout uses committedPx; live
            // width scales the windowed strip so frames don't resample until pinch ends.
            let layoutPx = layoutPxPerSecond
            let layoutWindowWidth = Self.timelineWidth(duration: duration, pxPerSecond: layoutPx)
            let zoomScale = isZooming && committedPxPerSecond > 0
                ? pxPerSecond / committedPxPerSecond
                : 1.0
            let stripWidth = CGFloat(sourceCellCount) * cellWidth
            HStack(spacing: 0) {
                ForEach(0..<sourceCellCount, id: \.self) { index in
                    Group {
                        if let frame = filmstripFrames[index] {
                            Image(uiImage: frame).resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: cellWidth, height: 58)
                    .clipped()
                }
            }
            .frame(width: stripWidth, height: 58, alignment: .leading)
            .offset(x: -CGFloat(trimStart) * layoutPx)
            .frame(width: layoutWindowWidth, height: 58, alignment: .leading)
            .clipped()
            .scaleEffect(x: zoomScale, y: 1, anchor: .leading)
            .frame(width: width, height: 58, alignment: .leading)
            .clipped()
        } else {
            placeholderGlyph
        }
    }

    @ViewBuilder
    private var reorderThumb: some View {
        Group {
            if clip.mediaType == "image" {
                if let urlString = clip.url, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            placeholderGlyph
                        }
                    }
                } else {
                    placeholderGlyph
                }
            } else if let firstFrame = filmstripFrames[0] {
                Image(uiImage: firstFrame).resizable().scaledToFill()
            } else {
                placeholderGlyph
            }
        }
        .frame(width: reorderSlotWidth, height: 58)
        .clipped()
    }

    private var durationBadge: some View {
        Text(String(format: "%.1fs", duration))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.75), in: Capsule())
    }

    private var placeholderGlyph: some View {
        Image(systemName: clip.mediaType == "image" ? "photo" : "film")
            .font(.system(size: 16))
            .foregroundStyle(.white.opacity(0.45))
    }

    private func loadFilmstripIfNeeded() async {
        guard let urlString = clip.url, let url = URL(string: urlString) else { return }
        // Plan 13-26 M1 Fix B: resolve through the local disk cache — same clip the composition
        // builder just downloaded (or will download) is reused here instead of a second
        // independent stream from R2 for the filmstrip thumbnails.
        let localURL = await ClipFileCache.shared.localURL(clipId: clip.id, remoteURL: url)
        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 92, height: 116)

        // 13-24 K2: sample SOURCE time from 0, independent of trim. Cache keys include zoom bucket
        // so different px/s tiers don't collide.
        let layoutPx = layoutPxPerSecond
        let bucket = Int(layoutPx.rounded())
        let count = sourceCellCount
        for index in 0..<count {
            if Task.isCancelled { return }
            let cacheKey = "\(clip.id)-src\(index)-z\(bucket)" as NSString
            if let cached = Self.filmstripCache.object(forKey: cacheKey) {
                filmstripFrames[index] = cached
                continue
            }
            let seconds = Double(index) * (Double(cellWidth) / layoutPx)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: time) else { continue }
            let image = UIImage(cgImage: cgImage)
            Self.filmstripCache.setObject(image, forKey: cacheKey)
            if Task.isCancelled { return }
            filmstripFrames[index] = image
        }
    }

    private var handle: some View {
        ZStack {
            Color.white.opacity(0.001) // invisible but hit-testable — widens the drag target
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: 3, height: 18)
        }
        .frame(width: 22)
        .contentShape(Rectangle())
    }

    // MARK: - 13-22 i12 / 13-24 K1: long-press-to-lift reorder. Hold threshold is 0.5s so a tap
    // never lifts. GestureState guarantees exit on ANY release/cancel (bare .onEnded can miss).
    // A plain (non-held) drag fails the long-press and falls through to background scrub.

    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineBlock")))
            .updating($reorderGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard !isZooming else { return }
                switch value {
                case .first(true):
                    onReorderLift()
                case .second(true, let drag):
                    if let drag {
                        onReorderChanged(drag.translation.width, drag.location.x, drag.startLocation.x)
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                onReorderEnded() // idempotent duplicate of GestureState exit
            }
    }

    // MARK: - Edge-handle trim (SC2)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isZooming else { return }
                if leftDragStartTrim == nil { leftDragStartTrim = clip.trimStartSeconds }
                let deltaSec = value.translation.width / pxPerSecond
                var newStart = (leftDragStartTrim ?? clip.trimStartSeconds) + deltaSec
                let endBound = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
                newStart = max(0, min(newStart, endBound - 0.2))
                previewTrimStart = newStart
            }
            .onEnded { _ in
                guard !isZooming else {
                    leftDragStartTrim = nil
                    previewTrimStart = nil
                    previewTrimEnd = nil
                    return
                }
                let finalStart = previewTrimStart ?? clip.trimStartSeconds
                let finalEnd = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
                leftDragStartTrim = nil
                onTrimChange(finalStart, finalEnd)
                previewTrimStart = nil
                previewTrimEnd = nil
            }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isZooming else { return }
                if rightDragStartTrim == nil {
                    rightDragStartTrim = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
                }
                let deltaSec = value.translation.width / pxPerSecond
                let cap = clip.originalDurationSeconds ?? .greatestFiniteMagnitude
                let startBound = previewTrimStart ?? clip.trimStartSeconds
                var newEnd = (rightDragStartTrim ?? clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds) + deltaSec
                newEnd = min(cap, max(newEnd, startBound + 0.2))
                previewTrimEnd = newEnd
            }
            .onEnded { _ in
                guard !isZooming else {
                    rightDragStartTrim = nil
                    previewTrimStart = nil
                    previewTrimEnd = nil
                    return
                }
                let finalStart = previewTrimStart ?? clip.trimStartSeconds
                let finalEnd = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
                rightDragStartTrim = nil
                onTrimChange(finalStart, finalEnd)
                previewTrimStart = nil
                previewTrimEnd = nil
            }
    }

    // MARK: - Split primitive (T-13-30: clamps both resulting ranges to non-negative,
    // non-overlapping bounds — server-side PATCH/POST also validates trim bounds per the threat
    // model). Pure helper only: the contextual Split action that calls this is wired from
    // EditorView in a later plan (no bottom toolbar exists yet in this plan's scope) — this is
    // deliberately just the primitive so that plan doesn't need to touch this file again.
    //
    // `localSplitSeconds` is the split point EXPRESSED IN THE CLIP'S OWN TRIMMED RANGE (i.e.
    // already converted from the global playhead time by the caller, who knows this clip's
    // position on the overall timeline). Returns nil if the split point isn't strictly inside the
    // clip's current trim range (nothing to split).
    struct SplitResult {
        /// New `trim_end_seconds` for the EXISTING clip (same id, PATCH).
        let originalTrimEnd: Double
        /// `trim_start_seconds` for a NEW clip sharing this clip's same source (POST).
        let newClipTrimStart: Double
        /// `trim_end_seconds` for the new clip (nil = plays to the source's original end).
        let newClipTrimEnd: Double?
        /// `sort_order` to assign the new clip — immediately after the original.
        let newClipSortOrder: Int
    }

    static func splitPoint(clip: ProjectClip, at localSplitSeconds: Double) -> SplitResult? {
        let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
        guard localSplitSeconds > clip.trimStartSeconds + 0.05,
              localSplitSeconds < end - 0.05 else { return nil }

        return SplitResult(
            originalTrimEnd: localSplitSeconds,
            newClipTrimStart: localSplitSeconds,
            newClipTrimEnd: clip.trimEndSeconds,
            newClipSortOrder: clip.sortOrder + 1
        )
    }
}
