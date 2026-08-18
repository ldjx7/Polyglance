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
        XCTAssertEqual(region.sourceRect, CGRect(x: 0, y: 550, width: 350, height: 200))
        XCTAssertEqual(region.pixelWidth, 700)
        XCTAssertEqual(region.pixelHeight, 400)
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
