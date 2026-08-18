import XCTest
@testable import Polyglance

final class ScreenshotCapturePolicyTests: XCTestCase {
    func testRegularScreenshotIncludesPolyglanceWindows() {
        XCTAssertTrue(ScreenshotCapturePolicy.includesCurrentApplicationWindows)
    }
}
