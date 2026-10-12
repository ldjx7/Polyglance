import AppKit
import XCTest
@testable import Polyglance

final class ClipboardSelectionInteractionTests: XCTestCase {
    func testMouseReturnAndCommandShortcutsFollowTheDefaultAction() {
        for flags in [NSEvent.ModifierFlags(), .command] {
            XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: flags, automaticPaste: false), .copy)
            XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: flags, automaticPaste: true), .paste)
        }
        XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: .option, automaticPaste: false), .paste)
        XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: .option, automaticPaste: true), .copy)
    }

    func testPlainTextShortcutChangesWithAutomaticPasteAndRejectsUnmappedChords() {
        XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: [.option, .shift], automaticPaste: false), .pastePlainText)
        XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: [.command, .shift], automaticPaste: true), .pastePlainText)
        XCTAssertNil(ClipboardSelectionAction.resolve(modifiers: [.command, .shift], automaticPaste: false))
        XCTAssertNil(ClipboardSelectionAction.resolve(modifiers: [.option, .shift], automaticPaste: true))
        for automaticPaste in [false, true] {
            XCTAssertNil(ClipboardSelectionAction.resolve(modifiers: [.control], automaticPaste: automaticPaste))
            XCTAssertNil(ClipboardSelectionAction.resolve(modifiers: [.option, .command], automaticPaste: automaticPaste))
        }
        XCTAssertEqual(ClipboardSelectionAction.resolve(modifiers: [.option, .capsLock], automaticPaste: true), .copy)
    }

    func testFirstReleaseOnlyOpensThePopup() {
        var cycle = ClipboardCycleState()
        cycle.begin(keyCode: 8, modifiers: [.command, .shift])
        XCTAssertFalse(cycle.release(modifiers: .command))
        XCTAssertTrue(cycle.isActive)
        XCTAssertFalse(cycle.release(modifiers: []))
        XCTAssertFalse(cycle.isActive)
        XCTAssertFalse(cycle.advance())
    }

    func testCyclingCommitsOnlyAfterAllModifiersAreReleasedAndOnlyOnce() {
        for remaining in [NSEvent.ModifierFlags.command, .shift, .option] {
            var cycle = ClipboardCycleState()
            cycle.begin(keyCode: 8, modifiers: [.command, .shift])
            XCTAssertTrue(cycle.advance())
            XCTAssertFalse(cycle.release(modifiers: remaining))
            XCTAssertTrue(cycle.release(modifiers: []))
            XCTAssertFalse(cycle.release(modifiers: []))
        }
    }

    func testCancellationAndPlainKeysNeverCommitOnRelease() {
        var cycle = ClipboardCycleState()
        cycle.begin(keyCode: 8, modifiers: .command)
        XCTAssertTrue(cycle.advance())
        cycle.cancel()
        XCTAssertFalse(cycle.release(modifiers: []))
        cycle.begin(keyCode: 8, modifiers: [])
        XCTAssertFalse(cycle.advance())
        XCTAssertFalse(cycle.release(modifiers: []))
    }
}
