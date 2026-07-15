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
    let onSelect: () -> Void
    /// Fires live, on every edge-handle drag change, with the clip's updated (trimStart, trimEnd)
    /// in seconds — the caller PATCHes `trim_start_seconds`/`trim_end_seconds`.
    let onTrimChange: (Double, Double) -> Void
    /// 13-22 i12: fires once the long-press succeeds (before any drag movement) — the caller
    /// enters reorder mode, selects this clip, and gives the medium haptic.
    let onReorderLift: () -> Void
    /// Fires on every drag-phase change once reorder mode is active, with the RAW horizontal
    /// translation (points) from the lift point — the caller updates its live slot math.
    let onReorderChanged: (CGFloat) -> Void
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
    // F5: the cell count actually rendered/loaded — only syncs to the live `cellCount` when NOT
    // mid-pinch (see `isZooming` doc comment above).
    @State private var committedCellCount: Int = 1

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)      // #8C59FF

    // Tiny in-memory-only cache — deliberately NOT ThumbnailCache.shared (see file header).
    private static let filmstripCache = NSCache<NSString, UIImage>()
    private let cellWidth: CGFloat = 46

    private var trimStart: Double { previewTrimStart ?? clip.trimStartSeconds }
    private var trimEnd: Double {
        previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
    }
    private var duration: Double { max(0, trimEnd - trimStart) }
    private var width: Double { max(duration * pxPerSecond, 30) }
    private var effectiveWidth: Double { isReordering ? reorderSlotWidth : width }
    // 13-22 i4: this pill sits in a plain leading-anchored HStack (clipRow) — growing/shrinking
    // its OWN `.frame(width:)` only ever moves the TRAILING edge (HStack repositions subsequent
    // siblings, but this pill's own leading edge is fixed by the cumulative width of EARLIER
    // siblings). A left-handle drag needs the LEADING edge to visually track the finger instead —
    // this local `.offset` compensates by exactly the trimStart delta, which also happens to keep
    // the trailing edge visually fixed (matches every trim-handle UX convention). Zero during a
    // right-handle drag, and irrelevant while reordering (handles are hidden then).
    private var trimHandleOffsetX: CGFloat { CGFloat(trimStart - clip.trimStartSeconds) * pxPerSecond }
    private var cellCount: Int { max(1, Int((width / cellWidth).rounded(.up))) }
    private var effectiveCellCount: Int { isZooming ? committedCellCount : cellCount }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.16, green: 0.14, blue: 0.22))

            mediaContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? accent : .clear, lineWidth: 2)
        )
        // 13-22 i3: with the clip row's HStack spacing now 0 (adjacent clips, CapCut has no gaps),
        // this 1pt leading-edge divider is what visually separates consecutive pills instead of a
        // real gap (harmless on the very first clip too — nothing sits immediately left of it).
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.black.opacity(0.45)).frame(width: 1)
        }
        .frame(width: effectiveWidth, height: 58)
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
        .onTapGesture { onSelect() }
        .highPriorityGesture(reorderGesture)
        .overlay(alignment: .leading) {
            if isSelected && !isReordering { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected && !isReordering { handle.highPriorityGesture(rightHandleGesture) }
        }
        // F2 (Plan 13-21): offset is now the LAST modifier — after the selection stroke and every
        // handle overlay — so the entire assembly (pill body + handles) translates together.
        // 13-22 i12: while reordering, trimHandleOffsetX is always 0 (handles hidden, preview
        // vars never populated) — only the dragged clip's own `dragOffsetX` applies here.
        .offset(x: isBeingDragged ? dragOffsetX : trimHandleOffsetX)
        .animation(.spring(duration: 0.25), value: isReordering)
        .task(id: "\(clip.id)-\(clip.url ?? "")-\(effectiveCellCount)") {
            guard clip.mediaType != "image" else { return }
            await loadFilmstripIfNeeded()
        }
        .onAppear { committedCellCount = cellCount }
        // F5: the pinch just ended — resync to whatever cellCount the final width settled at,
        // which re-triggers the .task above (effectiveCellCount now tracks live cellCount again).
        .onChange(of: isZooming) { wasZooming, nowZooming in
            if wasZooming, !nowZooming { committedCellCount = cellCount }
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
            // F5: renders at `effectiveCellCount` (frozen during a pinch), then `.scaleEffect`s the
            // whole strip horizontally to match the LIVE `width` — existing frames visibly stretch
            // as the user pinches instead of the grid abruptly adding/removing cells (which would
            // otherwise re-trigger an AVAssetImageGenerator load burst on every magnification
            // delta). The scale factor collapses back to ~1 the instant the pinch ends and
            // `effectiveCellCount` resyncs to the live `cellCount`.
            let renderedCellCount = effectiveCellCount
            let nominalWidth = CGFloat(renderedCellCount) * cellWidth
            HStack(spacing: 0) {
                ForEach(0..<renderedCellCount, id: \.self) { index in
                    Group {
                        if let frame = filmstripFrames[index] {
                            Image(uiImage: frame).resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: cellWidth)
                }
            }
            .frame(width: nominalWidth, height: 58, alignment: .leading)
            .scaleEffect(x: nominalWidth > 0 ? width / nominalWidth : 1, y: 1, anchor: .leading)
            .frame(width: width, height: 58, alignment: .leading)
        } else {
            placeholderGlyph
        }
    }

    @ViewBuilder
    private var reorderThumb: some View {
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
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 92, height: 116)

        for index in 0..<effectiveCellCount {
            if Task.isCancelled { return }
            let cacheKey = "\(clip.id)-\(index)" as NSString
            if let cached = Self.filmstripCache.object(forKey: cacheKey) {
                filmstripFrames[index] = cached
                continue
            }
            let seconds = trimStart + Double(index) * (cellWidth / pxPerSecond)
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

    // MARK: - 13-22 i12: long-press-to-lift reorder. A plain (non-held) drag never satisfies
    // LongPressGesture's minimumDuration and SwiftUI fails the whole sequence, letting the touch
    // fall through to TimelineTrackView's background scrubGesture — a quick drag on a clip scrubs
    // (CapCut behavior); only a genuine 0.35s hold engages reorder mode. `.first(true)` (the long
    // press succeeding) is idempotency-guarded by the CALLER (TimelineTrackView.startReorder
    // no-ops if this clip is already the one being dragged), since SwiftUI may deliver that case
    // more than once before the sequence advances to `.second`.

    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    onReorderLift()
                case .second(true, let drag):
                    if let drag { onReorderChanged(drag.translation.width) }
                default:
                    break
                }
            }
            .onEnded { _ in
                onReorderEnded()
            }
    }

    // MARK: - Edge-handle trim (SC2)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStartTrim == nil { leftDragStartTrim = clip.trimStartSeconds }
                let deltaSec = value.translation.width / pxPerSecond
                var newStart = (leftDragStartTrim ?? clip.trimStartSeconds) + deltaSec
                let endBound = previewTrimEnd ?? (clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds)
                newStart = max(0, min(newStart, endBound - 0.2))
                previewTrimStart = newStart
            }
            .onEnded { _ in
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
                onSelect()
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
