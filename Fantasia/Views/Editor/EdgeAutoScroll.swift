// EdgeAutoScroll.swift
// Fantasia
// Plan 13-22 i14: shared edge-auto-scroll math for a pill body-drag (text/audio/caption) that
// nears either side of the timeline viewport. Deliberately just a pure rate function — NOT a
// Timer/Combine publisher (CLAUDE.md: Swift Concurrency only) — each row view (AudioTrackRow/
// TextOverlayTrackRow/CaptionTrackRow) owns its own `Task` loop and calls `rate(...)` on every
// body-drag `.onChanged` to decide whether to start/retarget/stop that loop. Does NOT apply to
// clip reorder (i12 — clips scroll in collapsed-square space, a different interaction) or to any
// trim/edge-handle drag (only the body-MOVE drag needs this).

import CoreGraphics

enum EdgeAutoScroll {
    /// Outer band (points, from either viewport edge) that triggers scrolling at all.
    static let edgeZone: CGFloat = 44
    /// Innermost band (points) that triggers the accelerated (×2) rate.
    static let acceleratedZone: CGFloat = 16

    /// Returns the seconds-per-second rate `state.currentTime` should advance at while the finger
    /// (at `fingerX`, in the timeline's own named coordinate space) is held in an edge zone —
    /// negative scrolls backward (finger near the LEADING edge), positive scrolls forward. `nil`
    /// when `fingerX` is outside both edge zones (no scrolling).
    ///
    /// Base rate is exactly the plan's spec: `44 / pxPerSecond` seconds of playhead motion per
    /// second of hold (so the rate self-scales with zoom — the same 44pt edge band always feels
    /// like "about one edge-band-width of timeline per second" regardless of pxPerSecond).
    static func rate(fingerX: CGFloat, viewportWidth: CGFloat, pxPerSecond: Double) -> Double? {
        guard viewportWidth > 0, pxPerSecond > 0 else { return nil }
        let base = 44.0 / pxPerSecond

        let distanceFromLeading = fingerX
        let distanceFromTrailing = viewportWidth - fingerX

        if distanceFromLeading < acceleratedZone {
            return -base * 2
        } else if distanceFromLeading < edgeZone {
            return -base
        } else if distanceFromTrailing < acceleratedZone {
            return base * 2
        } else if distanceFromTrailing < edgeZone {
            return base
        }
        return nil
    }
}
