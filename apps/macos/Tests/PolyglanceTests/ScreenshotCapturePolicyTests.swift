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

    func testScreenshotConfigurationPreservesWindowFramingAndShadows() {
        guard let configuration = ScreenshotCapturePolicy.makeScreenshotConfiguration(
            pixelSize: CGSize(width: 2560, height: 1440)
        ) else {
            return
        }

        XCTAssertEqual(configuration.value(forKey: "width") as? Int, 2560)
        XCTAssertEqual(configuration.value(forKey: "height") as? Int, 1440)
        XCTAssertEqual(configuration.value(forKey: "showsCursor") as? Bool, false)
        XCTAssertEqual(configuration.value(forKey: "ignoreShadows") as? Bool, false)
        XCTAssertEqual(configuration.value(forKey: "ignoreClipping") as? Bool, false)
        XCTAssertEqual(configuration.value(forKey: "dynamicRange") as? Int, 0)
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
