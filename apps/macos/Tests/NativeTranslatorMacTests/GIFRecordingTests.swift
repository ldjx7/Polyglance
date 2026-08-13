import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import XCTest
@testable import NativeTranslatorMac

final class GIFRecordingTests: XCTestCase {
    func testEncoderWritesAnimatedGIFAndThrottlesFrames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("animation.gif")
        let encoder = try GIFRecordingEncoder(
            outputURL: output,
            limits: GIFRecordingLimits(
                frameRate: 10,
                maxDimension: 64,
                maxDuration: 2,
                maxFrames: 20,
                maxDecodedFrameBytes: 64 * 64 * 4,
                maxTemporaryBytes: 2_000_000
            )
        )
        let red = try makeImage(red: 255, green: 0, blue: 0)
        let blue = try makeImage(red: 0, green: 0, blue: 255)

        XCTAssertTrue(try encoder.append(red, at: CMTime(seconds: 0, preferredTimescale: 600)))
        XCTAssertFalse(try encoder.append(blue, at: CMTime(seconds: 0.04, preferredTimescale: 600)))
        XCTAssertTrue(try encoder.append(blue, at: CMTime(seconds: 0.11, preferredTimescale: 600)))
        try encoder.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual(gif?[kCGImagePropertyGIFLoopCount] as? Int, 0)
    }

    func testEncoderPreservesAcceptedFramePresentationIntervals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("variable-timing.gif")
        let encoder = try GIFRecordingEncoder(
            outputURL: output,
            limits: standardLimits()
        )
        let first = try makeImage(red: 255, green: 0, blue: 0)
        let second = try makeImage(red: 0, green: 0, blue: 255)

        XCTAssertTrue(try encoder.append(first, at: .zero))
        XCTAssertTrue(try encoder.append(
            second,
            at: CMTime(seconds: 1, preferredTimescale: 600)
        ))
        try encoder.finish()

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(frameDelay(at: 0, in: source), 1, accuracy: 0.01)
        XCTAssertEqual(frameDelay(at: 1, in: source), 0.1, accuracy: 0.01)
    }

    func testEncoderRejectsOversizedFrameWithoutLeavingOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("oversized.gif")
        let encoder = try GIFRecordingEncoder(
            outputURL: output,
            limits: GIFRecordingLimits(
                frameRate: 10,
                maxDimension: 1,
                maxDuration: 2,
                maxFrames: 20,
                maxDecodedFrameBytes: 4,
                maxTemporaryBytes: 1_000
            )
        )

        XCTAssertThrowsError(
            try encoder.append(
                makeImage(red: 0, green: 0, blue: 0),
                at: .zero
            )
        ) { error in
            XCTAssertEqual(error as? GIFRecordingError, .frameTooLarge)
        }
        encoder.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testEncoderEnforcesDurationAndFrameLimits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeImage(red: 0, green: 255, blue: 0)
        let durationEncoder = try GIFRecordingEncoder(
            outputURL: root.appendingPathComponent("duration.gif"),
            limits: GIFRecordingLimits(
                frameRate: 10,
                maxDimension: 64,
                maxDuration: 0.5,
                maxFrames: 10,
                maxDecodedFrameBytes: 64 * 64 * 4,
                maxTemporaryBytes: 2_000_000
            )
        )
        XCTAssertTrue(try durationEncoder.append(image, at: .zero))
        XCTAssertThrowsError(
            try durationEncoder.append(image, at: CMTime(seconds: 0.6, preferredTimescale: 600))
        ) { error in
            XCTAssertEqual(error as? GIFRecordingError, .durationLimitExceeded)
        }
        durationEncoder.cancel()

        let frameEncoder = try GIFRecordingEncoder(
            outputURL: root.appendingPathComponent("frames.gif"),
            limits: GIFRecordingLimits(
                frameRate: 10,
                maxDimension: 64,
                maxDuration: 2,
                maxFrames: 1,
                maxDecodedFrameBytes: 64 * 64 * 4,
                maxTemporaryBytes: 2_000_000
            )
        )
        XCTAssertTrue(try frameEncoder.append(image, at: .zero))
        XCTAssertThrowsError(
            try frameEncoder.append(image, at: CMTime(seconds: 0.11, preferredTimescale: 600))
        ) { error in
            XCTAssertEqual(error as? GIFRecordingError, .frameLimitExceeded)
        }
        frameEncoder.cancel()
    }

    func testEncoderRejectsInvalidAndReverseTimestamps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = try GIFRecordingEncoder(
            outputURL: root.appendingPathComponent("timestamps.gif"),
            limits: standardLimits()
        )
        let image = try makeImage(red: 1, green: 2, blue: 3)

        XCTAssertThrowsError(try encoder.append(image, at: .invalid)) { error in
            XCTAssertEqual(error as? GIFRecordingError, .invalidTimestamp)
        }
        XCTAssertTrue(try encoder.append(
            image,
            at: CMTime(seconds: 1, preferredTimescale: 600)
        ))
        XCTAssertThrowsError(try encoder.append(
            image,
            at: CMTime(seconds: 0.5, preferredTimescale: 600)
        )) { error in
            XCTAssertEqual(error as? GIFRecordingError, .invalidTimestamp)
        }
        encoder.cancel()
    }

    func testFinishWithoutFramesAndTemporaryStorageLimitAreExplicit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try GIFRecordingEncoder(
            outputURL: root.appendingPathComponent("empty.gif"),
            limits: standardLimits()
        )
        XCTAssertThrowsError(try empty.finish()) { error in
            XCTAssertEqual(error as? GIFRecordingError, .noFrames)
        }
        empty.cancel()

        let limited = try GIFRecordingEncoder(
            outputURL: root.appendingPathComponent("storage.gif"),
            limits: GIFRecordingLimits(
                frameRate: 10,
                maxDimension: 64,
                maxDuration: 2,
                maxFrames: 20,
                maxDecodedFrameBytes: 64 * 64 * 4,
                maxTemporaryBytes: 1
            )
        )
        let noisy = try makeImage(width: 64, height: 64)
        XCTAssertTrue(try limited.append(noisy, at: .zero))
        XCTAssertThrowsError(try limited.append(
            noisy,
            at: CMTime(seconds: 0.11, preferredTimescale: 600)
        )) { error in
            XCTAssertEqual(error as? GIFRecordingError, .temporaryStorageLimitExceeded)
        }
        limited.cancel()
    }

    func testInitializerReportsAnUnusableDestinationParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIFRecordingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regularFile = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: regularFile)

        XCTAssertThrowsError(try GIFRecordingEncoder(
            outputURL: regularFile.appendingPathComponent("clip.gif"),
            limits: standardLimits()
        )) { error in
            guard case .temporaryDirectoryCreationFailed = error as? GIFRecordingError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func standardLimits() -> GIFRecordingLimits {
        GIFRecordingLimits(
            frameRate: 10,
            maxDimension: 64,
            maxDuration: 2,
            maxFrames: 20,
            maxDecodedFrameBytes: 64 * 64 * 4,
            maxTemporaryBytes: 2_000_000
        )
    }

    private func frameDelay(at index: Int, in source: CGImageSource) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? 0
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in pixels.indices {
            pixels[index] = UInt8(truncatingIfNeeded: index &* 31)
        }
        let context = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        return try XCTUnwrap(context?.makeImage())
    }

    private func makeImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [
            red, green, blue, 255,
            red, green, blue, 255,
            red, green, blue, 255,
            red, green, blue, 255,
        ]
        let context = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 8,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        return try XCTUnwrap(context?.makeImage())
    }
}
