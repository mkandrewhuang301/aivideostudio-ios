// ClipPillView.swift
// Fantasia
// Phase 13, Plan 12: one clip rendered as a filmstrip pill (SC2) — select / body-drag reorder /
// edge-handle trim / delete. Gesture layering reproduces Spike 001's CuePillView.swift verbatim
// (.planning/spikes/001-caption-timing-drag/Sources/CuePillView.swift, VALIDATED on-device):
// `.contentShape(Rectangle()).onTapGesture{onSelect()}.highPriorityGesture(bodyDragGesture)`, plus
// a `.highPriorityGesture` on each 22pt-wide invisible edge-handle overlay — SwiftUI's topmost-
// view-at-touch-point hit-testing is what keeps body-drag/edge-handle/background-scrub from
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

import SwiftUI
import AVFoundation

struct ClipPillView: View {
    let clip: ProjectClip
    let pxPerSecond: Double
    let isSelected: Bool
    let onSelect: () -> Void
    /// Fires once, on drag release, with the final horizontal translation (points) — the CALLER
    /// (TimelineTrackView) resolves this into a target index + `sort_order` PATCH; this view never
    /// mutates `sort_order` itself, only previews the live drag.
    let onReorder: (CGFloat) -> Void
    /// Fires live, on every edge-handle drag change, with the clip's updated (trimStart, trimEnd)
    /// in seconds — the caller PATCHes `trim_start_seconds`/`trim_end_seconds`.
    let onTrimChange: (Double, Double) -> Void
    @State private var dragTranslation: CGFloat = 0
    @State private var leftDragStartTrim: Double? = nil
    @State private var rightDragStartTrim: Double? = nil
    @State private var filmstripFrames: [Int: UIImage] = [:]

    private let accent = Color(red: 0.55, green: 0.35, blue: 1.0)      // #8C59FF

    // Tiny in-memory-only cache — deliberately NOT ThumbnailCache.shared (see file header).
    private static let filmstripCache = NSCache<NSString, UIImage>()
    private let cellWidth: CGFloat = 46

    private var trimStart: Double { clip.trimStartSeconds }
    private var trimEnd: Double {
        clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
    }
    private var width: Double { max((trimEnd - trimStart) * pxPerSecond, 30) }
    private var cellCount: Int { max(1, Int((width / cellWidth).rounded(.up))) }

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
        .frame(width: width, height: 58)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .highPriorityGesture(bodyDragGesture)
        .overlay(alignment: .leading) {
            if isSelected { handle.highPriorityGesture(leftHandleGesture) }
        }
        .overlay(alignment: .trailing) {
            if isSelected { handle.highPriorityGesture(rightHandleGesture) }
        }
        // F2 (Plan 13-21): offset is now the LAST modifier — after the selection stroke and every
        // handle overlay — so the entire assembly (pill body + handles) translates together during
        // a body drag. Previously offset was applied BEFORE the overlays, so only the pill body
        // moved live while the handles stayed pinned to the pre-drag layout position until the
        // drag ended and the whole view re-rendered ("handles snap into place after release").
        .offset(x: dragTranslation)
        .task(id: "\(clip.id)-\(clip.url ?? "")-\(cellCount)") {
            guard clip.mediaType != "image" else { return }
            await loadFilmstripIfNeeded()
        }
    }

    // MARK: - Media preview (13-20 i5)

    @ViewBuilder
    private var mediaContent: some View {
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
        } else if !filmstripFrames.isEmpty {
            HStack(spacing: 0) {
                ForEach(0..<cellCount, id: \.self) { index in
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
            .frame(width: width, height: 58, alignment: .leading)
        } else {
            placeholderGlyph
        }
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

        for index in 0..<cellCount {
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

    // MARK: - Body drag (reorder preview — CALLER performs the sort_order PATCH on release)

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                onSelect()
                dragTranslation = value.translation.width
            }
            .onEnded { value in
                let finalTranslation = value.translation.width
                dragTranslation = 0
                onReorder(finalTranslation)
            }
    }

    // MARK: - Edge-handle trim (SC2)

    private var leftHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if leftDragStartTrim == nil { leftDragStartTrim = trimStart }
                let deltaSec = value.translation.width / pxPerSecond
                var newStart = (leftDragStartTrim ?? trimStart) + deltaSec
                newStart = max(0, min(newStart, trimEnd - 0.2))
                onTrimChange(newStart, trimEnd)
            }
            .onEnded { _ in leftDragStartTrim = nil }
    }

    private var rightHandleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onSelect()
                if rightDragStartTrim == nil { rightDragStartTrim = trimEnd }
                let deltaSec = value.translation.width / pxPerSecond
                let cap = clip.originalDurationSeconds ?? .greatestFiniteMagnitude
                var newEnd = (rightDragStartTrim ?? trimEnd) + deltaSec
                newEnd = min(cap, max(newEnd, trimStart + 0.2))
                onTrimChange(trimStart, newEnd)
            }
            .onEnded { _ in rightDragStartTrim = nil }
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
