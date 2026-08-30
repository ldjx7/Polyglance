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
        // The captured rectangle sits one chrome guard inside the selection so
        // the overlay's border and handles cannot be part of a frame.
        XCTAssertEqual(region.sourceRect, CGRect(x: 4, y: 554, width: 342, height: 192))
        XCTAssertEqual(region.pixelWidth, 684)
        XCTAssertEqual(region.pixelHeight, 384)
    }

    func testTheChromeGuardNeverInvertsASmallSelection() throws {
        let region = try XCTUnwrap(LongScreenshotCaptureRegion.make(
            displayID: 1,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            selection: CGRect(x: 10, y: 10, width: 8, height: 8),
            backingScaleFactor: 2
        ))

        XCTAssertEqual(region.sourceRect.width, 4)
        XCTAssertEqual(region.sourceRect.height, 4)
        XCTAssertEqual(region.pixelWidth, 8)
        XCTAssertEqual(region.pixelHeight, 8)
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
        XCTAssertLessThanOrEqual(configuration.maximumFrameCount, 240)
        XCTAssertGreaterThan(configuration.maximumOutputHeight, 1_000)
        XCTAssertLessThanOrEqual(configuration.maximumOutputHeight, 65_535)
        XCTAssertGreaterThan(configuration.maximumPixelCount, 0)
        XCTAssertGreaterThan(configuration.maximumWorkingBytes, 0)
    }
}
