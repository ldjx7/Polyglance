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
