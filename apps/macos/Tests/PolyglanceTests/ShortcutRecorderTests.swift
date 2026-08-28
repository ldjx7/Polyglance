import XCTest
@testable import Polyglance
import PolyglanceKit

final class ShortcutRecorderTests: XCTestCase {
    func testFormatterShowsRecommendedShortcutAndUnassignedState() {
        XCTAssertEqual(
            ShortcutFormatter.string(
                for: RecordedShortcut(keyCode: 18, modifiers: [.control, .shift])
            ),
            "⌃⇧1"
        )
        XCTAssertEqual(ShortcutFormatter.string(for: nil), "未设置")
    }

    func testFormatterInterpolatesUnknownKeyCode() {
        XCTAssertEqual(
            ShortcutFormatter.string(
                for: RecordedShortcut(keyCode: 127, modifiers: [.control])
            ),
            "⌃Key 127"
        )
    }
}
