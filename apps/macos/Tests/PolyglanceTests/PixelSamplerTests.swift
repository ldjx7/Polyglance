import AppKit
import XCTest
@testable import Polyglance

final class PixelSamplerTests: XCTestCase {
    func testSamplerMapsBottomLeftRetinaViewPointToTopLeftPhysicalPixel() throws {
        let image = try makeImage(width: 4, height: 4) { x, y in
            x == 1 && y == 1 ? (0x12, 0x34, 0x56) : (0xFF, 0xFF, 0xFF)
        }
        let sampler = try XCTUnwrap(PixelSampler(image: image))

        let sample = try XCTUnwrap(sampler.sample(
            atViewPoint: CGPoint(x: 0.75, y: 1.25),
            viewSize: CGSize(width: 2, height: 2)
        ))

        XCTAssertEqual(sample.coordinate, PixelCoordinate(x: 1, y: 1))
        XCTAssertEqual(sample.red, 0x12)
        XCTAssertEqual(sample.green, 0x34)
        XCTAssertEqual(sample.blue, 0x56)
        XCTAssertEqual(sample.hex, "#123456")
        XCTAssertEqual(sample.text(format: .hex), "#123456")
        XCTAssertEqual(sample.text(format: .rgb), "RGB(18, 52, 86)")
    }

    func testSamplerClampsExactViewEdgesAndRejectsInvalidViewSize() throws {
        let image = try makeImage(width: 2, height: 2) { x, y in
            (UInt8(x * 100), UInt8(y * 100), 0)
        }
        let sampler = try XCTUnwrap(PixelSampler(image: image))

        XCTAssertEqual(
            sampler.sample(atViewPoint: CGPoint(x: 2, y: 0), viewSize: CGSize(width: 2, height: 2))?.coordinate,
            PixelCoordinate(x: 1, y: 1)
        )
        XCTAssertEqual(
            sampler.sample(atViewPoint: .zero, viewSize: CGSize(width: 2, height: 2))?.coordinate,
            PixelCoordinate(x: 0, y: 1)
        )
        XCTAssertNil(sampler.sample(atViewPoint: .zero, viewSize: .zero))
        XCTAssertNil(sampler.sample(
            atViewPoint: CGPoint(x: -0.01, y: 1),
            viewSize: CGSize(width: 2, height: 2)
        ))
    }

    func testMagnifierFrameFlipsAtEdgesAndRemainsInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
        let size = CGSize(width: 184, height: 142)

        let frame = ScreenshotMagnifierView.positionedFrame(
            near: CGPoint(x: 310, y: 230),
            size: size,
            in: bounds
        )

        XCTAssertTrue(bounds.contains(frame))
        XCTAssertLessThan(frame.maxX, 310)
        XCTAssertLessThan(frame.maxY, 230)
    }

    private func makeImage(
        width: Int,
        height: Int,
        color: (_ x: Int, _ topDownY: Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let value = color(x, y)
                    bytes[offset] = value.0
                    bytes[offset + 1] = value.1
                    bytes[offset + 2] = value.2
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
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
