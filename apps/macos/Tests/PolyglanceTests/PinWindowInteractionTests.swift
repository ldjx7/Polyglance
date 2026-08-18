import AppKit
import CoreGraphics
import XCTest
@testable import Polyglance

@MainActor
final class PinWindowInteractionTests: XCTestCase {
    func testOrdinaryScrollZoomsAroundPointerAnchor() {
        let (panel, view) = makePinnedWindow()
        let oldFrame = panel.frame
        let anchor = CGPoint(x: 50, y: 30)

        view.applyScroll(deltaY: 1, modifiers: [], anchorInWindow: anchor)

        let newFrame = panel.frame
        XCTAssertGreaterThan(newFrame.width, oldFrame.width)
        assertAnchorIsStable(oldFrame: oldFrame, newFrame: newFrame, anchor: anchor)
        panel.close()
    }

    func testOptionScrollUsesFinerZoomStep() {
        let (normalPanel, normalView) = makePinnedWindow(origin: CGPoint(x: 100, y: 100))
        let (precisePanel, preciseView) = makePinnedWindow(origin: CGPoint(x: 400, y: 100))
        let anchor = CGPoint(x: 100, y: 60)

        normalView.applyScroll(deltaY: 1, modifiers: [], anchorInWindow: anchor)
        preciseView.applyScroll(deltaY: 1, modifiers: [.option], anchorInWindow: anchor)

        XCTAssertGreaterThan(precisePanel.frame.width, 200)
        XCTAssertLessThan(precisePanel.frame.width, normalPanel.frame.width)
        normalPanel.close()
        precisePanel.close()
    }

    func testCommandScrollChangesOnlyOpacityAndClampsIt() {
        let (panel, view) = makePinnedWindow()
        panel.alphaValue = 0.5
        let originalFrame = panel.frame

        view.applyScroll(
            deltaY: 1,
            modifiers: [.command],
            anchorInWindow: CGPoint(x: 80, y: 40)
        )

        XCTAssertGreaterThan(panel.alphaValue, 0.5)
        XCTAssertEqual(panel.frame, originalFrame)

        view.applyScroll(deltaY: -1_000, modifiers: [.command], anchorInWindow: .zero)
        XCTAssertEqual(panel.alphaValue, 0.1, accuracy: 0.001)
        view.applyScroll(deltaY: 1_000, modifiers: [.command], anchorInWindow: .zero)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
        panel.close()
    }

    func testScrollWheelEventRoutesToZoomBehavior() {
        let (panel, view) = makePinnedWindow()

        view.scrollWheel(with: scrollEvent(deltaY: 1, units: .line))

        XCTAssertGreaterThan(panel.frame.width, 200)
        panel.close()
    }

    func testPrecisePixelScrollIsNormalizedToOneLineForOrdinaryZoom() {
        let (linePanel, lineView) = makePinnedWindow(origin: CGPoint(x: 100, y: 100))
        let (pixelPanel, pixelView) = makePinnedWindow(origin: CGPoint(x: 400, y: 100))

        lineView.scrollWheel(with: scrollEvent(deltaY: 1, units: .line))
        let pixelEvent = scrollEvent(deltaY: 10, units: .pixel)
        XCTAssertTrue(pixelEvent.hasPreciseScrollingDeltas)
        pixelView.scrollWheel(with: pixelEvent)

        XCTAssertEqual(pixelPanel.frame.width, linePanel.frame.width, accuracy: 1)
        XCTAssertLessThan(pixelPanel.frame.width, 230)
        linePanel.close()
        pixelPanel.close()
    }

    func testPrecisePixelScrollIsNormalizedForOptionFineZoom() {
        let (linePanel, lineView) = makePinnedWindow(origin: CGPoint(x: 100, y: 100))
        let (pixelPanel, pixelView) = makePinnedWindow(origin: CGPoint(x: 400, y: 100))

        lineView.scrollWheel(with: scrollEvent(deltaY: 1, units: .line, modifiers: [.option]))
        pixelView.scrollWheel(with: scrollEvent(deltaY: 10, units: .pixel, modifiers: [.option]))

        XCTAssertEqual(pixelPanel.frame.width, linePanel.frame.width, accuracy: 1)
        XCTAssertLessThan(pixelPanel.frame.width, 210)
        linePanel.close()
        pixelPanel.close()
    }

    func testPrecisePixelScrollIsNormalizedForCommandOpacity() {
        let (linePanel, lineView) = makePinnedWindow(origin: CGPoint(x: 100, y: 100))
        let (pixelPanel, pixelView) = makePinnedWindow(origin: CGPoint(x: 400, y: 100))
        linePanel.alphaValue = 0.5
        pixelPanel.alphaValue = 0.5

        lineView.scrollWheel(with: scrollEvent(deltaY: 1, units: .line, modifiers: [.command]))
        pixelView.scrollWheel(with: scrollEvent(deltaY: 10, units: .pixel, modifiers: [.command]))

        XCTAssertEqual(pixelPanel.alphaValue, linePanel.alphaValue, accuracy: 0.001)
        XCTAssertEqual(pixelPanel.alphaValue, 0.55, accuracy: 0.001)
        linePanel.close()
        pixelPanel.close()
    }

    func testMagnificationStillScalesAroundWindowCenter() {
        let (panel, view) = makePinnedWindow()
        let oldCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)

        view.applyMagnification(0.25)

        XCTAssertGreaterThan(panel.frame.width, 200)
        XCTAssertEqual(panel.frame.midX, oldCenter.x, accuracy: 0.001)
        XCTAssertEqual(panel.frame.midY, oldCenter.y, accuracy: 0.001)
        panel.close()
    }

    func testMiddleClickRestoresInitialSizeWithoutMovingCenter() {
        let (panel, view) = makePinnedWindow()
        panel.setFrame(
            CGRect(x: 50, y: 70, width: 400, height: 240),
            display: false
        )
        let enlargedCenter = CGPoint(x: panel.frame.midX, y: panel.frame.midY)

        view.otherMouseDown(with: otherMouseEvent(button: .center))

        XCTAssertEqual(panel.frame.size, CGSize(width: 200, height: 120))
        XCTAssertEqual(panel.frame.midX, enlargedCenter.x, accuracy: 0.001)
        XCTAssertEqual(panel.frame.midY, enlargedCenter.y, accuracy: 0.001)
        panel.close()
    }

    func testNonMiddleAuxiliaryButtonDoesNotResetSize() {
        let (panel, view) = makePinnedWindow()
        panel.setFrame(
            CGRect(x: 50, y: 70, width: 400, height: 240),
            display: false
        )

        view.otherMouseDown(with: otherMouseEvent(button: CGMouseButton(rawValue: 4)!))

        XCTAssertEqual(panel.frame.size, CGSize(width: 400, height: 240))
        panel.close()
    }

    func testLockPreventsDraggingZoomingAndNativeResizeButMenuStillUnlocks() {
        let (panel, view) = makePinnedWindow()
        selectMenuItem(titled: "锁定贴图", in: view)
        let lockedFrame = panel.frame

        view.mouseDown(with: mouseEvent(.leftMouseDown, window: panel, location: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, window: panel, location: CGPoint(x: 80, y: 60)))
        view.applyScroll(deltaY: 2, modifiers: [], anchorInWindow: CGPoint(x: 80, y: 60))
        view.applyMagnification(0.5)

        XCTAssertEqual(panel.frame, lockedFrame)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        let lockedMenu = view.makeContextMenu()
        XCTAssertNotNil(lockedMenu.items.first(where: { $0.title == "解锁贴图" && $0.state == .on }))

        selectMenuItem(titled: "解锁贴图", in: view)

        XCTAssertTrue(panel.styleMask.contains(.resizable))
        let unlockedMenu = view.makeContextMenu()
        XCTAssertNotNil(unlockedMenu.items.first(where: { $0.title == "锁定贴图" && $0.state == .off }))
        panel.close()
    }

    func testUnlockedPinCanStillBeDragged() {
        let (panel, view) = makePinnedWindow()
        let originalOrigin = panel.frame.origin

        view.mouseDown(with: mouseEvent(.leftMouseDown, window: panel, location: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, window: panel, location: CGPoint(x: 60, y: 45)))
        view.mouseUp(with: mouseEvent(.leftMouseUp, window: panel, location: CGPoint(x: 60, y: 45)))

        XCTAssertEqual(panel.frame.origin.x, originalOrigin.x + 40, accuracy: 0.001)
        XCTAssertEqual(panel.frame.origin.y, originalOrigin.y + 25, accuracy: 0.001)
        panel.close()
    }

    func testAlwaysOnTopMenuTogglesBetweenFloatingAndNormalLevels() {
        let (panel, view) = makePinnedWindow()

        let initialMenu = view.makeContextMenu()
        XCTAssertNotNil(initialMenu.items.first(where: { $0.title == "取消置顶" && $0.state == .on }))

        selectMenuItem(titled: "取消置顶", in: view)

        XCTAssertEqual(panel.level, .normal)
        XCTAssertFalse(panel.isFloatingPanel)
        let normalMenu = view.makeContextMenu()
        XCTAssertNotNil(normalMenu.items.first(where: { $0.title == "置顶贴图" && $0.state == .off }))

        selectMenuItem(titled: "置顶贴图", in: view)

        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isFloatingPanel)
        panel.close()
    }

    func testContextMenuRetainsCopySaveOpacityAndCloseActions() {
        let (panel, view) = makePinnedWindow()
        panel.alphaValue = 0.8

        let menu = view.makeContextMenu()

        XCTAssertNotNil(menu.items.first(where: { $0.title == "复制图片" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "另存为…" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "关闭贴图" }))
        let opacity = try! XCTUnwrap(menu.items.first(where: { $0.title == "透明度" })?.submenu)
        XCTAssertEqual(opacity.items.map { $0.title }, ["100%", "80%", "60%", "40%"])
        XCTAssertEqual(opacity.items.first(where: { $0.title == "80%" })?.state, .on)
        panel.close()
    }

    func testCopyFailureIsReportedThroughInjectedErrorHandler() {
        var reportedMessage: String?
        let view = makeContentView(
            copyImage: { _ in throw PinInteractionTestError(message: "复制失败") },
            saveImage: { _ in true },
            presentError: { reportedMessage = $0.localizedDescription }
        )
        let (panel, _) = makePinnedWindow(view: view)

        selectMenuItem(titled: "复制图片", in: view)

        XCTAssertEqual(reportedMessage, "复制失败")
        panel.close()
    }

    func testSaveFailureIsReportedThroughInjectedErrorHandler() {
        var reportedMessage: String?
        let view = makeContentView(
            copyImage: { _ in },
            saveImage: { _ in throw PinInteractionTestError(message: "保存失败") },
            presentError: { reportedMessage = $0.localizedDescription }
        )
        let (panel, _) = makePinnedWindow(view: view)

        selectMenuItem(titled: "另存为…", in: view)

        XCTAssertEqual(reportedMessage, "保存失败")
        panel.close()
    }

    func testCancellingSaveDoesNotReportAnError() {
        var reportedMessage: String?
        let view = makeContentView(
            copyImage: { _ in },
            saveImage: { _ in false },
            presentError: { reportedMessage = $0.localizedDescription }
        )
        let (panel, _) = makePinnedWindow(view: view)

        selectMenuItem(titled: "另存为…", in: view)

        XCTAssertNil(reportedMessage)
        panel.close()
    }

    func testPasteboardEncodingFailurePreservesExistingContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertThrowsError(try ImagePasteboard.write(NSImage(size: .zero), to: pasteboard))

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testPasteboardWriteFailureRestoresExistingContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let image = NSImage(size: CGSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        CGRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        XCTAssertThrowsError(try ImagePasteboard.write(
            image,
            to: pasteboard,
            replaceContents: { pasteboard, _ in
                pasteboard.clearContents()
                return false
            }
        ))

        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testHoverStillShowsAndHidesCloseButton() {
        let (panel, view) = makePinnedWindow()
        let closeButton = try! XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)

        XCTAssertTrue(closeButton.isHidden)
        view.mouseEntered(with: mouseEvent(.leftMouseDown, window: panel, location: .zero))
        XCTAssertFalse(closeButton.isHidden)
        view.mouseExited(with: mouseEvent(.leftMouseDown, window: panel, location: .zero))
        XCTAssertTrue(closeButton.isHidden)
        panel.close()
    }

    private func makePinnedWindow(
        origin: CGPoint = CGPoint(x: 100, y: 100),
        view suppliedView: PinContentView? = nil
    ) -> (NSPanel, PinContentView) {
        _ = NSApplication.shared
        let size = CGSize(width: 200, height: 120)
        let view = suppliedView ?? PinContentView(image: NSImage(size: size), initialSize: size)
        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.orderFront(nil)
        return (panel, view)
    }

    private func makeContentView(
        copyImage: @escaping @MainActor (NSImage) throws -> Void,
        saveImage: @escaping @MainActor (NSImage) throws -> Bool,
        presentError: @escaping @MainActor (Error) -> Void
    ) -> PinContentView {
        let size = CGSize(width: 200, height: 120)
        return PinContentView(
            image: NSImage(size: size),
            initialSize: size,
            copyImage: copyImage,
            saveImage: saveImage,
            presentError: presentError
        )
    }

    private func selectMenuItem(
        titled title: String,
        in view: PinContentView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let menu = view.makeContextMenu()
        guard let item = menu.items.first(where: { $0.title == title }),
              let action = item.action else {
            XCTFail("Missing enabled menu item: \(title)", file: file, line: line)
            return
        }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), file: file, line: line)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        window: NSWindow,
        location: CGPoint
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func scrollEvent(
        deltaY: Int32,
        units: CGScrollEventUnit,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        )!
        var flags: CGEventFlags = []
        if modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        event.flags = flags
        return NSEvent(cgEvent: event)!
    }

    private func otherMouseEvent(button: CGMouseButton) -> NSEvent {
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .otherMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: button
        )!
        return NSEvent(cgEvent: event)!
    }

    private func assertAnchorIsStable(
        oldFrame: CGRect,
        newFrame: CGRect,
        anchor: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scale = newFrame.width / oldFrame.width
        XCTAssertEqual(
            newFrame.minX + anchor.x * scale,
            oldFrame.minX + anchor.x,
            accuracy: 1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            newFrame.minY + anchor.y * scale,
            oldFrame.minY + anchor.y,
            accuracy: 1,
            file: file,
            line: line
        )
    }
}

private struct PinInteractionTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
