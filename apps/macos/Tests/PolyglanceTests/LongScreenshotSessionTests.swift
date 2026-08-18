import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class LongScreenshotSessionTests: XCTestCase {
    func testStartCapturesImmediatelyAndScheduledTicksUseTheSameRegion() async throws {
        let region = makeRegion()
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionRowImage([10, 20, 30, 40]),
            makeSessionRowImage([30, 40, 50, 60]),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: region,
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )

        await session.start()
        await scheduler.fire()

        XCTAssertEqual(session.state, .capturing)
        XCTAssertEqual(capturer.capturedRegions, [region, region])
        XCTAssertEqual(scheduler.scheduledInterval, 0.2)
        let image = try session.finish()
        XCTAssertEqual(image.representations.first?.pixelsHigh, 6)
        XCTAssertEqual(session.state, .finished)
        XCTAssertTrue(scheduler.isInvalidated)
    }

    func testHorizontalSessionStitchesScrollableColumnsWhenLeadingColumnsStayFrozen() async throws {
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionColumnImage([200, 210, 10, 20, 30, 40, 50, 60]),
            makeSessionColumnImage([200, 210, 30, 40, 50, 60, 70, 80]),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )

        await session.start()
        XCTAssertTrue(session.setDirection(.horizontal))
        await scheduler.fire()

        let image = try session.finish()
        XCTAssertEqual(session.direction, .horizontal)
        XCTAssertEqual(image.representations.first?.pixelsWide, 10)
        XCTAssertEqual(image.representations.first?.pixelsHigh, 4)
    }

    func testPauseAndResumeGateScheduledCaptures() async {
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionRowImage([10, 20, 30, 40]),
            makeSessionRowImage([30, 40, 50, 60]),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )

        await session.start()
        session.pause()
        await scheduler.fire()
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(capturer.capturedRegions.count, 1)

        session.resume()
        await scheduler.fire()
        XCTAssertEqual(session.state, .capturing)
        XCTAssertEqual(capturer.capturedRegions.count, 2)
    }

    func testLimitAutomaticallyFinishesOnceAndReturnsAnNSImage() async {
        var configuration = makeSessionConfiguration()
        configuration.maximumFrameCount = 2
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionRowImage([10, 20, 30, 40]),
            makeSessionRowImage([30, 40, 50, 60]),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: configuration
        )
        var completedImages: [NSImage] = []
        session.onFinished = { completedImages.append($0) }

        await session.start()
        await scheduler.fire()
        await scheduler.fire()

        XCTAssertEqual(session.state, .finished)
        XCTAssertEqual(completedImages.count, 1)
        XCTAssertEqual(completedImages.first?.representations.first?.pixelsHigh, 6)
        XCTAssertEqual(capturer.capturedRegions.count, 2)
    }

    func testCancelIsIdempotentAndNeverProducesAnImage() async {
        let capturer = QueueLongScreenshotCapturer(images: [makeSessionRowImage([1, 2, 3, 4])])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )
        var cancelCount = 0
        var finishCount = 0
        session.onCancelled = { cancelCount += 1 }
        session.onFinished = { _ in finishCount += 1 }

        await session.start()
        session.cancel()
        session.cancel()
        await scheduler.fire()

        XCTAssertEqual(session.state, .cancelled)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(capturer.capturedRegions.count, 1)
    }

    func testCaptureFailureStopsTheTimerAndReportsTheError() async {
        let scheduler = ManualLongScreenshotScheduler()
        let capturer = QueueLongScreenshotCapturer(error: TestCaptureError.failed)
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )
        var reportedError: Error?
        session.onFailed = { reportedError = $0 }

        await session.start()

        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(reportedError as? TestCaptureError, .failed)
        XCTAssertTrue(scheduler.isInvalidated)
    }

    func testFinishBeforeStartIsRejectedAndTerminalOperationsAreIdempotent() async throws {
        let capturer = QueueLongScreenshotCapturer(images: [makeSessionRowImage([10, 20, 30, 40])])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )
        var stateChanges: [LongScreenshotSessionState] = []
        session.onStateChanged = { stateChanges.append($0) }

        XCTAssertThrowsError(try session.finish()) {
            XCTAssertEqual($0 as? LongScreenshotStitchError, .noFrames)
        }
        session.pause()
        session.resume()
        await session.start()
        let firstResult = try session.finish()

        await session.start()
        session.pause()
        session.resume()
        session.cancel()
        let secondResult = try session.finish()

        XCTAssertTrue(firstResult === secondResult)
        XCTAssertEqual(stateChanges, [.capturing, .finished])
        XCTAssertEqual(capturer.capturedRegions.count, 1)
    }

    func testUnreliableOverlapIsRecoverableUntilTheFrameLimitCompletesTheSession() async {
        var configuration = makeSessionConfiguration()
        configuration.maximumFrameCount = 3
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionRowImage([10, 20, 30, 40]),
            makeSessionRowImage([201, 3, 177, 9]),
            makeSessionRowImage([199, 1, 173, 7]),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: configuration
        )
        var recoverableErrors: [LongScreenshotStitchError] = []
        session.onRecoverableFrameError = { error in
            if let error = error as? LongScreenshotStitchError {
                recoverableErrors.append(error)
            }
        }

        await session.start()
        await scheduler.fire()
        await scheduler.fire()

        XCTAssertEqual(recoverableErrors, [.noReliableVerticalOverlap, .noReliableVerticalOverlap])
        XCTAssertEqual(session.state, .finished)
        XCTAssertTrue(scheduler.isInvalidated)
    }

    func testFrameDimensionChangeFailsTheSession() async {
        let capturer = QueueLongScreenshotCapturer(images: [
            makeSessionRowImage([10, 20, 30, 40], width: 8),
            makeSessionRowImage([20, 30, 40, 50], width: 7),
        ])
        let scheduler = ManualLongScreenshotScheduler()
        let session = LongScreenshotSession(
            region: makeRegion(),
            captureSource: capturer,
            scheduler: scheduler,
            configuration: makeSessionConfiguration()
        )
        var failure: LongScreenshotStitchError?
        session.onFailed = { failure = $0 as? LongScreenshotStitchError }

        await session.start()
        await scheduler.fire()

        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(failure, .frameDimensionsChanged)
    }

    func testTaskSchedulerFiresPausesResumesAndInvalidates() async throws {
        let scheduler = LongScreenshotTaskScheduler()
        var invocationCount = 0
        var nextFireExpectation: XCTestExpectation?
        scheduler.schedule(every: 0.01) {
            invocationCount += 1
            let expectation = nextFireExpectation
            nextFireExpectation = nil
            expectation?.fulfill()
        }

        let initialFire = expectation(description: "scheduler fires")
        nextFireExpectation = initialFire
        await fulfillment(of: [initialFire], timeout: 1)

        scheduler.pause()
        let countAtPause = invocationCount
        let pausedFire = expectation(description: "paused scheduler stays idle")
        pausedFire.isInverted = true
        nextFireExpectation = pausedFire
        await fulfillment(of: [pausedFire], timeout: 0.05)
        nextFireExpectation = nil
        XCTAssertEqual(invocationCount, countAtPause)

        let resumedFire = expectation(description: "scheduler resumes")
        nextFireExpectation = resumedFire
        scheduler.resume()
        await fulfillment(of: [resumedFire], timeout: 1)
        XCTAssertGreaterThan(invocationCount, countAtPause)

        scheduler.invalidate()
        let countAtInvalidation = invocationCount
        let invalidatedFire = expectation(description: "invalidated scheduler stays idle")
        invalidatedFire.isInverted = true
        nextFireExpectation = invalidatedFire
        await fulfillment(of: [invalidatedFire], timeout: 0.05)
        XCTAssertEqual(invocationCount, countAtInvalidation)
    }

    private func makeRegion() -> LongScreenshotCaptureRegion {
        LongScreenshotCaptureRegion(
            displayID: 7,
            sourceRect: CGRect(x: 20, y: 30, width: 8, height: 4),
            globalRect: CGRect(x: 120, y: 230, width: 8, height: 4),
            pixelWidth: 8,
            pixelHeight: 4
        )
    }

    private func makeSessionConfiguration() -> LongScreenshotConfiguration {
        LongScreenshotConfiguration(
            captureInterval: 0.2,
            maximumFrameCount: 20,
            maximumOutputWidth: 100,
            maximumOutputHeight: 100,
            maximumPixelCount: 10_000,
            maximumWorkingBytes: 1_000_000,
            minimumOverlapRows: 2,
            maximumScrollFraction: 0.75,
            matchThreshold: 0.01
        )
    }
}

@MainActor
private final class QueueLongScreenshotCapturer: LongScreenshotFrameCapturing {
    private var images: [CGImage]
    private let error: Error?
    private(set) var capturedRegions: [LongScreenshotCaptureRegion] = []

    init(images: [CGImage]) {
        self.images = images
        error = nil
    }

    init(error: Error) {
        images = []
        self.error = error
    }

    func capture(region: LongScreenshotCaptureRegion) async throws -> CGImage {
        capturedRegions.append(region)
        if let error {
            throw error
        }
        return images.removeFirst()
    }
}

@MainActor
private final class ManualLongScreenshotScheduler: LongScreenshotScheduling {
    private var operation: (@MainActor () async -> Void)?
    private(set) var scheduledInterval: TimeInterval?
    private(set) var isPaused = false
    private(set) var isInvalidated = false

    func schedule(every interval: TimeInterval, operation: @escaping @MainActor () async -> Void) {
        scheduledInterval = interval
        self.operation = operation
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func invalidate() {
        isInvalidated = true
        operation = nil
    }

    func fire() async {
        guard !isPaused, !isInvalidated else {
            return
        }
        await operation?()
    }
}

private enum TestCaptureError: Error, Equatable {
    case failed
}

private func makeSessionRowImage(_ redValues: [UInt8], width: Int = 8) -> CGImage {
    var bytes: [UInt8] = []
    for red in redValues {
        for column in 0 ..< width {
            bytes += [
                red,
                UInt8((Int(red) + column * 11) % 256),
                UInt8((Int(red) + column * 3) % 256),
                255,
            ]
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
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

private func makeSessionColumnImage(_ redValues: [UInt8], height: Int = 4) -> CGImage {
    var bytes: [UInt8] = []
    for row in 0 ..< height {
        for red in redValues {
            bytes += [
                red,
                UInt8((Int(red) + row * 11) % 256),
                UInt8((Int(red) + row * 3) % 256),
                255,
            ]
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
