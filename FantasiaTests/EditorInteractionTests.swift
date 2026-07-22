import XCTest
@testable import Fantasia

final class EditorInteractionTests: XCTestCase {
    func testGenerationCardDetailButtonMeetsMinimumTapTarget() {
        XCTAssertGreaterThanOrEqual(GenerationCardView.detailButtonMinimumHitSize, 44)
    }

    func testProjectClipVolumeDefaultsToFullForLegacyPayloads() throws {
        let data = Data(#"""
        {
            "id":"legacy",
            "sort_order":0,
            "media_type":"video",
            "trim_start_seconds":0,
            "trim_end_seconds":3,
            "original_duration_seconds":3,
            "width":1920,
            "height":1080
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(ProjectClip.self, from: data)
        XCTAssertEqual(decoded.volume, 1)
    }

    func testClipVolumeIsClampedAtPlaybackBoundary() {
        XCTAssertEqual(EditorCompositionBuilder.normalizedVolume(-1), 0)
        XCTAssertEqual(EditorCompositionBuilder.normalizedVolume(0.42), 0.42)
        XCTAssertEqual(EditorCompositionBuilder.normalizedVolume(2), 1)
        XCTAssertEqual(EditorCompositionBuilder.normalizedVolume(.nan), 1)
    }

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

    func testClipReorderRequiresDragAfterLongPress() {
        XCTAssertFalse(TimelineTrackView.shouldActivateClipReorder(translation: 0))
        XCTAssertFalse(TimelineTrackView.shouldActivateClipReorder(translation: 3.99))
        XCTAssertFalse(TimelineTrackView.shouldActivateClipReorder(translation: -3.99))
        XCTAssertTrue(TimelineTrackView.shouldActivateClipReorder(translation: 4))
        XCTAssertTrue(TimelineTrackView.shouldActivateClipReorder(translation: -4))
    }

    func testClipUnderPlayheadMovesToFollowingClipAfterBoundary() {
        let clips = [
            clip("first", order: 0, duration: 4),
            clip("second", order: 1, duration: 3)
        ]

        XCTAssertEqual(TimelineTrackView.clipID(at: 3.999, in: clips), "first")
        XCTAssertEqual(TimelineTrackView.clipID(at: 4, in: clips), "first")
        XCTAssertEqual(TimelineTrackView.clipID(at: 4.001, in: clips), "second")
        XCTAssertEqual(TimelineTrackView.clipID(at: 6.999, in: clips), "second")
        XCTAssertEqual(TimelineTrackView.clipID(at: 7, in: clips), "second")
    }

    func testClipUnderPlayheadUsesTrimmedDurationsAndSortOrder() {
        let later = clip("later", order: 1, duration: 5, trimStart: 1, trimEnd: 3.5)
        let first = clip("first", order: 0, duration: 2)

        XCTAssertEqual(TimelineTrackView.clipID(at: 1.999, in: [later, first]), "first")
        XCTAssertEqual(TimelineTrackView.clipID(at: 2, in: [later, first]), "first")
        XCTAssertEqual(TimelineTrackView.clipID(at: 2.001, in: [later, first]), "later")
        XCTAssertEqual(TimelineTrackView.clipID(at: 4.5, in: [later, first]), "later")
    }

    func testClipBoundaryDetentHoldsBeforeEnteringNextClip() {
        let atBoundary = TimelineTrackView.scrubProjection(
            startTime: 3.5,
            translationX: -20,
            pxPerSecond: 40,
            boundaries: [4]
        )
        let insideDetent = TimelineTrackView.scrubProjection(
            startTime: 3.5,
            translationX: -27.9,
            pxPerSecond: 40,
            boundaries: [4]
        )
        let pastDetent = TimelineTrackView.scrubProjection(
            startTime: 3.5,
            translationX: -32,
            pxPerSecond: 40,
            boundaries: [4]
        )

        XCTAssertEqual(atBoundary.time, 4, accuracy: 0.0001)
        XCTAssertEqual(atBoundary.heldBoundary, 4)
        XCTAssertEqual(insideDetent.time, 4, accuracy: 0.0001)
        XCTAssertEqual(insideDetent.heldBoundary, 4)
        XCTAssertEqual(pastDetent.time, 4.1, accuracy: 0.0001)
        XCTAssertNil(pastDetent.heldBoundary)
    }

    func testClipBoundaryDetentWorksInReverse() {
        let held = TimelineTrackView.scrubProjection(
            startTime: 4.5,
            translationX: 24,
            pxPerSecond: 40,
            boundaries: [4]
        )
        let cleared = TimelineTrackView.scrubProjection(
            startTime: 4.5,
            translationX: 32,
            pxPerSecond: 40,
            boundaries: [4]
        )

        XCTAssertEqual(held.time, 4, accuracy: 0.0001)
        XCTAssertEqual(held.heldBoundary, 4)
        XCTAssertEqual(cleared.time, 3.9, accuracy: 0.0001)
        XCTAssertNil(cleared.heldBoundary)
    }

    func testFastMomentumStillVisitsEveryCrossedClipBoundary() {
        XCTAssertEqual(
            TimelineTrackView.boundariesCrossed(from: 1, to: 8, boundaries: [2, 4, 6]),
            [2, 4, 6]
        )
        XCTAssertEqual(
            TimelineTrackView.boundariesCrossed(from: 8, to: 1, boundaries: [2, 4, 6]),
            [6, 4, 2]
        )
        XCTAssertEqual(
            TimelineTrackView.boundariesCrossed(from: 4, to: 6, boundaries: [2, 4, 6]),
            [6]
        )
    }

    func testAllImageCompositionKeepsItsLogicalScrubDuration() async throws {
        let clip = ProjectClip(
            id: "still",
            sortOrder: 0,
            url: nil,
            mediaType: "image",
            trimStartSeconds: 0,
            trimEndSeconds: nil,
            originalDurationSeconds: 3,
            width: 1920,
            height: 1080
        )

        let built = await EditorCompositionBuilder.build(clips: [clip], aspectRatio: "original")
        let result = try XCTUnwrap(built)

        XCTAssertFalse(result.isDegraded)
        XCTAssertEqual(
            EditorCompositionBuilder.playableDuration(
                compositionDuration: result.composition.duration.seconds,
                ranges: result.ranges
            ),
            3,
            accuracy: 0.001
        )
        XCTAssertEqual(try XCTUnwrap(result.ranges.first?.end), 3, accuracy: 0.001)
    }

    func testLeadingImageMakesMixedProjectUseLogicalPlaybackClock() {
        let still = ProjectClip(
            id: "still",
            sortOrder: 0,
            url: nil,
            mediaType: "image",
            trimStartSeconds: 0,
            trimEndSeconds: 3,
            originalDurationSeconds: 3,
            width: 1920,
            height: 1080
        )
        let video = clip("video", order: 1, duration: 5)

        XCTAssertTrue(EditorCompositionBuilder.requiresLogicalPlaybackClock(clips: [still, video]))
        XCTAssertFalse(EditorCompositionBuilder.requiresLogicalPlaybackClock(clips: [video]))
    }

    private func clip(
        _ id: String,
        order: Int,
        duration: Double,
        trimStart: Double = 0,
        trimEnd: Double? = nil
    ) -> ProjectClip {
        ProjectClip(
            id: id,
            sortOrder: order,
            url: nil,
            mediaType: "video",
            trimStartSeconds: trimStart,
            trimEndSeconds: trimEnd,
            originalDurationSeconds: duration,
            width: 1920,
            height: 1080
        )
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

    func testCoverFrameSnapUsesOnlyTinyThreePointWindow() {
        let committedTime = 2.0
        let px: CGFloat = 40

        XCTAssertEqual(
            CoverPickerSheet.snappedScrubTime(
                proposedTime: committedTime + 2.9 / Double(px),
                committedTime: committedTime,
                pixelsPerSecond: px,
                snapDistancePoints: 3
            ),
            committedTime
        )
        XCTAssertEqual(
            CoverPickerSheet.snappedScrubTime(
                proposedTime: committedTime - 2.9 / Double(px),
                committedTime: committedTime,
                pixelsPerSecond: px,
                snapDistancePoints: 3
            ),
            committedTime
        )

        let justOutside = committedTime + 3.01 / Double(px)
        XCTAssertEqual(
            CoverPickerSheet.snappedScrubTime(
                proposedTime: justOutside,
                committedTime: committedTime,
                pixelsPerSecond: px,
                snapDistancePoints: 3
            ),
            justOutside
        )
    }

    func testTextOverlayCenterKeepsRotatedBoundsInsideVideo() {
        let center = TextOverlayCanvasGeometry.constrainedCenter(
            proposed: CGPoint(x: 310, y: 170),
            contentSize: CGSize(width: 80, height: 32),
            rotationDegrees: 30,
            canvasSize: CGSize(width: 320, height: 180)
        )

        let radians = CGFloat(30.0 * .pi / 180)
        let halfWidth = (80 * abs(cos(radians)) + 32 * abs(sin(radians))) / 2
        let halfHeight = (80 * abs(sin(radians)) + 32 * abs(cos(radians))) / 2

        XCTAssertEqual(center.x, 320 - halfWidth, accuracy: 0.0001)
        XCTAssertEqual(center.y, 180 - halfHeight, accuracy: 0.0001)
    }

    func testOversizedTextOverlayFallsBackToCanvasCenter() {
        let center = TextOverlayCanvasGeometry.constrainedCenter(
            proposed: CGPoint(x: 300, y: 170),
            contentSize: CGSize(width: 400, height: 200),
            rotationDegrees: 0,
            canvasSize: CGSize(width: 320, height: 180)
        )

        XCTAssertEqual(center, CGPoint(x: 160, y: 90))
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

        manager.registerPendingExport(
            id: "export-generation",
            projectId: "studio-project",
            aspectRatio: "16:9"
        )
        manager.registerPendingExport(
            id: "export-generation",
            projectId: "studio-project",
            aspectRatio: "16:9"
        )

        XCTAssertEqual(manager.generations.count, 1)
        XCTAssertEqual(manager.generations.first?.id, "export-generation")
        XCTAssertEqual(manager.generations.first?.status, .pending)
        XCTAssertFalse(manager.generations.first?.isLocalPlaceholder ?? true)
    }

    @MainActor
    func testStudioExportIsNeverPrunedByGenerationListReconciliation() throws {
        let manager = GenerationManager()
        manager.registerPendingExport(
            id: "long-running-export",
            projectId: "studio-project",
            aspectRatio: "16:9"
        )
        let export = try XCTUnwrap(manager.generations.first)
        let now = Date()

        XCTAssertFalse(
            GenerationManager.shouldReconcileListDeletion(
                export,
                freshIDs: [],
                oldestFresh: now.addingTimeInterval(-3_600),
                recentCutoff: now.addingTimeInterval(3_600)
            )
        )
    }
}
