import AppKit
import ScreenCaptureKit
import XCTest
@testable import Polyglance

final class ScreenshotCapturePolicyTests: XCTestCase {
    func testRegularScreenshotIncludesPolyglanceWindows() {
        XCTAssertTrue(ScreenshotCapturePolicy.includesCurrentApplicationWindows)
    }

    func testMacOS26UsesScreenshotSpecificCaptureBackend() {
        XCTAssertEqual(
            ScreenshotCapturePolicy.captureBackend(macOSMajorVersion: 26),
            .screenshotConfiguration
        )
        XCTAssertEqual(
            ScreenshotCapturePolicy.captureBackend(macOSMajorVersion: 15),
            .streamConfiguration
        )
    }

    @available(macOS 26.0, *)
    func testScreenshotConfigurationPreservesWindowFramingAndShadows() {
        let configuration = ScreenshotCapturePolicy.makeScreenshotConfiguration(
            pixelSize: CGSize(width: 2560, height: 1440)
        )

        XCTAssertEqual(configuration.width, 2560)
        XCTAssertEqual(configuration.height, 1440)
        XCTAssertFalse(configuration.showsCursor)
        XCTAssertFalse(configuration.ignoreShadows)
        XCTAssertFalse(configuration.ignoreClipping)
        XCTAssertEqual(configuration.dynamicRange, .sdr)
    }

    func testMultipleDisplaysUseOneVirtualDesktopForScreenshotAndTranslation() {
        XCTAssertTrue(ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: 2,
            preferredAction: nil
        ))
        XCTAssertTrue(ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: 2,
            preferredAction: .screenTranslation
        ))
    }

    func testSingleDisplayAndDisplayBoundCaptureModesStayOnOneScreen() {
        XCTAssertFalse(ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: 1,
            preferredAction: nil
        ))
        XCTAssertFalse(ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: 2,
            preferredAction: .longScreenshot
        ))
        XCTAssertFalse(ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: 2,
            preferredAction: .screenRecording
        ))
    }

    func testReplacementWindowsKeepTheOverlayUntilTheirFirstFrameIsOnScreen() {
        XCTAssertTrue(ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .pin(
            SelectedScreenshot(image: NSImage(size: CGSize(width: 4, height: 4)),
                               screenFrame: CGRect(x: 0, y: 0, width: 4, height: 4))
        )))
        XCTAssertFalse(ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .copy(
            SelectedScreenshot(image: NSImage(size: CGSize(width: 4, height: 4)),
                               screenFrame: CGRect(x: 0, y: 0, width: 4, height: 4))
        )))
        XCTAssertFalse(ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: nil))
    }
}
