import AppKit
import XCTest
@testable import Polyglance

final class ScreenshotRegionDetectorTests: XCTestCase {
    func testConvertsQuartzWindowFrameToLocalBottomLeftCoordinates() {
        let detector = ScreenshotRegionDetector(
            displayBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            windows: [
                ScreenshotWindowRegion(
                    frame: CGRect(x: 100, y: 100, width: 500, height: 300),
                    ownerPID: 10
                ),
            ],
            elementFrameLookup: { _, _ in nil }
        )

        XCTAssertEqual(
            detector.windowRegion(at: CGPoint(x: 200, y: 600)),
            CGRect(x: 100, y: 500, width: 500, height: 300)
        )
    }

    func testConvertsWindowOnDisplayLeftOfMainScreen() {
        let detector = ScreenshotRegionDetector(
            displayBounds: CGRect(x: -1280, y: 0, width: 1280, height: 800),
            windows: [
                ScreenshotWindowRegion(
                    frame: CGRect(x: -1200, y: 100, width: 500, height: 400),
                    ownerPID: 10
                ),
            ],
            elementFrameLookup: { _, _ in nil }
        )

        XCTAssertEqual(
            detector.windowRegion(at: CGPoint(x: 200, y: 500)),
            CGRect(x: 80, y: 300, width: 500, height: 400)
        )
    }

    func testFrontmostWindowWinsWhenWindowsOverlap() {
        let detector = ScreenshotRegionDetector(
            displayBounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
            windows: [
                ScreenshotWindowRegion(
                    frame: CGRect(x: 200, y: 150, width: 200, height: 200),
                    ownerPID: 20
                ),
                ScreenshotWindowRegion(
                    frame: CGRect(x: 100, y: 100, width: 600, height: 500),
                    ownerPID: 10
                ),
            ],
            elementFrameLookup: { _, _ in nil }
        )

        XCTAssertEqual(
            detector.windowRegion(at: CGPoint(x: 250, y: 500)),
            CGRect(x: 200, y: 450, width: 200, height: 200)
        )
    }

    func testAccessibleElementInsideWindowTakesPriority() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elementFrame = CGRect(x: 220, y: 220, width: 120, height: 60)
        let detector = ScreenshotRegionDetector(
            displayBounds: displayBounds,
            windows: [
                ScreenshotWindowRegion(
                    frame: CGRect(x: 100, y: 100, width: 600, height: 500),
                    ownerPID: 42
                ),
            ],
            elementFrameLookup: { ownerPID, quartzPoint in
                XCTAssertEqual(ownerPID, 42)
                XCTAssertEqual(quartzPoint, CGPoint(x: 250, y: 250))
                return elementFrame
            }
        )

        XCTAssertEqual(
            detector.refinedElementRegion(at: CGPoint(x: 250, y: 550)),
            CGRect(x: 220, y: 520, width: 120, height: 60)
        )
    }

    func testEmptyDesktopFallsBackToEntireDisplay() {
        let detector = ScreenshotRegionDetector(
            displayBounds: CGRect(x: 1200, y: -200, width: 800, height: 600),
            windows: [],
            elementFrameLookup: { _, _ in nil }
        )

        XCTAssertEqual(
            detector.windowRegion(at: CGPoint(x: 400, y: 300)),
            CGRect(x: 0, y: 0, width: 800, height: 600)
        )
    }

    func testNormalAndFloatingWindowsAreCandidateLayersButSystemUIIsNot() {
        XCTAssertTrue(ScreenshotRegionDetector.acceptsWindowLayer(0))
        XCTAssertTrue(ScreenshotRegionDetector.acceptsWindowLayer(3))
        XCTAssertFalse(ScreenshotRegionDetector.acceptsWindowLayer(20))
        XCTAssertFalse(ScreenshotRegionDetector.acceptsWindowLayer(-1))
    }
}
