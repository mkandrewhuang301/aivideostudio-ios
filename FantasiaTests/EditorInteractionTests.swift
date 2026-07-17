import XCTest
@testable import Fantasia

final class EditorInteractionTests: XCTestCase {
    private func overlay(
        _ id: String,
        row: Int?,
        start: Double,
        end: Double
    ) -> TextOverlay {
        TextOverlay(
            id: id,
            text: id,
            xNorm: 0.5,
            yNorm: 0.5,
            rowIndex: row,
            startSeconds: start,
            endSeconds: end
        )
    }

    func testTextRetimeBoundsStopAtSameRowNeighbors() {
        let previous = overlay("previous", row: 0, start: 0, end: 2)
        let current = overlay("current", row: 0, start: 3, end: 5)
        let next = overlay("next", row: 0, start: 6.5, end: 8)

        let bounds = TextOverlayTrackRow.retimeBounds(
            for: current,
            among: [previous, current, next]
        )

        XCTAssertEqual(bounds.minimumStart, 2)
        XCTAssertEqual(bounds.maximumEnd, 6.5)
    }

    func testTextRetimeBoundsIgnoreOtherRows() {
        let current = overlay("current", row: 0, start: 3, end: 5)
        let overlappingOtherRow = overlay("other", row: 1, start: 1, end: 7)

        let bounds = TextOverlayTrackRow.retimeBounds(
            for: current,
            among: [current, overlappingOtherRow]
        )

        XCTAssertEqual(bounds.minimumStart, 0)
        XCTAssertNil(bounds.maximumEnd)
    }

    func testTextRetimeBoundsUseEffectiveRowsForLegacyOverlays() {
        let first = overlay("first", row: nil, start: 0, end: 2)
        let current = overlay("current", row: nil, start: 3, end: 5)
        let next = overlay("next", row: nil, start: 6, end: 8)

        let bounds = TextOverlayTrackRow.retimeBounds(
            for: current,
            among: [next, current, first]
        )

        XCTAssertEqual(bounds.minimumStart, 2)
        XCTAssertEqual(bounds.maximumEnd, 6)
    }

    func testClipTimelineWidthRemainsTimeProportionalBelowOldThirtyPointFloor() {
        for pxPerSecond in [8.0, 44.0, 240.0] {
            let narrow = ClipPillView.timelineWidth(duration: 0.2, pxPerSecond: pxPerSecond)
            let wider = ClipPillView.timelineWidth(duration: 0.4, pxPerSecond: pxPerSecond)

            XCTAssertLessThan(narrow, wider)
            XCTAssertEqual(wider, max(0.4 * pxPerSecond, 1), accuracy: 0.0001)
        }
    }

    func testCommittedCoverMarkerTracksOldFrameUntilSelectionCompletes() {
        let viewport: CGFloat = 320
        let px: CGFloat = 40

        XCTAssertEqual(
            CoverPickerSheet.committedMarkerX(
                committedTime: 2,
                scrubbedTime: 2,
                pixelsPerSecond: px,
                viewportWidth: viewport
            ),
            160
        )
        XCTAssertEqual(
            CoverPickerSheet.committedMarkerX(
                committedTime: 2,
                scrubbedTime: 4,
                pixelsPerSecond: px,
                viewportWidth: viewport
            ),
            80
        )
        XCTAssertEqual(
            CoverPickerSheet.committedMarkerX(
                committedTime: 4,
                scrubbedTime: 4,
                pixelsPerSecond: px,
                viewportWidth: viewport
            ),
            160
        )
    }

    func testVideoCacheRejectsErrorBodiesBeforeInstallingThemAsMP4() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let errorURL = directory.appendingPathComponent("error.mp4")
        var errorData = Data("<?xml version=\"1.0\"?><Error>Expired</Error>".utf8)
        errorData.append(Data(repeating: 0, count: 1_024))
        try errorData.write(to: errorURL)
        XCTAssertFalse(VideoCache.isValidPayload(at: errorURL))

        let mediaURL = directory.appendingPathComponent("video.mp4")
        var mediaData = Data(repeating: 0, count: 1_024)
        mediaData.replaceSubrange(4..<12, with: Data("ftypisom".utf8))
        try mediaData.write(to: mediaURL)
        XCTAssertTrue(VideoCache.isValidPayload(at: mediaURL))
    }

    @MainActor
    func testPendingExportIsRegisteredUnderItsRealGenerationID() {
        let manager = GenerationManager()

        manager.registerPendingExport(id: "export-generation", aspectRatio: "16:9")
        manager.registerPendingExport(id: "export-generation", aspectRatio: "16:9")

        XCTAssertEqual(manager.generations.count, 1)
        XCTAssertEqual(manager.generations.first?.id, "export-generation")
        XCTAssertEqual(manager.generations.first?.status, .pending)
        XCTAssertFalse(manager.generations.first?.isLocalPlaceholder ?? true)
    }
}
