import AppKit
import XCTest
@testable import NativeTranslatorMac

@MainActor
final class LongScreenshotCoordinatorTests: XCTestCase {
    func testCoordinatorFinishesThenRoutesCopySaveAndPinActions() async throws {
        let frame = makeCoordinatorImage()
        let capturer = CoordinatorCapturer(frame: frame)
        let scheduler = CoordinatorScheduler()
        var copied: NSImage?
        var saved: NSImage?
        var pinned: (NSImage, CGRect)?
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 10, y: 10, width: 4, height: 4),
            globalRect: CGRect(x: 110, y: 210, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )
        let coordinator = LongScreenshotCoordinator(
            captureSource: capturer,
            configuration: .default,
            schedulerFactory: { scheduler },
            outputActions: LongScreenshotOutputActions(
                copy: { copied = $0 },
                save: { saved = $0 },
                pin: { pinned = ($0, $1) }
            ),
            presentsControlPanel: false
        )

        try coordinator.begin(region: region)
        await coordinator.startCapture()
        coordinator.finishCapture()
        try coordinator.performOutput(.copy)
        try coordinator.performOutput(.save)
        try coordinator.performOutput(.pin)

        XCTAssertNotNil(coordinator.outputImage)
        XCTAssertTrue(copied === coordinator.outputImage)
        XCTAssertTrue(saved === coordinator.outputImage)
        XCTAssertTrue(pinned?.0 === coordinator.outputImage)
        XCTAssertEqual(pinned?.1, region.globalRect)
    }

    func testCoordinatorStartsCapturingImmediatelyAndNoScrollProducesTheSelectedFrame() async throws {
        let frame = makeCoordinatorImage()
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: frame),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: .discarding,
            presentsControlPanel: false
        )
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )

        try coordinator.begin(region: region)
        for _ in 0 ..< 20 where coordinator.controlView?.copyButton.isEnabled != true {
            await Task.yield()
        }
        coordinator.finishCapture()

        let output = try XCTUnwrap(coordinator.outputImage)
        XCTAssertEqual(output.representations.first?.pixelsWide, frame.width)
        XCTAssertEqual(output.representations.first?.pixelsHigh, frame.height)
    }

    func testCoordinatorRejectsConcurrentSessionsAndCancelReleasesTheActiveSession() throws {
        let scheduler = CoordinatorScheduler()
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { scheduler },
            outputActions: .discarding,
            presentsControlPanel: false
        )
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )

        try coordinator.begin(region: region)
        XCTAssertThrowsError(try coordinator.begin(region: region)) {
            XCTAssertEqual($0 as? LongScreenshotCoordinatorError, .sessionAlreadyActive)
        }

        coordinator.cancelCapture()
        XCTAssertNoThrow(try coordinator.begin(region: region))
    }

    func testReadySessionAcceptsAnAdjustedVisibleRegionBeforeCaptureStarts() async {
        let capturer = CoordinatorCapturer(frame: makeCoordinatorImage())
        let session = LongScreenshotSession(
            region: LongScreenshotCaptureRegion(
                displayID: 9,
                sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                globalRect: CGRect(x: 100, y: 100, width: 4, height: 4),
                pixelWidth: 4,
                pixelHeight: 4
            ),
            captureSource: capturer,
            scheduler: CoordinatorScheduler()
        )
        let adjusted = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 2, y: 3, width: 6, height: 5),
            globalRect: CGRect(x: 102, y: 96, width: 6, height: 5),
            pixelWidth: 6,
            pixelHeight: 5
        )

        XCTAssertTrue(session.updateRegion(adjusted))
        XCTAssertEqual(session.region, adjusted)
        await session.start()
        XCTAssertFalse(session.updateRegion(adjusted))
        XCTAssertEqual(capturer.lastRegion, adjusted)
    }

    func testSessionPublishesAnIncrementalThumbnailAfterCapturingAFrame() async throws {
        let frame = makeCoordinatorImage()
        let session = LongScreenshotSession(
            region: LongScreenshotCaptureRegion(
                displayID: 9,
                sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
                globalRect: CGRect(x: 100, y: 100, width: 4, height: 4),
                pixelWidth: 4,
                pixelHeight: 4
            ),
            captureSource: CoordinatorCapturer(frame: frame),
            scheduler: CoordinatorScheduler()
        )
        var previews: [LongScreenshotPreview] = []
        session.onPreviewChanged = { previews.append($0) }

        await session.start()

        let preview = try XCTUnwrap(previews.last)
        XCTAssertEqual(preview.frameCount, 1)
        XCTAssertEqual(preview.totalPixelHeight, frame.height)
        XCTAssertEqual(preview.viewportPixelHeight, frame.height)
        XCTAssertGreaterThan(preview.image.size.width, 0)
        XCTAssertGreaterThan(preview.image.size.height, 0)
    }

    func testClosingACompletedSessionPreservesOutputAndAllowsAnotherSession() async throws {
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: .discarding,
            presentsControlPanel: false
        )
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )

        try coordinator.begin(region: region)
        await coordinator.startCapture()
        coordinator.finishCapture()
        let completedImage = try XCTUnwrap(coordinator.outputImage)

        coordinator.cancelCapture()

        XCTAssertTrue(coordinator.outputImage === completedImage)
        XCTAssertNoThrow(try coordinator.begin(region: region))
    }

    func testControlViewDrivesCapturePauseResumeOutputsAndClose() async throws {
        var outputActions: [LongScreenshotOutputAction] = []
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: LongScreenshotOutputActions(
                copy: { _ in outputActions.append(.copy) },
                save: { _ in outputActions.append(.save) },
                pin: { _, _ in outputActions.append(.pin) }
            ),
            presentsControlPanel: false
        )
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )
        try coordinator.begin(region: region)
        let controls = try XCTUnwrap(coordinator.controlView)

        for _ in 0 ..< 10 where !controls.copyButton.isEnabled {
            await Task.yield()
        }
        controls.copyButton.performClick(nil)

        XCTAssertEqual(outputActions, [.copy])
        XCTAssertNil(coordinator.controlView)
        XCTAssertNoThrow(try coordinator.begin(region: region))
    }

    func testPinButtonFinishesCapturePinsAndClosesTheLongScreenshotUI() async throws {
        var outputActions: [LongScreenshotOutputAction] = []
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: LongScreenshotOutputActions(
                copy: { _ in outputActions.append(.copy) },
                save: { _ in outputActions.append(.save) },
                pin: { _, _ in outputActions.append(.pin) }
            ),
            presentsControlPanel: false
        )
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )
        try coordinator.begin(region: region)
        let controls = try XCTUnwrap(coordinator.controlView)
        for _ in 0 ..< 10 where !controls.pinButton.isEnabled {
            await Task.yield()
        }

        controls.pinButton.performClick(nil)

        XCTAssertEqual(outputActions, [.pin])
        XCTAssertNil(coordinator.controlView)
        XCTAssertNotNil(coordinator.outputImage)
    }

    func testFailureAndCancelCallbacksReleaseTheSession() async throws {
        var presentedError: Error?
        var cancelCount = 0
        let region = LongScreenshotCaptureRegion(
            displayID: 9,
            sourceRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            globalRect: CGRect(x: 0, y: 0, width: 4, height: 4),
            pixelWidth: 4,
            pixelHeight: 4
        )
        let coordinator = LongScreenshotCoordinator(
            captureSource: FailingCoordinatorCapturer(),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: .discarding,
            presentsControlPanel: false,
            presentError: { presentedError = $0 }
        )

        try coordinator.begin(region: region)
        await coordinator.startCapture()
        XCTAssertEqual(presentedError as? TestCoordinatorError, .failed)
        XCTAssertNoThrow(try coordinator.begin(region: region))

        coordinator.onCancelled = { cancelCount += 1 }
        coordinator.cancelCapture()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertNoThrow(try coordinator.begin(region: region))
    }

    func testInvalidSelectionAndMissingOutputReportErrors() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        var presentedErrors: [Error] = []
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: .discarding,
            presentsControlPanel: false,
            presentError: { presentedErrors.append($0) }
        )

        XCTAssertThrowsError(try coordinator.begin(
            selection: CGRect(x: screen.frame.maxX + 100, y: screen.frame.maxY + 100, width: 20, height: 20),
            on: screen
        )) {
            XCTAssertEqual($0 as? LongScreenshotCoordinatorError, .invalidSelection)
        }
        XCTAssertThrowsError(try coordinator.performOutput(.copy)) {
            XCTAssertEqual($0 as? LongScreenshotCoordinatorError, .noCompletedImage)
        }

        try coordinator.begin(
            selection: screen.frame.insetBy(dx: 40, dy: 40),
            on: screen
        )
        for _ in 0 ..< 20 where coordinator.controlView?.copyButton.isEnabled != true {
            await Task.yield()
        }
        coordinator.finishCapture()
        XCTAssertNotNil(coordinator.outputImage)
        XCTAssertTrue(presentedErrors.isEmpty)
        coordinator.cancelCapture()
        coordinator.cancelCapture()
    }

    func testSelectionEntryPointInvokesCompletionAndPanelCanBePresented() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let selection = screen.frame.insetBy(dx: 80, dy: 80)
        var completedImage: NSImage?
        let coordinator = LongScreenshotCoordinator(
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage()),
            configuration: .default,
            schedulerFactory: { CoordinatorScheduler() },
            outputActions: .discarding,
            presentsControlPanel: false
        )

        try coordinator.begin(selection: selection, on: screen) {
            completedImage = $0
        }
        for _ in 0 ..< 20 where coordinator.controlView?.copyButton.isEnabled != true {
            await Task.yield()
        }
        coordinator.finishCapture()

        XCTAssertTrue(completedImage === coordinator.outputImage)

        let panel = LongScreenshotControlPanel()
        panel.present(near: selection)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(screen.visibleFrame.intersects(panel.frame))
        panel.orderOut(nil)
    }

    func testCoordinatorErrorsAndDiscardingOutputsAreComplete() throws {
        XCTAssertEqual(
            LongScreenshotCoordinatorError.sessionAlreadyActive.localizedDescription,
            "已有长截图任务正在进行"
        )
        XCTAssertEqual(LongScreenshotCoordinatorError.invalidSelection.localizedDescription, "长截图选区无效")
        XCTAssertEqual(LongScreenshotCoordinatorError.noCompletedImage.localizedDescription, "长截图尚未完成")

        let image = NSImage(size: CGSize(width: 2, height: 2))
        XCTAssertNoThrow(try LongScreenshotOutputActions.discarding.copy(image))
        XCTAssertNoThrow(try LongScreenshotOutputActions.discarding.save(image))
        XCTAssertNoThrow(try LongScreenshotOutputActions.discarding.pin(image, .zero))

        _ = LongScreenshotCoordinator(
            pinWindowManager: PinWindowManager(),
            captureSource: CoordinatorCapturer(frame: makeCoordinatorImage())
        )
        _ = LongScreenshotCoordinator(pinWindowManager: PinWindowManager())
    }
}

@MainActor
private final class CoordinatorCapturer: LongScreenshotFrameCapturing {
    let frame: CGImage
    private(set) var lastRegion: LongScreenshotCaptureRegion?

    init(frame: CGImage) {
        self.frame = frame
    }

    func capture(region: LongScreenshotCaptureRegion) async throws -> CGImage {
        lastRegion = region
        return frame
    }
}

@MainActor
private final class FailingCoordinatorCapturer: LongScreenshotFrameCapturing {
    func capture(region: LongScreenshotCaptureRegion) async throws -> CGImage {
        throw TestCoordinatorError.failed
    }
}

private enum TestCoordinatorError: Error, Equatable {
    case failed
}

@MainActor
private final class CoordinatorScheduler: LongScreenshotScheduling {
    func schedule(every interval: TimeInterval, operation: @escaping @MainActor () async -> Void) {}
    func pause() {}
    func resume() {}
    func invalidate() {}
}

private func makeCoordinatorImage() -> CGImage {
    let width = 4
    let height = 4
    let bytes = Data(repeating: 120, count: width * height * 4)
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: bytes as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
