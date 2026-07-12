// MaskEditorExportTests.swift
// FantasiaTests
// Verifies MaskEditorView's mask-export math (PKDrawing.image(from:scale:) → MediaPrepService.
// alphaMaskPNG) places a painted stroke at the correctly SCALED location in the exported mask,
// independent of the canvas/source size ratio. MaskEditorView pins the PencilKit canvas's own
// `.bounds` at a fixed size regardless of pinch-zoom (only an ancestor UIView's transform changes
// with zoom — PencilKit always records/exports strokes in that fixed local coordinate space), so
// exercising the export step across several canvas/source size ratios is what "stays 1:1 with the
// pixel regardless of zoom" reduces to for this step. This doesn't simulate live touch/zoom
// gestures (out of unit-test reach) — it proves the math those gestures ultimately feed into.

import XCTest
import PencilKit
@testable import Fantasia

final class MaskEditorExportTests: XCTestCase {

    /// Builds a short PKStroke centered at `center` (in the canvas's local coordinate space).
    private func makeStroke(center: CGPoint, width: CGFloat) -> PKStroke {
        let points = [
            PKStrokePoint(location: CGPoint(x: center.x - 6, y: center.y),
                          timeOffset: 0, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: center.x + 6, y: center.y),
                          timeOffset: 0.05, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: .magenta), path: path)
    }

    /// Samples the alpha channel at a single pixel via a fresh 1x1 bitmap context — robust to
    /// whatever native pixel format the PNG decoded to (avoids hand-parsing raw bytes).
    private func alphaValue(of cgImage: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 255 }
        // CGContext origin is bottom-left; flip the requested top-left (x, y) pixel into place so
        // it lands exactly on the context's single pixel.
        let flippedY = cgImage.height - 1 - y
        context.draw(cgImage, in: CGRect(x: -x, y: -flippedY, width: cgImage.width, height: cgImage.height))
        return pixel[3]
    }

    /// Mirrors MaskEditorView.submit()'s export math exactly: a stroke painted at a given
    /// fractional position of the (fixed) canvas must land at that SAME fractional position of
    /// the exported source-pixel-sized mask, for any canvas/source size ratio — i.e. for any
    /// "effective zoom" the canvas happened to be fitted at when its bounds were pinned.
    func testStrokeExportsToCorrectlyScaledLocation() {
        let cases: [(canvas: CGSize, source: CGSize)] = [
            (CGSize(width: 300, height: 300), CGSize(width: 1024, height: 1024)),
            (CGSize(width: 150, height: 150), CGSize(width: 1024, height: 1024)),
            (CGSize(width: 300, height: 300), CGSize(width: 2048, height: 2048)),
            (CGSize(width: 320, height: 568), CGSize(width: 1440, height: 2556)), // non-square, matches a real 9:16 photo
        ]

        for testCase in cases {
            let canvasSize = testCase.canvas
            let sourceSize = testCase.source

            // Off-center on purpose — a flipped axis or off-by-half bug would land elsewhere.
            let strokeCenter = CGPoint(x: canvasSize.width * 0.25, y: canvasSize.height * 0.7)
            let strokeWidth = max(canvasSize.width * 0.08, 6)
            let drawing = PKDrawing(strokes: [makeStroke(center: strokeCenter, width: strokeWidth)])

            // Exact same math as MaskEditorView.submit().
            let scale = sourceSize.width / canvasSize.width
            let strokeImage = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
            let maskData = MediaPrepService.alphaMaskPNG(strokeImage: strokeImage, sourcePixelSize: sourceSize)

            guard let maskImage = UIImage(data: maskData), let cgImage = maskImage.cgImage else {
                XCTFail("Failed to decode exported mask for canvas \(canvasSize) / source \(sourceSize)")
                continue
            }
            XCTAssertEqual(cgImage.width, Int(sourceSize.width), "Mask width must exactly match source pixel size")
            XCTAssertEqual(cgImage.height, Int(sourceSize.height), "Mask height must exactly match source pixel size")

            let expectedX = Int(strokeCenter.x * scale)
            let expectedY = Int(strokeCenter.y * scale)

            let alphaAtStroke = alphaValue(of: cgImage, x: expectedX, y: expectedY)
            let alphaFarCorner = alphaValue(of: cgImage, x: cgImage.width - 3, y: 3)

            XCTAssertLessThan(
                alphaAtStroke, 128,
                "canvas \(canvasSize) / source \(sourceSize): painted region must be TRANSPARENT (edit) at the scaled stroke location, got alpha=\(alphaAtStroke)"
            )
            XCTAssertGreaterThan(
                alphaFarCorner, 128,
                "canvas \(canvasSize) / source \(sourceSize): untouched region must stay OPAQUE (preserve), got alpha=\(alphaFarCorner)"
            )
        }
    }

    /// prepareSourceImage's returned image's REAL pixel buffer (not just its .size in points)
    /// must exactly match the computed downsized dimensions — UIGraphicsImageRenderer(size:)
    /// defaults to the device's screen scale (2x/3x) unless told otherwise, which would leave
    /// the actual uploaded photo 2-3x larger than the mask exported for the same source and
    /// blow past gpt-image-2's max-dimension constraint this function exists to enforce.
    func testPrepareSourceImageProducesExactPixelDimensions() {
        // A source deliberately larger than maxDimension so the downsize path is exercised.
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 4000)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        }
        let prepared = MaskEditorView.prepareSourceImage(big, maxDimension: 2048)

        // Mirrors the function's own downsize math to know the expected result independent of
        // its internals.
        let factor = 2048.0 / 4000.0
        let expectedW = (3000.0 * factor / 16).rounded(.down) * 16
        let expectedH = (4000.0 * factor / 16).rounded(.down) * 16

        XCTAssertEqual(prepared.size.width, expectedW, "prepared.size (points) should match the computed downsize")
        XCTAssertEqual(prepared.size.height, expectedH)
        guard let cgImage = prepared.cgImage else {
            XCTFail("prepareSourceImage returned no cgImage")
            return
        }
        XCTAssertEqual(cgImage.width, Int(expectedW), "REAL pixel width must equal .size, not .size * screen scale")
        XCTAssertEqual(cgImage.height, Int(expectedH), "REAL pixel height must equal .size, not .size * screen scale")
        XCTAssertEqual(prepared.scale, 1, "scale must be 1 so .size and the real pixel buffer agree")
    }

    /// Same stroke position (as a FRACTION of canvas size) at two very different canvas/source
    /// ratios must land at the same FRACTIONAL position in both exported masks — this is the
    /// direct "zooming in and drawing doesn't shift where the edit lands" assertion.
    func testSameRelativePositionAcrossDifferentEffectiveZoom() {
        let smallCanvas = CGSize(width: 120, height: 120)   // stands in for a more-zoomed-in fit
        let largeCanvas = CGSize(width: 400, height: 400)   // stands in for zoomed-out (fit-to-screen)
        let source = CGSize(width: 1024, height: 1024)

        let fractionalCenter = CGPoint(x: 0.6, y: 0.35)

        func exportedStrokeFraction(canvasSize: CGSize) -> CGPoint {
            let center = CGPoint(x: canvasSize.width * fractionalCenter.x, y: canvasSize.height * fractionalCenter.y)
            let width = max(canvasSize.width * 0.06, 5)
            let drawing = PKDrawing(strokes: [makeStroke(center: center, width: width)])
            let scale = source.width / canvasSize.width
            let strokeImage = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
            let maskData = MediaPrepService.alphaMaskPNG(strokeImage: strokeImage, sourcePixelSize: source)
            guard let cgImage = UIImage(data: maskData)?.cgImage else {
                XCTFail("Failed to decode exported mask")
                return .zero
            }
            // Scan for the darkest-alpha (most transparent) pixel's location as a fraction of the image.
            var best: (x: Int, y: Int, alpha: UInt8) = (0, 0, 255)
            let step = 4
            for y in stride(from: 0, to: cgImage.height, by: step) {
                for x in stride(from: 0, to: cgImage.width, by: step) {
                    let a = alphaValue(of: cgImage, x: x, y: y)
                    if a < best.alpha { best = (x, y, a) }
                }
            }
            return CGPoint(x: CGFloat(best.x) / CGFloat(cgImage.width), y: CGFloat(best.y) / CGFloat(cgImage.height))
        }

        let fractionFromSmall = exportedStrokeFraction(canvasSize: smallCanvas)
        let fractionFromLarge = exportedStrokeFraction(canvasSize: largeCanvas)

        XCTAssertEqual(fractionFromSmall.x, fractionFromLarge.x, accuracy: 0.05,
                        "Same relative stroke position should land at the same relative X regardless of canvas/zoom ratio")
        XCTAssertEqual(fractionFromSmall.y, fractionFromLarge.y, accuracy: 0.05,
                        "Same relative stroke position should land at the same relative Y regardless of canvas/zoom ratio")
    }
}
