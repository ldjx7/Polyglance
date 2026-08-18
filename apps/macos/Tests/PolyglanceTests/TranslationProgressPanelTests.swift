import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class TranslationProgressPanelTests: XCTestCase {
    func testOCRTranslationProgressPanelIsVisibleWithoutTakingKeyboardFocus() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let panel = OCRTranslationProgressPanel(
            message: "正在翻译截图…",
            sourceFrame: CGRect(x: 300, y: 300, width: 400, height: 200),
            visibleFrame: visibleFrame
        )

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertEqual(panel.message, "正在翻译截图…")
        XCTAssertTrue(visibleFrame.contains(panel.frame))
        XCTAssertEqual(panel.level, .floating)
    }
}
