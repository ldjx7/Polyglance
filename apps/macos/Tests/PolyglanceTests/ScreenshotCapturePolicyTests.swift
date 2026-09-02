import AppKit
import XCTest
@testable import Polyglance

final class ScreenshotCapturePolicyTests: XCTestCase {
    func testRegularScreenshotIncludesPolyglanceWindows() {
        XCTAssertTrue(ScreenshotCapturePolicy.includesCurrentApplicationWindows)
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
