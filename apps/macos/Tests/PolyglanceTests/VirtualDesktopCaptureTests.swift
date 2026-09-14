import CoreGraphics
import XCTest
@testable import Polyglance

@MainActor
final class VirtualDesktopCaptureTests: XCTestCase {
    func testUnionFrameIncludesDisplaysOnBothSidesOfTheOrigin() {
        let frame = VirtualDesktopCapture.unionFrame([
            CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
        ])

        XCTAssertEqual(frame, CGRect(x: -1920, y: 0, width: 4480, height: 1440))
    }

    func testLocalSelectionMapsAcrossTheDisplaySeam() {
        let captureFrame = CGRect(x: -1920, y: -900, width: 4480, height: 2340)

        let global = VirtualDesktopCapture.globalFrame(
            for: CGRect(x: 1800, y: 800, width: 400, height: 300),
            in: captureFrame
        )

        XCTAssertEqual(global, CGRect(x: -120, y: -100, width: 400, height: 300))
    }

    func testCompositionProducesOneBitmapForTheWholeDesktop() throws {
        let first = try makeImage(width: 10, height: 10)
        let second = try makeImage(width: 10, height: 10)

        let result = try XCTUnwrap(VirtualDesktopCapture.compose([
            .init(image: first, frame: CGRect(x: -10, y: 0, width: 10, height: 10), backingScaleFactor: 1),
            .init(image: second, frame: CGRect(x: 0, y: 0, width: 10, height: 10), backingScaleFactor: 1),
        ]))

        XCTAssertEqual(result.frame, CGRect(x: -10, y: 0, width: 20, height: 10))
        XCTAssertEqual(result.image.width, 20)
        XCTAssertEqual(result.image.height, 10)
    }

    func testCropSingleSegmentWithoutComposition() throws {
        let first = try makeImage(width: 20, height: 20)
        let captureFrame = CGRect(x: 0, y: 0, width: 20, height: 20)
        let cropped = try XCTUnwrap(VirtualDesktopCapture.crop(
            from: [
                .init(image: first, frame: captureFrame, backingScaleFactor: 1),
            ],
            captureFrame: captureFrame,
            selection: CGRect(x: 2, y: 2, width: 8, height: 8)
        ))
        XCTAssertEqual(cropped.width, 8)
        XCTAssertEqual(cropped.height, 8)
    }

    func testCropCrossSegmentStitchesOnlySelectedRegion() throws {
        let first = try makeImage(width: 20, height: 20)
        let second = try makeImage(width: 20, height: 20)
        let segments = [
            VirtualDesktopCapture.Segment(image: first, frame: CGRect(x: -20, y: 0, width: 20, height: 20), backingScaleFactor: 1),
            VirtualDesktopCapture.Segment(image: second, frame: CGRect(x: 0, y: 0, width: 20, height: 20), backingScaleFactor: 1),
        ]
        let captureFrame = CGRect(x: -20, y: 0, width: 40, height: 20)
        // Selection spanning from x=15 to x=25 in local captureFrame coords (-5 to +5 in global coords)
        let cropped = try XCTUnwrap(VirtualDesktopCapture.crop(
            from: segments,
            captureFrame: captureFrame,
            selection: CGRect(x: 15, y: 5, width: 10, height: 10)
        ))
        XCTAssertEqual(cropped.width, 10)
        XCTAssertEqual(cropped.height, 10)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let data = Data(repeating: 0xFF, count: width * height * 4) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}
