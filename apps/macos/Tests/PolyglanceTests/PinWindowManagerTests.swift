import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class PinWindowManagerTests: XCTestCase {
    func testDefaultManagerPinsImageAndMakesOrdinaryCloseRestorable() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let manager = PinWindowManager()

        manager.pin(
            NSImage(size: CGSize(width: 240, height: 160)),
            sourceFrame: CGRect(
                x: screen.visibleFrame.midX,
                y: screen.visibleFrame.midY,
                width: 40,
                height: 40
            )
        )

        XCTAssertEqual(manager.state.activePinCount, 1)
        XCTAssertFalse(manager.canRestoreMostRecentPin)
        manager.closeAllPins()
        XCTAssertTrue(manager.canRestoreMostRecentPin)
        XCTAssertNotNil(manager.restoreMostRecentPin())
        manager.destroyAllPins()
    }

    func testOrdinaryCloseStoresStateAndRestoreRecreatesPin() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let image = NSImage(size: CGSize(width: 240, height: 160))
        let frame = CGRect(x: 120, y: 140, width: 360, height: 240)
        let panel = manager.createPinWindow(
            image: image,
            initialSize: CGSize(width: 240, height: 160),
            frame: frame,
            opacity: 0.6,
            isLocked: true,
            isAlwaysOnTop: false
        )

        manager.closePin(panel)

        XCTAssertEqual(
            manager.state,
            PinWindowManagerState(
                activePinCount: 0,
                visiblePinCount: 0,
                hiddenPinCount: 0,
                historyCount: 1
            )
        )

        let restored = try XCTUnwrap(manager.restoreMostRecentPin())
        let restoredView = try XCTUnwrap(restored.contentView as? PinContentView)
        XCTAssertEqual(restored.frame, frame)
        XCTAssertEqual(restored.alphaValue, 0.6, accuracy: 0.001)
        XCTAssertTrue(restoredView.isLocked)
        XCTAssertFalse(restoredView.isAlwaysOnTop)
        XCTAssertFalse(restored.styleMask.contains(.resizable))
        XCTAssertEqual(restored.level, .normal)
        XCTAssertTrue(restored.isVisible)
        XCTAssertEqual(manager.state.historyCount, 0)
        manager.destroyAllPins()
    }

    func testDestroyClosesPinWithoutAddingItToHistory() {
        _ = NSApplication.shared
        let manager = makeManager()
        let panel = makePin(using: manager, x: 100)

        manager.destroyPin(panel)

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 0)
        XCTAssertNil(manager.restoreMostRecentPin())
    }

    func testRestoredLockedPinRemainsUnlockableAfterViewLifecycleRefresh() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let panel = manager.createPinWindow(
            image: NSImage(size: CGSize(width: 200, height: 120)),
            initialSize: CGSize(width: 200, height: 120),
            frame: CGRect(x: 100, y: 120, width: 200, height: 120),
            opacity: 1,
            isLocked: true,
            isAlwaysOnTop: true
        )
        let view = try XCTUnwrap(panel.contentView as? PinContentView)
        view.viewDidMoveToWindow()

        performMenuItem("解锁贴图", in: view)

        XCTAssertFalse(view.isLocked)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        manager.destroyAllPins()
    }

    func testCloseAllStoresEveryPinAndCanRestoreThemIndividually() {
        _ = NSApplication.shared
        let manager = makeManager()
        makePin(using: manager, x: 100)
        makePin(using: manager, x: 360)
        makePin(using: manager, x: 620)

        manager.closeAllPins()

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 3)
        XCTAssertNotNil(manager.restoreMostRecentPin())
        XCTAssertNotNil(manager.restoreMostRecentPin())
        XCTAssertNotNil(manager.restoreMostRecentPin())
        XCTAssertNil(manager.restoreMostRecentPin())
        manager.destroyAllPins()
    }

    func testHideAndShowAllKeepPinsManagedWithoutAddingHistory() {
        _ = NSApplication.shared
        let manager = makeManager()
        let first = makePin(using: manager, x: 100)
        let second = makePin(using: manager, x: 360)

        manager.hideAllPins()

        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
        XCTAssertEqual(manager.state.activePinCount, 2)
        XCTAssertEqual(manager.state.hiddenPinCount, 2)
        XCTAssertEqual(manager.state.historyCount, 0)

        manager.showAllPins()

        XCTAssertTrue(first.isVisible)
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(manager.state.visiblePinCount, 2)
        XCTAssertEqual(manager.state.hiddenPinCount, 0)
        manager.destroyAllPins()
    }

    func testHideOthersLeavesSelectedPinVisible() {
        _ = NSApplication.shared
        let manager = makeManager()
        let selected = makePin(using: manager, x: 100)
        let other = makePin(using: manager, x: 360)

        manager.hideOtherPins(than: selected)

        XCTAssertTrue(selected.isVisible)
        XCTAssertFalse(other.isVisible)
        XCTAssertEqual(manager.state.visiblePinCount, 1)
        XCTAssertEqual(manager.state.hiddenPinCount, 1)
        manager.destroyAllPins()
    }

    func testDestroyAllClearsActivePinsButPreservesExistingCloseHistory() {
        _ = NSApplication.shared
        let manager = makeManager()
        let historical = makePin(using: manager, x: 100)
        manager.closePin(historical)
        makePin(using: manager, x: 360)
        makePin(using: manager, x: 620)

        manager.destroyAllPins()

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 1)
        XCTAssertNotNil(manager.restoreMostRecentPin())
        manager.destroyAllPins()
    }

    func testManagerWiresContextMenuActionsAndAvailability() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let first = makePin(using: manager, x: 100)
        let second = makePin(using: manager, x: 360)
        let firstView = try XCTUnwrap(first.contentView as? PinContentView)

        var menu = firstView.makeContextMenu()
        XCTAssertTrue(try menuItem("隐藏其他贴图", in: menu).isEnabled)
        XCTAssertTrue(try menuItem("隐藏全部贴图", in: menu).isEnabled)
        XCTAssertFalse(try menuItem("显示全部贴图", in: menu).isEnabled)
        XCTAssertFalse(try menuItem("恢复最近关闭的贴图", in: menu).isEnabled)

        performMenuItem("隐藏其他贴图", in: firstView)
        XCTAssertTrue(first.isVisible)
        XCTAssertFalse(second.isVisible)

        menu = firstView.makeContextMenu()
        XCTAssertTrue(try menuItem("显示全部贴图", in: menu).isEnabled)
        performMenuItem("显示全部贴图", in: firstView)
        XCTAssertTrue(second.isVisible)

        performMenuItem("关闭贴图", in: firstView)
        XCTAssertEqual(manager.state.historyCount, 1)
        let secondView = try XCTUnwrap(second.contentView as? PinContentView)
        XCTAssertTrue(try menuItem("恢复最近关闭的贴图", in: secondView.makeContextMenu()).isEnabled)
        performMenuItem("恢复最近关闭的贴图", in: secondView)
        XCTAssertEqual(manager.state.activePinCount, 2)
        manager.destroyAllPins()
    }

    func testContextMenuDestroyActionDoesNotEnterHistory() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let panel = makePin(using: manager, x: 100)
        let view = try XCTUnwrap(panel.contentView as? PinContentView)

        performMenuItem("彻底销毁贴图", in: view)

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 0)
    }

    func testUnmanagedWindowsAndNonPanelNotificationsAreIgnored() {
        _ = NSApplication.shared
        let manager = makeManager()
        let unmanaged = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 100, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        manager.closePin(unmanaged)
        manager.destroyPin(unmanaged)
        manager.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: NSObject()))

        XCTAssertEqual(
            manager.state,
            PinWindowManagerState(
                activePinCount: 0,
                visiblePinCount: 0,
                hiddenPinCount: 0,
                historyCount: 0
            )
        )
    }

    func testOrdinaryAndTranslationPinsShareCloseHistoryInActualCloseOrder() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let ordinary = makePin(using: manager, x: 100)
        let translation = manager.createTranslationPinWindow(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "source",
            translatedText: "translation",
            displayMode: .original,
            initialSize: CGSize(width: 320, height: 180),
            frame: CGRect(x: 420, y: 160, width: 480, height: 270),
            opacity: 0.55,
            isLocked: true,
            isAlwaysOnTop: false
        )

        manager.closePin(ordinary)
        manager.closePin(translation)

        XCTAssertEqual(manager.state.historyCount, 2)
        let restoredTranslation = try XCTUnwrap(manager.restoreMostRecentPin())
        let translationView = try XCTUnwrap(
            restoredTranslation.contentView as? OCRTranslationPinContentView
        )
        XCTAssertEqual(translationView.sourceText, "source")
        XCTAssertEqual(translationView.translationText, "translation")
        XCTAssertEqual(translationView.originalImage.size, CGSize(width: 320, height: 180))
        XCTAssertEqual(translationView.mode, .original)
        XCTAssertTrue(translationView.isTranslationOverlayHidden)
        XCTAssertTrue(translationView.isTranslationTextSelectable)
        XCTAssertTrue(translationView.isLocked)
        XCTAssertFalse(translationView.isAlwaysOnTop)
        XCTAssertEqual(restoredTranslation.frame, CGRect(x: 420, y: 160, width: 480, height: 270))
        XCTAssertEqual(restoredTranslation.alphaValue, 0.55, accuracy: 0.001)
        XCTAssertEqual(restoredTranslation.level, .normal)
        XCTAssertFalse(restoredTranslation.styleMask.contains(.resizable))

        let restoredOrdinary = try XCTUnwrap(manager.restoreMostRecentPin())
        XCTAssertTrue(restoredOrdinary.contentView is PinContentView)
        manager.destroyAllPins()
    }

    func testHideAndShowAllManageOrdinaryAndTranslationPinsTogether() {
        _ = NSApplication.shared
        let manager = makeManager()
        let ordinary = makePin(using: manager, x: 100)
        let translation = makeTranslationPin(using: manager, x: 360)

        manager.hideAllPins()

        XCTAssertFalse(ordinary.isVisible)
        XCTAssertFalse(translation.isVisible)
        XCTAssertEqual(manager.state.activePinCount, 2)
        XCTAssertEqual(manager.state.hiddenPinCount, 2)

        manager.showAllPins()

        XCTAssertTrue(ordinary.isVisible)
        XCTAssertTrue(translation.isVisible)
        XCTAssertEqual(manager.state.visiblePinCount, 2)
        manager.destroyAllPins()
    }

    func testTranslationPinOrdinaryCloseIsRestorableButDestroyIsNot() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let closed = makeTranslationPin(using: manager, x: 100)
        let destroyed = makeTranslationPin(using: manager, x: 360)

        manager.destroyPin(destroyed)
        manager.closePin(closed)

        XCTAssertEqual(manager.state.historyCount, 1)
        XCTAssertTrue(try XCTUnwrap(manager.restoreMostRecentPin()).contentView is OCRTranslationPinContentView)
        XCTAssertNil(manager.restoreMostRecentPin())
        manager.destroyAllPins()
    }

    func testDestroyAllRemovesMixedPinsWithoutCreatingHistory() {
        _ = NSApplication.shared
        let manager = makeManager()
        makePin(using: manager, x: 100)
        makeTranslationPin(using: manager, x: 360)

        manager.destroyAllPins()

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 0)
        XCTAssertNil(manager.restoreMostRecentPin())
    }

    func testOCRSelectionPinSharesBatchVisibilityCloseHistoryAndRestore() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let ordinary = makePin(using: manager, x: 100)
        var translatedText: String?
        let ocr = manager.createOCRSelectionPinWindow(
            image: NSImage(size: CGSize(width: 240, height: 120)),
            document: makeOCRDocument(),
            translateHandler: { translatedText = $0 },
            initialSize: CGSize(width: 240, height: 120),
            frame: CGRect(x: 380, y: 120, width: 360, height: 180),
            opacity: 0.7
        )

        XCTAssertEqual(manager.state.activePinCount, 2)
        manager.hideAllPins()
        XCTAssertFalse(ordinary.isVisible)
        XCTAssertFalse(ocr.isVisible)
        manager.showAllPins()
        XCTAssertTrue(ordinary.isVisible)
        XCTAssertTrue(ocr.isVisible)

        manager.closePin(ocr)
        XCTAssertEqual(manager.state.historyCount, 1)
        let restored = try XCTUnwrap(manager.restoreMostRecentPin())
        let restoredView = try XCTUnwrap(restored.contentView as? OCRSelectionResultView)
        XCTAssertEqual(restoredView.canvasView.selectionModel.document.plainText, "Hello")
        XCTAssertEqual(restored.alphaValue, 0.7, accuracy: 0.001)

        restoredView.translateButton.performClick(nil)
        XCTAssertEqual(translatedText, "Hello")
        manager.destroyAllPins()
    }

    func testOCRSelectionPinCloseButtonUsesUnifiedHistoryAndDestroyDoesNot() throws {
        _ = NSApplication.shared
        let manager = makeManager()
        let closed = manager.createOCRSelectionPinWindow(
            image: NSImage(size: CGSize(width: 200, height: 100)),
            document: makeOCRDocument(),
            translateHandler: { _ in },
            initialSize: CGSize(width: 200, height: 100),
            frame: CGRect(x: 100, y: 120, width: 200, height: 100),
            opacity: 1
        )
        let destroyed = manager.createOCRSelectionPinWindow(
            image: NSImage(size: CGSize(width: 200, height: 100)),
            document: makeOCRDocument(),
            translateHandler: { _ in },
            initialSize: CGSize(width: 200, height: 100),
            frame: CGRect(x: 340, y: 120, width: 200, height: 100),
            opacity: 1
        )

        try XCTUnwrap(closed.contentView as? OCRSelectionResultView).closeButton.performClick(nil)
        manager.destroyPin(destroyed)

        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertEqual(manager.state.historyCount, 1)
        XCTAssertTrue(try XCTUnwrap(manager.restoreMostRecentPin()).contentView is OCRSelectionResultView)
        manager.destroyAllPins()
    }

    func testUnifiedOCRSelectionPinExpandsTinySourceToOperableToolbar() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let manager = makeManager()
        let source = CGRect(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY,
            width: 48,
            height: 16
        )

        let panel = try XCTUnwrap(manager.pinOCRSelection(
            image: NSImage(size: CGSize(width: 48, height: 16)),
            document: makeOCRDocument(),
            sourceFrame: source,
            translateHandler: { _ in }
        ))
        let view = try XCTUnwrap(panel.contentView as? OCRSelectionResultView)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.frame.width, 240)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 140)
        XCTAssertTrue(view.contextualActionsHidden)
        XCTAssertTrue(view.bounds.contains(view.contextualActionsFrame))
        manager.destroyAllPins()
    }

    private func makeManager() -> PinWindowManager {
        PinWindowManager(
            historyStore: PinHistoryStore(
                limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 10_000_000)
            )
        )
    }

    @discardableResult
    private func makePin(using manager: PinWindowManager, x: CGFloat) -> NSPanel {
        manager.createPinWindow(
            image: NSImage(size: CGSize(width: 200, height: 120)),
            initialSize: CGSize(width: 200, height: 120),
            frame: CGRect(x: x, y: 120, width: 200, height: 120),
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true
        )
    }

    @discardableResult
    private func makeTranslationPin(using manager: PinWindowManager, x: CGFloat) -> NSPanel {
        manager.createTranslationPinWindow(
            image: NSImage(size: CGSize(width: 200, height: 120)),
            sourceText: "source-\(Int(x))",
            translatedText: "translated-\(Int(x))",
            displayMode: .translation,
            initialSize: CGSize(width: 200, height: 120),
            frame: CGRect(x: x, y: 120, width: 200, height: 120),
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true
        )
    }

    private func makeOCRDocument() -> OCRDocument {
        let item = OCRTextItem(
            id: 0,
            lineIndex: 0,
            indexInLine: 0,
            text: "Hello",
            boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        )
        return OCRDocument(lines: [
            OCRTextLine(
                index: 0,
                text: "Hello",
                boundingBox: item.boundingBox,
                items: [item]
            ),
        ])
    }

    private func findMenuItem(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title {
                return item
            }
            if let submenu = item.submenu, let found = findMenuItem(title, in: submenu) {
                return found
            }
        }
        return nil
    }

    private func menuItem(_ title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(findMenuItem(title, in: menu))
    }

    private func performMenuItem(
        _ title: String,
        in view: PinContentView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = view.makeContextMenu()
        guard let item = findMenuItem(title, in: menu),
              item.isEnabled,
              let action = item.action else {
            XCTFail("Missing enabled menu item: \(title)", file: file, line: line)
            return
        }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), file: file, line: line)
    }
}
