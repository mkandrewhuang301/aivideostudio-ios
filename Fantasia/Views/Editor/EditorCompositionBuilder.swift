// EditorCompositionBuilder.swift
// Fantasia
// Plan 13-21 F1: extracts EditorView's buildComposition() (13-19 Task C0) into a shared helper so
// the inline preview player (EditorView.rebuildPlayer) builds ONE back-to-back multi-clip
// composition — the root cause of "fullscreen plays overlapping media" was an earlier fullscreen
// player looping just `clips.first` via AVPlayerLooper while writing its own looped LOCAL time
// onto the shared `state.currentTime`, fighting the inline player's global multi-clip timeline.
// Plan 13-22 F6 went further: the fullscreen player (FullscreenEditorPlayerView) no longer builds
// its own composition at all — it shares EditorView's own live AVPlayer instance outright. Also
// used by F17's CoverPickerSheet (frame strip over the whole project timeline).
//
// Plan 13-23 J4: build() now ALSO returns an AVMutableVideoComposition that aspect-FITS each clip
// segment into one shared canvas. AVMutableComposition alone SCALES every inserted segment to the
// composition's natural size (the first segment's) — a portrait clip following a 16:9 clip was
// STRETCHED to 16:9. The per-segment layer-instruction transforms here (preferredTransform
// composed with a centered aspect-fit scale+translate into `renderSize`) pillarbox/letterbox it
// instead, exactly like the backend export's scale+pad ffmpeg graph and CapCut (reference frame
// g04). EditorView sets the returned videoComposition on its AVPlayerItem (fullscreen shares that
// same item); CoverPickerSheet sets it on its AVAssetImageGenerators so picked frames match.
//
// KNOWN LIMITATION: only VIDEO clips contribute actual frames to the composition (AVFoundation
// has no simple "insert a still image as a video segment" primitive without a custom
// AVVideoCompositor). Image clips therefore reserve a logical range and EditorView overlays the
// still itself. EditorView uses `playableDuration(compositionDuration:ranges:)` so an all-image
// composition's AVFoundation duration of zero does not pin every horizontal timeline drag at
// 00:00. Export (server-side, ffmpegProcessor.ts) renders images directly.

import AVFoundation
import CoreGraphics

enum EditorCompositionBuilder {
    struct ClipRange {
        let clipId: String
        let start: Double
        let end: Double
    }

    // 13-23 J4: fixed-preset canvas sizes — mirrors the backend export's COMPOSE_CANVAS
    // (ffmpegProcessor.ts), so the live preview letterboxes each clip into the SAME canvas shape
    // the export render will.
    private static let presetCanvasSizes: [String: CGSize] = [
        "9:16": CGSize(width: 1080, height: 1920),
        "4:5": CGSize(width: 1080, height: 1350),
        "1:1": CGSize(width: 1080, height: 1080),
        "16:9": CGSize(width: 1920, height: 1080),
    ]

    private static func forceEven(_ n: CGFloat) -> CGFloat {
        let i = Int(n.rounded(.down))
        return CGFloat(i % 2 == 0 ? i : i - 1)
    }

    /// Builds one AVMutableComposition spanning every clip in `clips` (sorted by `sortOrder`),
    /// back-to-back, plus each clip's [start, end) window on that composition's timeline (global
    /// seconds) — the exact cumulative-duration walk every cross-clip helper in the Editor already
    /// does (TimelineTrackView.selectClip, CaptionTrackRow.clipIdUnderPlayhead, EditorView's split
    /// helpers). Returns nil for an empty clip list.
    ///
    /// 13-23 J4: also returns the per-clip aspect-fit `videoComposition` (see file header) — nil
    /// when no video clip contributed a segment (an all-image project; an AVVideoComposition over
    /// an empty video track is invalid and the image overlay handles rendering anyway).
    static func build(clips: [ProjectClip], aspectRatio: String) async -> (
        composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition?,
        audioMix: AVAudioMix?,
        ranges: [ClipRange],
        isDegraded: Bool
    )? {
        let sorted = clips.sorted { $0.sortOrder < $1.sortOrder }
        guard !sorted.isEmpty else { return nil }

        let composition = AVMutableComposition()
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        let renderSize = await resolveRenderSize(aspectRatio: aspectRatio, sortedClips: sorted)

        // Resolve independent clip downloads concurrently before assembling the ordered
        // composition. The old await-inside-for-loop made a cold three-clip project pay the sum
        // of all download times even though the files have no dependency on one another.
        let videoRequests: [(id: String, remoteURL: URL)] = sorted.compactMap { clip in
            guard clip.mediaType == "video",
                  let urlString = clip.url,
                  let remoteURL = URL(string: urlString)
            else { return nil }
            return (clip.id, remoteURL)
        }
        let localVideoURLs = await withTaskGroup(of: (String, URL).self, returning: [String: URL].self) { group in
            for request in videoRequests {
                group.addTask {
                    let localURL = await ClipFileCache.shared.localURL(
                        clipId: request.id,
                        remoteURL: request.remoteURL
                    )
                    return (request.id, localURL)
                }
            }
            var resolved: [String: URL] = [:]
            for await (id, url) in group { resolved[id] = url }
            return resolved
        }

        var cursor = CMTime.zero
        var ranges: [ClipRange] = []
        // J4.2: ONE AVMutableVideoCompositionInstruction per clip segment. Video segments carry a
        // layer instruction with the aspect-fit transform; image-clip ranges get a background-only
        // instruction (no layer instructions → black) so the instruction timeline stays gap-free —
        // AVFoundation requires instructions to cover the composition's full duration with no
        // gaps/overlaps, and EditorView overlays the actual still on top exactly as before.
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var hasVideoSegment = false
        var hasMissingVideoSegment = false

        for clip in sorted {
            let clipDuration = duration(of: clip)
            let segmentDuration = clipDuration > 0 && clipDuration.isFinite ? clipDuration : 0
            let durationTime = CMTime(seconds: segmentDuration, preferredTimescale: 600)
            let segmentStart = cursor
            let start = segmentStart.seconds

            let instruction = AVMutableVideoCompositionInstruction()

            if clip.mediaType == "video", let localURL = localVideoURLs[clip.id] {
                // Plan 13-26 M1 Fix B: resolve through the local disk cache first — after a
                // clip's first download, every subsequent editor open (even with a fresh
                // presigned URL string) loads the SAME local file instantly instead of
                // re-streaming the full video from R2 again.
                let asset = AVURLAsset(url: localURL)
                let trimStart = CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: trimStart, duration: durationTime)
                var insertedVideoSegment = false
                do {
                    if let assetVideoTrack = try await asset.loadTracks(withMediaType: .video).first {
                        // Keep unlike source formats on separate composition tracks. A single
                        // mutable track that switches from portrait to landscape format
                        // descriptions can make AVPlayerLayer's live compositor fail (-19230),
                        // even though offline frame generation succeeds. Only one of these tracks
                        // is active in any instruction window, so playback remains back-to-back.
                        let segmentTrack = composition.addMutableTrack(
                            withMediaType: .video,
                            preferredTrackID: kCMPersistentTrackID_Invalid
                        )
                        try segmentTrack?.insertTimeRange(timeRange, of: assetVideoTrack, at: cursor)
                        hasVideoSegment = true
                        insertedVideoSegment = segmentTrack != nil
                        if let segmentTrack {
                            // The layer instruction references the COMPOSITION's video track (the
                            // track the player actually renders), not the source asset's.
                            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: segmentTrack)
                            let transform = await aspectFitTransform(for: assetVideoTrack, into: renderSize)
                            layer.setTransform(transform, at: cursor)
                            instruction.layerInstructions = [layer]
                        }
                    }
                    if let assetAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                        try audioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: cursor)
                    }
                } catch {
                    print("[EditorCompositionBuilder] insert error for clip \(clip.id): \(error)")
                }
                if !insertedVideoSegment { hasMissingVideoSegment = true }
            } else if clip.mediaType == "video" {
                hasMissingVideoSegment = true
            }

            cursor = cursor + durationTime
            // Tile instructions from the SAME CMTime cursor used for insertTimeRange — each
            // segment ends exactly where the next begins (no independent Double recomputation).
            instruction.timeRange = CMTimeRange(start: segmentStart, end: cursor)
            ranges.append(ClipRange(clipId: clip.id, start: start, end: cursor.seconds))
            instructions.append(instruction)
        }

        // A stale presigned URL can make every source insertion fail while the logical timeline
        // above still advances. Never force an instruction's end backwards to a shorter (or zero)
        // composition duration: that creates an invalid CMTimeRange whose seconds surface as NaN.
        // The ProjectManager URL-refresh bridge will update the clips and trigger a clean rebuild.
        guard !hasMissingVideoSegment else {
            print(
                "[EditorCompositionBuilder] degraded build: inserted \(composition.duration.seconds)s of expected \(cursor.seconds)s — media unavailable (stale URLs?)"
            )
            return (composition, nil, makeAudioMix(audioTrack: audioTrack, clips: sorted), ranges, true)
        }

        // AVFoundation's duration stops at the last real media sample, so a trailing image's
        // logical instruction may begin at/after that end. Keep only the instruction domain the
        // player item can actually consume; EditorView owns the still range beyond it.
        instructions.removeAll { $0.timeRange.start >= composition.duration }
        if let last = instructions.last {
            last.timeRange = CMTimeRange(start: last.timeRange.start, end: composition.duration)
        }

        validateInstructionTiling(
            instructions: instructions,
            clipIds: sorted.map(\.id),
            compositionDuration: composition.duration
        )

        var videoComposition: AVMutableVideoComposition?
        if hasVideoSegment {
            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            vc.instructions = instructions
            videoComposition = vc
        }

        return (composition, videoComposition, makeAudioMix(audioTrack: audioTrack, clips: sorted), ranges, false)
    }

    /// Builds the live preview's per-clip source-audio levels. All source audio is inserted into
    /// one back-to-back composition track, so setting a gain at each clip boundary gives the
    /// selected clip its own level without affecting music/audio-overlay tracks.
    static func makeAudioMix(audioTrack: AVCompositionTrack?, clips: [ProjectClip]) -> AVAudioMix? {
        guard let audioTrack else { return nil }

        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        var cursor = CMTime.zero
        for clip in clips.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            parameters.setVolume(Float(normalizedVolume(clip.volume)), at: cursor)
            cursor = cursor + CMTime(seconds: duration(of: clip), preferredTimescale: 600)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Persisted/API values are validated server-side, but clamp again at the playback boundary
    /// so a stale cache or malformed legacy payload can never overdrive AVFoundation.
    static func normalizedVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return 1 }
        return min(max(volume, 0), 1)
    }

    /// The scrub/playhead domain is the larger of AVFoundation's real-media duration and the
    /// logical clip ranges. They differ for still images because still pixels are rendered by a
    /// SwiftUI overlay rather than inserted as video samples.
    static func playableDuration(compositionDuration: Double, ranges: [ClipRange]) -> Double {
        max(compositionDuration.isFinite ? compositionDuration : 0, ranges.last?.end ?? 0)
    }

    /// AVPlayer is authoritative only when every playable range has media samples. A positive-
    /// duration image is rendered by SwiftUI instead, so AVPlayer would skip that range on Play.
    static func requiresLogicalPlaybackClock(clips: [ProjectClip]) -> Bool {
        clips.contains { $0.mediaType == "image" && duration(of: $0) > 0 }
    }

    static func duration(of clip: ProjectClip) -> Double {
        let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
        let d = end - clip.trimStartSeconds
        guard d.isFinite else {
            print("[EditorCompositionBuilder] non-finite duration for clip \(clip.id)")
            return 0
        }
        return max(0, d)
    }

    /// J4.1: the shared canvas the video composition renders into — the project's resolved aspect
    /// (reuses 13-22 i1's resolution rule): fixed presets map to their 1080p-capped sizes
    /// (matching the backend's COMPOSE_CANVAS); 'original' resolves to the FIRST (sortOrder)
    /// clip's stored pixel dimensions, falling back to that clip's own rotation-corrected video
    /// track naturalSize, then to 1080×1920. Always even-forced (h264 requirement, mirrors the
    /// backend's forceEven).
    private static func resolveRenderSize(aspectRatio: String, sortedClips: [ProjectClip]) async -> CGSize {
        if let preset = presetCanvasSizes[aspectRatio] { return preset }
        // "original" (or any unknown value)
        guard let first = sortedClips.first else { return CGSize(width: 1080, height: 1920) }
        if let w = first.width, let h = first.height, w > 0, h > 0 {
            let size = evenCanvasSize(width: CGFloat(w), height: CGFloat(h))
            if size.width > 0, size.height > 0 { return size }
        }
        if first.mediaType == "video", let urlString = first.url, let url = URL(string: urlString) {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let naturalSize = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let size = naturalSize.applying(transform)
                let w = abs(size.width), h = abs(size.height)
                if w > 0, h > 0 {
                    let canvas = evenCanvasSize(width: w, height: h)
                    if canvas.width > 0, canvas.height > 0 { return canvas }
                }
            }
        }
        return CGSize(width: 1080, height: 1920)
    }

    private static func evenCanvasSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: forceEven(width), height: forceEven(height))
    }

    /// Plan 13-25 L2: AVVideoComposition instructions must tile [0, composition.duration]
    /// with no gaps or overlaps — violations produce a `.failed` player item (black preview).
    private static func validateInstructionTiling(
        instructions: [AVMutableVideoCompositionInstruction],
        clipIds: [String],
        compositionDuration: CMTime
    ) {
        guard !instructions.isEmpty else { return }

        let sorted = instructions.enumerated().sorted { $0.element.timeRange.start < $1.element.timeRange.start }
        var violations: [String] = []

        if sorted.first?.element.timeRange.start != .zero {
            violations.append("first instruction starts at \(sorted.first!.element.timeRange.start.seconds), expected 0")
        }

        for index in 1..<sorted.count {
            let (prevIdx, prev) = sorted[index - 1]
            let (currIdx, curr) = sorted[index]
            let prevEnd = prev.timeRange.end
            let currStart = curr.timeRange.start
            if currStart != prevEnd {
                let prevClip = clipIds.indices.contains(prevIdx) ? clipIds[prevIdx] : "?"
                let currClip = clipIds.indices.contains(currIdx) ? clipIds[currIdx] : "?"
                violations.append(
                    "gap/overlap between clip \(prevClip) end \(prevEnd.seconds) and clip \(currClip) start \(currStart.seconds)"
                )
            }
        }

        if let last = sorted.last?.element, last.timeRange.end != compositionDuration {
            let lastClip = clipIds.indices.contains(sorted.last!.offset) ? clipIds[sorted.last!.offset] : "?"
            violations.append(
                "last instruction (clip \(lastClip)) ends at \(last.timeRange.end.seconds), expected composition duration \(compositionDuration.seconds)"
            )
        }

        guard !violations.isEmpty else { return }

        let message = "[EditorCompositionBuilder] instruction tiling violation: \(violations.joined(separator: "; "))"
        print(message)
    }

    /// J4.2: `preferredTransform` composed with a centered aspect-FIT scale+translate of the
    /// clip's rotation-corrected natural size into `renderSize`. The origin fix-up
    /// (`-displayRect.origin`) normalizes preferredTransforms whose rotation maps the frame into
    /// negative coordinate space before the fit is applied — the standard robust recipe for
    /// arbitrary capture orientations.
    private static func aspectFitTransform(for track: AVAssetTrack, into renderSize: CGSize) async -> CGAffineTransform {
        guard let naturalSize = try? await track.load(.naturalSize),
              let preferred = try? await track.load(.preferredTransform),
              naturalSize.width > 0, naturalSize.height > 0
        else { return .identity }

        // Rotation-corrected display rect, shifted back to the origin.
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let originFix = CGAffineTransform(translationX: -displayRect.origin.x, y: -displayRect.origin.y)
        let displayW = displayRect.width
        let displayH = displayRect.height
        guard displayW > 0, displayH > 0 else { return preferred }

        let scale = min(renderSize.width / displayW, renderSize.height / displayH)
        let tx = (renderSize.width - displayW * scale) / 2
        let ty = (renderSize.height - displayH * scale) / 2

        return preferred
            .concatenating(originFix)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}
