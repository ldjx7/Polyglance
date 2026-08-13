import AppKit
import XCTest
@testable import NativeTranslatorMac

final class LongScreenshotStitcherTests: XCTestCase {
    func testAdjacentFramesAreDeduplicatedUsingTheirVerticalOverlap() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())

        let first = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))
        let second = try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80]))

        XCTAssertEqual(first.disposition, .initial)
        XCTAssertEqual(second.disposition, .appended(direction: .vertical, offset: 2))
        XCTAssertEqual(second.totalHeight, 8)
        XCTAssertEqual(try redRows(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70, 80])
    }

    func testVerticalScrollWithMostlyBlankRowsIsNotMistakenForAnUnchangedFrame() throws {
        var configuration = makeConfiguration()
        configuration.matchThreshold = 0.035
        var stitcher = LongScreenshotStitcher(configuration: configuration)

        _ = try stitcher.append(
            makeRowImage([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 30, 60, 90, 120])
        )
        let result = try stitcher.append(
            makeRowImage([0, 0, 0, 0, 0, 0, 0, 0, 0, 30, 60, 90, 120, 150])
        )

        XCTAssertEqual(result.disposition, .appended(direction: .vertical, offset: 1))
        XCTAssertEqual(result.totalHeight, 15)
    }

    func testHorizontalFramesAreDeduplicatedUsingTheirHorizontalOverlap() throws {
        var stitcher = LongScreenshotStitcher(
            configuration: makeConfiguration(),
            direction: .horizontal
        )

        let first = try stitcher.append(makeColumnImage([10, 20, 30, 40, 50, 60]))
        let second = try stitcher.append(makeColumnImage([30, 40, 50, 60, 70, 80]))

        XCTAssertEqual(first.disposition, .initial)
        XCTAssertEqual(second.disposition, .appended(direction: .horizontal, offset: 2))
        XCTAssertEqual(second.totalWidth, 8)
        XCTAssertEqual(try redColumns(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70, 80])
    }

    func testScrollingUpPrependsNewRowsInsteadOfRejectingTheFrame() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())

        _ = try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80]))
        let result = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))

        XCTAssertEqual(result.disposition, .appended(direction: .vertical, offset: -2))
        XCTAssertEqual(try redRows(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70, 80])
        XCTAssertEqual(stitcher.currentFrameOffset, 0)
    }

    func testScrollingLeftPrependsNewColumns() throws {
        var stitcher = LongScreenshotStitcher(
            configuration: makeConfiguration(),
            direction: .horizontal
        )

        _ = try stitcher.append(makeColumnImage([30, 40, 50, 60, 70, 80]))
        let result = try stitcher.append(makeColumnImage([10, 20, 30, 40, 50, 60]))

        XCTAssertEqual(result.disposition, .appended(direction: .horizontal, offset: -2))
        XCTAssertEqual(try redColumns(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70, 80])
        XCTAssertEqual(stitcher.currentFrameOffset, 0)
    }

    func testReversingScrollWithinAlreadyCapturedContentDoesNotDuplicateRows() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())

        _ = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))
        _ = try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80]))
        let result = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))

        XCTAssertEqual(result.disposition, .unchanged)
        XCTAssertEqual(result.frameCount, 2)
        XCTAssertEqual(try redRows(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70, 80])
    }

    func testDirectionCanChangeBeforeScrollingButNotAfterContentWasExtended() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())
        _ = try stitcher.append(makeColumnImage([10, 20, 30, 40, 50, 60]))

        XCTAssertTrue(stitcher.setDirection(.horizontal))
        _ = try stitcher.append(makeColumnImage([30, 40, 50, 60, 70, 80]))
        XCTAssertFalse(stitcher.setDirection(.vertical))
        XCTAssertEqual(stitcher.direction, .horizontal)
    }

    func testUnchangedFrameDoesNotIncreaseOutputHeight() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())
        let frame = makeRowImage([10, 30, 50, 70, 90, 110])

        _ = try stitcher.append(frame)
        let result = try stitcher.append(frame)

        XCTAssertEqual(result.disposition, .unchanged)
        XCTAssertEqual(result.totalHeight, 6)
        XCTAssertEqual(result.frameCount, 1)
    }

    func testIncrementalPreviewIsBoundedAndPreservesTheWholeLongImage() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())
        _ = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60], width: 8))
        _ = try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80], width: 8))

        let preview = try stitcher.renderPreview(
            maximumPixelWidth: 4,
            maximumPixelHeight: 4
        )

        XCTAssertEqual(preview.width, 4)
        XCTAssertEqual(preview.height, 4)
        XCTAssertEqual(try redRows(in: preview), [10, 30, 50, 70])
    }

    func testSmallOneRowScrollIsRecognized() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())

        _ = try stitcher.append(makeRowImage([5, 25, 45, 65, 85, 105]))
        let result = try stitcher.append(makeRowImage([25, 45, 65, 85, 105, 125]))

        XCTAssertEqual(result.disposition, .appended(direction: .vertical, offset: 1))
        XCTAssertEqual(try redRows(in: stitcher.render()), [5, 25, 45, 65, 85, 105, 125])
    }

    func testRepeatedTextureUsesTheSmallestReliableForwardDisplacement() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())

        _ = try stitcher.append(makeRowImage([20, 80, 20, 80, 140, 200]))
        let result = try stitcher.append(makeRowImage([20, 80, 140, 200, 20, 80]))

        XCTAssertEqual(result.disposition, .appended(direction: .vertical, offset: 2))
        XCTAssertEqual(try redRows(in: stitcher.render()), [20, 80, 20, 80, 140, 200, 20, 80])
    }

    func testMaximumHeightTruncatesTheLastAppendWithoutExceedingTheLimit() throws {
        var configuration = makeConfiguration()
        configuration.maximumOutputHeight = 7
        var stitcher = LongScreenshotStitcher(configuration: configuration)

        _ = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))
        let result = try stitcher.append(makeRowImage([40, 50, 60, 70, 80, 90]))

        XCTAssertEqual(result.disposition, .appended(direction: .vertical, offset: 3))
        XCTAssertEqual(result.limitReached, .outputHeight)
        XCTAssertEqual(result.totalHeight, 7)
        XCTAssertEqual(try redRows(in: stitcher.render()), [10, 20, 30, 40, 50, 60, 70])
    }

    func testUnchangedFramesDoNotConsumeTheLongCaptureFrameLimit() throws {
        var configuration = makeConfiguration()
        configuration.maximumFrameCount = 2
        var stitcher = LongScreenshotStitcher(configuration: configuration)
        let frame = makeRowImage([10, 20, 30, 40, 50, 60])

        _ = try stitcher.append(frame)
        for _ in 0 ..< 5 {
            let result = try stitcher.append(frame)
            XCTAssertEqual(result.disposition, .unchanged)
            XCTAssertEqual(result.frameCount, 1)
            XCTAssertNil(result.limitReached)
        }
        let result = try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80]))

        XCTAssertEqual(result.limitReached, .frameCount)
        XCTAssertEqual(result.frameCount, 2)
    }

    func testMismatchedWidthAndUnrelatedContentAreRejected() throws {
        var stitcher = LongScreenshotStitcher(configuration: makeConfiguration())
        _ = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60], width: 8))

        XCTAssertThrowsError(
            try stitcher.append(makeRowImage([30, 40, 50, 60, 70, 80], width: 7))
        ) { error in
            XCTAssertEqual(error as? LongScreenshotStitchError, .frameDimensionsChanged)
        }
        XCTAssertThrowsError(
            try stitcher.append(makeRowImage([201, 3, 177, 9, 155, 1], width: 8))
        ) { error in
            XCTAssertEqual(error as? LongScreenshotStitchError, .noReliableVerticalOverlap)
        }
    }

    func testPixelAndWorkingMemoryLimitsAreCheckedBeforeAllocatingOutput() {
        var pixelLimited = makeConfiguration()
        pixelLimited.maximumPixelCount = 30
        var pixelStitcher = LongScreenshotStitcher(configuration: pixelLimited)

        XCTAssertThrowsError(try pixelStitcher.append(makeRowImage([1, 2, 3, 4], width: 8))) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .pixelLimitExceeded)
        }

        var memoryLimited = makeConfiguration()
        memoryLimited.maximumWorkingBytes = 100
        var memoryStitcher = LongScreenshotStitcher(configuration: memoryLimited)

        XCTAssertThrowsError(try memoryStitcher.append(makeRowImage([1, 2, 3, 4], width: 8))) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .workingMemoryLimitExceeded)
        }
    }

    func testInitialFrameIsTruncatedAtTheConfiguredMaximumHeight() throws {
        var configuration = makeConfiguration()
        configuration.maximumOutputHeight = 3
        var stitcher = LongScreenshotStitcher(configuration: configuration)

        let result = try stitcher.append(makeRowImage([10, 20, 30, 40, 50, 60]))

        XCTAssertEqual(result.limitReached, .outputHeight)
        XCTAssertEqual(result.totalHeight, 3)
        XCTAssertEqual(try redRows(in: stitcher.render()), [10, 20, 30])
    }

    func testRenderWithoutFramesAndAppendPastFrameLimitAreRejected() throws {
        var configuration = makeConfiguration()
        configuration.maximumFrameCount = 1
        var stitcher = LongScreenshotStitcher(configuration: configuration)

        XCTAssertThrowsError(try stitcher.render()) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .noFrames)
        }
        _ = try stitcher.append(makeRowImage([10, 20, 30, 40]))
        XCTAssertThrowsError(try stitcher.append(makeRowImage([20, 30, 40, 50]))) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .frameLimitExceeded)
        }
    }

    func testInvalidConfigurationAndInsufficientOverlapAreRejected() {
        var invalid = makeConfiguration()
        invalid.captureInterval = 0
        var invalidStitcher = LongScreenshotStitcher(configuration: invalid)
        XCTAssertThrowsError(try invalidStitcher.append(makeRowImage([1, 2, 3, 4]))) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .invalidConfiguration)
        }

        var insufficientOverlap = makeConfiguration()
        insufficientOverlap.minimumOverlapRows = 4
        var overlapStitcher = LongScreenshotStitcher(configuration: insufficientOverlap)
        _ = try? overlapStitcher.append(makeRowImage([10, 20, 30, 40]))
        XCTAssertThrowsError(try overlapStitcher.append(makeRowImage([20, 30, 40, 50]))) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .noReliableVerticalOverlap)
        }
    }

    func testNonRGBAInputIsNormalizedBeforeStitching() throws {
        let grayData = Data([10, 20, 30, 40])
        let grayImage = try XCTUnwrap(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: grayData as CFData)),
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        var configuration = makeConfiguration()
        configuration.minimumOverlapRows = 1
        var stitcher = LongScreenshotStitcher(configuration: configuration)

        let result = try stitcher.append(grayImage)

        XCTAssertEqual(result.totalHeight, 2)
        XCTAssertEqual(try stitcher.render().width, 2)
    }

    func testAllStitchErrorsHaveLocalizedDescriptions() {
        let errors: [LongScreenshotStitchError] = [
            .invalidConfiguration,
            .invalidFrame,
            .frameDimensionsChanged,
            .noReliableVerticalOverlap,
            .pixelLimitExceeded,
            .workingMemoryLimitExceeded,
            .frameLimitExceeded,
            .noFrames,
            .imageCreationFailed,
        ]

        XCTAssertTrue(errors.allSatisfy { !$0.localizedDescription.isEmpty })
        XCTAssertEqual(Set(errors.map(\.localizedDescription)).count, errors.count)
    }

    private func makeConfiguration() -> LongScreenshotConfiguration {
        LongScreenshotConfiguration(
            captureInterval: 0.25,
            maximumFrameCount: 20,
            maximumOutputWidth: 100,
            maximumOutputHeight: 100,
            maximumPixelCount: 10_000,
            maximumWorkingBytes: 1_000_000,
            minimumOverlapRows: 2,
            maximumScrollFraction: 0.8,
            matchThreshold: 0.01
        )
    }
}

private func makeRowImage(_ redValues: [UInt8], width: Int = 8) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(width * redValues.count * 4)
    for red in redValues {
        for column in 0 ..< width {
            bytes.append(red)
            bytes.append(UInt8((Int(red) + column * 13) % 256))
            bytes.append(UInt8((Int(red) + column * 7) % 256))
            bytes.append(255)
        }
    }
    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(
        width: width,
        height: redValues.count,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makeColumnImage(_ redValues: [UInt8], height: Int = 8) -> CGImage {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(height * redValues.count * 4)
    for row in 0 ..< height {
        for red in redValues {
            bytes.append(red)
            bytes.append(UInt8((Int(red) + row * 13) % 256))
            bytes.append(UInt8((Int(red) + row * 7) % 256))
            bytes.append(255)
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
        width: redValues.count,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: redValues.count * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func redRows(in image: CGImage) throws -> [UInt8] {
    let data = try XCTUnwrap(image.dataProvider?.data as Data?)
    return (0 ..< image.height).map { row in
        data[row * image.bytesPerRow]
    }
}


private func redColumns(in image: CGImage) throws -> [UInt8] {
    let data = try XCTUnwrap(image.dataProvider?.data as Data?)
    return (0 ..< image.width).map { column in
        data[column * 4]
    }
}
