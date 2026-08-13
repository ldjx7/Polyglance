import AppKit
import XCTest
@testable import NativeTranslatorMac

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
