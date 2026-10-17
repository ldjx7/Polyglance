import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class ClipboardQuickLayoutTests: XCTestCase {
    func testPreviewOpensToTheRightWithoutMovingTheList() {
        let layout = ClipboardQuickLayout()
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let original = NSRect(x: 200, y: 200, width: 450, height: 520)
        let expanded = layout.frame(showingPreview: true, current: original, screen: screen)
        XCTAssertFalse(layout.previewOnLeft)
        XCTAssertEqual(expanded.minX, original.minX)
        XCTAssertEqual(expanded.width, 770)
        XCTAssertEqual(layout.frame(showingPreview: false, current: expanded, screen: screen), original)
    }

    func testPreviewUsesLeftSpaceAtTheRightEdgeAndRestoresListPosition() {
        let layout = ClipboardQuickLayout()
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let original = NSRect(x: -480, y: 200, width: 450, height: 520)
        let expanded = layout.frame(showingPreview: true, current: original, screen: screen)
        XCTAssertTrue(layout.previewOnLeft)
        XCTAssertEqual(expanded.minX + layout.previewWidth, original.minX)
        XCTAssertTrue(screen.contains(expanded))
        XCTAssertEqual(layout.frame(showingPreview: false, current: expanded, screen: screen), original)
    }

    func testPreviewFitsSmallScreenAndDoesNotDriftOnRepeatedUpdates() {
        let layout = ClipboardQuickLayout()
        let screen = NSRect(x: 100, y: 50, width: 700, height: 600)
        let original = NSRect(x: 200, y: 100, width: 450, height: 520)
        let expanded = layout.frame(showingPreview: true, current: original, screen: screen)
        XCTAssertEqual(layout.previewWidth, 250)
        XCTAssertTrue(screen.contains(expanded))
        XCTAssertEqual(layout.frame(showingPreview: true, current: expanded, screen: screen), expanded)
        let collapsed = layout.frame(showingPreview: false, current: expanded, screen: screen)
        XCTAssertEqual(collapsed.width, 450)
        XCTAssertTrue(screen.contains(collapsed))
    }
}
