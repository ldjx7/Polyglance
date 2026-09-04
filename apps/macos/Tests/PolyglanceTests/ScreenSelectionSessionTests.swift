import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class ScreenSelectionSessionTests: XCTestCase {
    func testSessionDimsEveryInactiveScreenExactlyOnceAndCleansUpIdempotently() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let firstInactiveFrame = screen.frame.offsetBy(dx: screen.frame.width, dy: 0)
        let secondInactiveFrame = screen.frame.offsetBy(dx: 0, dy: -screen.frame.height)
        let overlappingTargetFrame = screen.frame.insetBy(dx: 20, dy: 20)
        let overlappingInactiveFrame = firstInactiveFrame.insetBy(dx: 20, dy: 20)
        let session = ScreenSelectionSession(
            image: try makeImage(),
            screen: screen,
            inactiveScreenFrames: [
                screen.frame,
                firstInactiveFrame,
                firstInactiveFrame,
                overlappingTargetFrame,
                overlappingInactiveFrame,
                secondInactiveFrame,
            ]
        )

        XCTAssertEqual(
            Set(session.inactiveDimmingWindowFrames.map(RectKey.init)),
            Set([RectKey(firstInactiveFrame), RectKey(secondInactiveFrame)])
        )

        var completionCount = 0
        session.present { action in
            XCTAssertNil(action)
            completionCount += 1
        }

        XCTAssertTrue(session.areInactiveScreensDimmed)
        XCTAssertTrue(session.isSelectionWindowVisible)

        session.cancel()
        session.cancel()

        XCTAssertFalse(session.areInactiveScreensDimmed)
        XCTAssertFalse(session.isSelectionWindowVisible)
        XCTAssertEqual(completionCount, 1)
    }

    func testInactiveScreenDimmingWindowCannotBecomeKeyOrPassClicksThrough() {
        _ = NSApplication.shared
        let window = InactiveScreenDimmingWindow(
            frame: CGRect(x: -1200, y: 0, width: 1200, height: 800)
        )

        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.level, .screenSaver)
    }

    func testInactiveScreenDimmingWindowRoutesRightClickToSelectionSession() throws {
        _ = NSApplication.shared
        let window = InactiveScreenDimmingWindow(
            frame: CGRect(x: -1200, y: 0, width: 1200, height: 800)
        )
        var rightClickCount = 0
        window.onRightClick = { rightClickCount += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        window.contentView?.rightMouseDown(with: event)

        XCTAssertEqual(rightClickCount, 1)
    }

    func testPinHandoffKeepsSelectionVisibleUntilCoordinatorDismissesIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let session = ScreenSelectionSession(
            image: try makeImage(width: 240, height: 160),
            screen: screen
        )
        var receivedPin = false
        session.present { action in
            if case .pin = action {
                receivedPin = true
            }
        }

        let window = session.selectionWindowForTesting
        let view = window.selectionView
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 120), window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 180, y: 120), window: window))
        try button(titled: "贴图", in: try XCTUnwrap(window.contentView)).performClick(nil)

        XCTAssertTrue(receivedPin)
        XCTAssertTrue(session.isSelectionWindowVisible)

        session.dismiss()
        XCTAssertFalse(session.isSelectionWindowVisible)
    }

    func testCrossScreenMirrorShowsTheLiveSelectionOnTheSecondDisplay() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let secondFrame = screen.frame.offsetBy(dx: screen.frame.width, dy: 0)
        let captureFrame = screen.frame.union(secondFrame)
        let session = ScreenSelectionSession(
            image: try makeImage(width: 400, height: 120),
            screen: screen,
            captureFrame: captureFrame,
            crossScreenFrames: [screen.frame, secondFrame]
        )
        session.present { _ in }
        let window = session.selectionWindowForTesting
        let start = CGPoint(x: 40, y: 80)
        let globalEnd = CGPoint(x: secondFrame.midX, y: secondFrame.midY)

        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: start, window: window)
        )
        window.selectionView.advanceGlobalDragForTesting(
            globalPoint: globalEnd,
            leftButtonPressed: true
        )

        XCTAssertEqual(session.crossScreenOverlayFrames, [secondFrame])
        XCTAssertTrue(session.areCrossScreenOverlaysVisible)
        let mirroredSelection = try XCTUnwrap(
            session.crossScreenSelectionsForTesting.first ?? nil
        )
        XCTAssertGreaterThan(mirroredSelection.width, 0)
        XCTAssertTrue(CGRect(origin: .zero, size: secondFrame.size).intersects(mirroredSelection))

        session.cancel()
        XCTAssertFalse(session.areCrossScreenOverlaysVisible)
    }

    func testSecondDisplayMirrorForwardsSelectionEdgeResize() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let secondFrame = screen.frame.offsetBy(dx: screen.frame.width, dy: 0)
        let captureFrame = screen.frame.union(secondFrame)
        let session = ScreenSelectionSession(
            image: try makeImage(width: 400, height: 120),
            screen: screen,
            captureFrame: captureFrame,
            crossScreenFrames: [screen.frame, secondFrame]
        )
        session.present { _ in }
        let window = session.selectionWindowForTesting
        let selectionStart = CGPoint(x: 40, y: 100)
        let selectionEnd = CGPoint(
            x: secondFrame.minX - captureFrame.minX + 240,
            y: 500
        )
        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: selectionStart, window: window)
        )
        window.selectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: selectionEnd, window: window)
        )
        window.selectionView.mouseUp(
            with: mouseEvent(.leftMouseUp, at: selectionEnd, window: window)
        )
        let original = try XCTUnwrap(window.selectionView.confirmedSelection)
        let edge = CGPoint(
            x: captureFrame.minX + original.maxX,
            y: captureFrame.minY + original.midY
        )
        let expandedEdge = CGPoint(x: edge.x + 120, y: edge.y)

        session.forwardCrossScreenMouseForTesting(.leftMouseDown, globalPoint: edge)
        session.forwardCrossScreenMouseForTesting(.leftMouseDragged, globalPoint: expandedEdge)
        session.forwardCrossScreenMouseForTesting(.leftMouseUp, globalPoint: expandedEdge)

        let resized = try XCTUnwrap(window.selectionView.confirmedSelection)
        XCTAssertEqual(resized.maxX, original.maxX + 120, accuracy: 0.001)
        session.cancel()
    }

    func testManuallyMovedToolbarIsMirroredOnTheSecondDisplay() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let secondFrame = screen.frame.offsetBy(dx: screen.frame.width, dy: 0)
        let captureFrame = screen.frame.union(secondFrame)
        let session = ScreenSelectionSession(
            image: try makeImage(width: 400, height: 120),
            screen: screen,
            captureFrame: captureFrame,
            crossScreenFrames: [screen.frame, secondFrame]
        )
        session.present { _ in }
        let window = session.selectionWindowForTesting
        let selectionStart = CGPoint(x: 40, y: 100)
        let selectionEnd = CGPoint(x: 480, y: 500)
        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: selectionStart, window: window)
        )
        window.selectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: selectionEnd, window: window)
        )
        window.selectionView.mouseUp(
            with: mouseEvent(.leftMouseUp, at: selectionEnd, window: window)
        )

        window.selectionView.moveToolbarForTesting(
            by: CGPoint(x: secondFrame.minX - screen.frame.minX + 120, y: 0)
        )

        let mirroredToolbar = try XCTUnwrap(
            session.crossScreenToolbarFramesForTesting.first ?? nil
        )
        XCTAssertTrue(CGRect(origin: .zero, size: secondFrame.size).intersects(mirroredToolbar))
        session.cancel()
    }

    func testSecondDisplayMirroredToolbarForwardsButtonClicks() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let secondFrame = screen.frame.offsetBy(dx: screen.frame.width, dy: 0)
        let captureFrame = screen.frame.union(secondFrame)
        var receivedOCRTranslation = false
        let session = ScreenSelectionSession(
            image: try makeImage(width: 400, height: 120),
            screen: screen,
            captureFrame: captureFrame,
            crossScreenFrames: [screen.frame, secondFrame]
        )
        session.present { action in
            if case .ocrTranslate = action {
                receivedOCRTranslation = true
            }
        }
        let window = session.selectionWindowForTesting
        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 100), window: window)
        )
        window.selectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 480, y: 500), window: window)
        )
        window.selectionView.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: 480, y: 500), window: window)
        )
        window.selectionView.moveToolbarForTesting(
            by: CGPoint(x: secondFrame.minX - screen.frame.minX + 120, y: 0)
        )
        let buttonFrame = try XCTUnwrap(
            window.selectionView.toolbarButtonFrameForTesting(titled: "OCR翻译")
        )
        let buttonCenter = CGPoint(
            x: captureFrame.minX + buttonFrame.midX,
            y: captureFrame.minY + buttonFrame.midY
        )

        session.forwardCrossScreenMouseForTesting(.leftMouseDown, globalPoint: buttonCenter)
        session.forwardCrossScreenMouseForTesting(.leftMouseUp, globalPoint: buttonCenter)

        XCTAssertTrue(
            receivedOCRTranslation,
            "button=\(buttonFrame) global=\(buttonCenter) screen=\(secondFrame)"
        )
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func button(titled title: String, in view: NSView) throws -> NSButton {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for child in view.subviews {
            if let button = try? button(titled: title, in: child) {
                return button
            }
        }
        throw NSError(domain: "ScreenSelectionSessionTests", code: 1)
    }

    func testCustomizedToolbarItemsOrderAndVisibility() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let customItems: [ScreenshotToolbarItemConfig] = [
            ScreenshotToolbarItemConfig(id: "copy", isVisible: true),
            ScreenshotToolbarItemConfig(id: "pin", isVisible: true),
            ScreenshotToolbarItemConfig(id: "rect", isVisible: false),
        ]
        let session = ScreenSelectionSession(
            image: try makeImage(),
            screen: screen,
            toolbarItems: customItems
        )
        let view = session.selectionWindowForTesting.selectionView
        XCTAssertNotNil(view.toolbarButtonFrameForTesting(titled: "复制"))
        XCTAssertNotNil(view.toolbarButtonFrameForTesting(titled: "贴图"))
        XCTAssertNil(view.toolbarButtonFrameForTesting(titled: "矩形"))
    }

    private func makeImage(width: Int = 10, height: Int = 10) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let pixelData = Data(repeating: 255, count: width * height * 4) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: pixelData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }
}

private struct RectKey: Hashable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}
