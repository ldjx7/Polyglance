import AppKit
import XCTest
@testable import Polyglance

final class LongScreenshotCaptureRegionTests: XCTestCase {
    func testSelectionIsClippedAndConvertedToDisplayLocalTopLeftCoordinates() throws {
        let region = try XCTUnwrap(LongScreenshotCaptureRegion.make(
            displayID: 42,
            screenFrame: CGRect(x: 100, y: 200, width: 1_000, height: 800),
            selection: CGRect(x: 50, y: 250, width: 400, height: 200),
            backingScaleFactor: 2
        ))

        XCTAssertEqual(region.displayID, 42)
        XCTAssertEqual(region.globalRect, CGRect(x: 100, y: 250, width: 350, height: 200))
        // The captured rectangle expands vertically for motion tracking while
        // recording the insets needed to crop down to the exact user selection.
        XCTAssertEqual(region.sourceRect, CGRect(x: 4, y: 154, width: 342, height: 646))
        XCTAssertEqual(region.pixelWidth, 684)
        XCTAssertEqual(region.pixelHeight, 1292)
        XCTAssertEqual(region.cropTop, 800)
        XCTAssertEqual(region.cropBottom, 108)
        XCTAssertEqual(region.cropLeft, 0)
        XCTAssertEqual(region.cropRight, 0)
        XCTAssertEqual(region.selectionPixelWidth, 684)
        XCTAssertEqual(region.selectionPixelHeight, 384)
    }

    func testTheChromeGuardNeverInvertsASmallSelection() throws {
        let region = try XCTUnwrap(LongScreenshotCaptureRegion.make(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            selection: CGRect(x: 10, y: 10, width: 8, height: 8),
            backingScaleFactor: 2
        ))

        XCTAssertEqual(region.sourceRect.width, 4)
        XCTAssertEqual(region.selectionPixelWidth, 8)
        XCTAssertEqual(region.selectionPixelHeight, 8)
        XCTAssertEqual(region.pixelWidth, 8)
    }

    func testEmptyOrInvalidSelectionsAreRejected() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        XCTAssertNil(LongScreenshotCaptureRegion.make(
            displayID: 1,
            screenFrame: screen,
            selection: CGRect(x: 2_000, y: 2_000, width: 20, height: 20),
            backingScaleFactor: 2
        ))
        XCTAssertNil(LongScreenshotCaptureRegion.make(
            displayID: 1,
            screenFrame: screen,
            selection: CGRect(x: 20, y: 20, width: 0, height: 20),
            backingScaleFactor: 2
        ))
        XCTAssertNil(LongScreenshotCaptureRegion.make(
            displayID: 1,
            screenFrame: screen,
            selection: CGRect(x: 20, y: 20, width: 20, height: 20),
            backingScaleFactor: 0
        ))
    }

    func testDefaultConfigurationProvidesFiniteSafetyLimits() {
        let configuration = LongScreenshotConfiguration.default

        XCTAssertGreaterThan(configuration.captureInterval, 0)
        XCTAssertGreaterThan(configuration.maximumFrameCount, 1)
        XCTAssertLessThanOrEqual(configuration.maximumFrameCount, 100_000)
        XCTAssertGreaterThan(configuration.maximumOutputHeight, 1_000)
        XCTAssertLessThanOrEqual(configuration.maximumOutputHeight, 65_535)
        XCTAssertGreaterThan(configuration.maximumPixelCount, 0)
        XCTAssertGreaterThan(configuration.maximumWorkingBytes, 0)
    }
}
