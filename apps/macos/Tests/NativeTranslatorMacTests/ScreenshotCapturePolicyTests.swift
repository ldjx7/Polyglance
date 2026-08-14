import XCTest
@testable import NativeTranslatorMac

final class ScreenshotCapturePolicyTests: XCTestCase {
    func testRegularScreenshotIncludesPolyglanceWindows() {
        XCTAssertTrue(ScreenshotCapturePolicy.includesCurrentApplicationWindows)
    }
}
