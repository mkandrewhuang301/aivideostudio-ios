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
// KNOWN LIMITATION (unchanged from the original buildComposition, 13-20): only VIDEO clips
// contribute actual frames to the composition (AVFoundation has no simple "insert a still image
// as a video segment" primitive without a custom AVVideoCompositor). An image clip still reserves
// its trimmed duration on the virtual timeline so state.totalDuration/the ruler/scrubbing stay
// correct, but the composition itself shows the surrounding video content rather than the still —
// EditorView's `currentImageClipURL` overlay compensates in the live inline preview; Export
// (server-side, ffmpegProcessor.ts) renders images correctly regardless.

import AVFoundation

enum EditorCompositionBuilder {
    struct ClipRange {
        let clipId: String
        let start: Double
        let end: Double
    }

    /// Builds one AVMutableComposition spanning every clip in `clips` (sorted by `sortOrder`),
    /// back-to-back, plus each clip's [start, end) window on that composition's timeline (global
    /// seconds) — the exact cumulative-duration walk every cross-clip helper in the Editor already
    /// does (TimelineTrackView.selectClip, CaptionTrackRow.clipIdUnderPlayhead, EditorView's split
    /// helpers). Returns nil for an empty clip list.
    static func build(clips: [ProjectClip]) async -> (composition: AVMutableComposition, ranges: [ClipRange])? {
        let sorted = clips.sorted { $0.sortOrder < $1.sortOrder }
        guard !sorted.isEmpty else { return nil }

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var ranges: [ClipRange] = []

        for clip in sorted {
            let clipDuration = duration(of: clip)
            let durationTime = CMTime(seconds: clipDuration, preferredTimescale: 600)
            let start = cursor.seconds

            if clip.mediaType == "video", let urlString = clip.url, let url = URL(string: urlString) {
                let asset = AVURLAsset(url: url)
                let trimStart = CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: trimStart, duration: durationTime)
                do {
                    if let assetVideoTrack = try await asset.loadTracks(withMediaType: .video).first {
                        try videoTrack?.insertTimeRange(timeRange, of: assetVideoTrack, at: cursor)
                    }
                    if let assetAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                        try audioTrack?.insertTimeRange(timeRange, of: assetAudioTrack, at: cursor)
                    }
                } catch {
                    print("[EditorCompositionBuilder] insert error for clip \(clip.id): \(error)")
                }
            }

            cursor = cursor + durationTime
            ranges.append(ClipRange(clipId: clip.id, start: start, end: cursor.seconds))
        }

        return (composition, ranges)
    }

    static func duration(of clip: ProjectClip) -> Double {
        let end = clip.trimEndSeconds ?? clip.originalDurationSeconds ?? clip.trimStartSeconds
        return max(0, end - clip.trimStartSeconds)
    }
}
