import AppKit
import XCTest
@testable import NativeTranslatorMac

@MainActor
final class LongScreenshotControlViewTests: XCTestCase {
    func testRegionOverlayRemainsVisibleAndOnlyAllowsEditingWhileReady() {
        _ = NSApplication.shared
        let region = CGRect(x: 100, y: 120, width: 480, height: 320)
        let panel = LongScreenshotRegionOverlayPanel(region: region)
        panel.present()

        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, region)
        XCTAssertTrue(panel.overlayView.isRegionVisible)
        XCTAssertTrue(panel.overlayView.allowsRegionEditing)
        XCTAssertEqual(panel.overlayView.borderColor, .systemBlue)

        panel.update(for: .capturing)
        XCTAssertTrue(panel.overlayView.isRegionVisible)
        XCTAssertFalse(panel.overlayView.allowsRegionEditing)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.overlayView.borderColor, .systemRed)

        panel.update(for: .paused)
        XCTAssertTrue(panel.overlayView.isRegionVisible)
        XCTAssertEqual(panel.overlayView.borderColor, .systemOrange)
        panel.orderOut(nil)
    }

    func testReadyRegionOverlayCanResizeAndMoveBeforeCapture() {
        _ = NSApplication.shared
        let panel = LongScreenshotRegionOverlayPanel(
            region: CGRect(x: 120, y: 140, width: 400, height: 260)
        )
        panel.present()
        var changedFrames: [CGRect] = []
        panel.overlayView.onRegionChanged = { changedFrames.append($0) }

        panel.overlayView.mouseDown(with: regionMouseEvent(
            .leftMouseDown,
            location: CGPoint(x: 399, y: 130),
            window: panel
        ))
        panel.overlayView.mouseDragged(with: regionMouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: 349, y: 130),
            window: panel
        ))
        panel.overlayView.mouseUp(with: regionMouseEvent(
            .leftMouseUp,
            location: CGPoint(x: 349, y: 130),
            window: panel
        ))

        XCTAssertEqual(panel.frame.width, 350, accuracy: 1)
        XCTAssertEqual(changedFrames.last, panel.frame)

        let movePoint = CGPoint(x: panel.frame.width / 2, y: panel.frame.height - 8)
        let oldOrigin = panel.frame.origin
        panel.overlayView.mouseDown(with: regionMouseEvent(
            .leftMouseDown,
            location: movePoint,
            window: panel
        ))
        panel.overlayView.mouseDragged(with: regionMouseEvent(
            .leftMouseDragged,
            location: CGPoint(x: movePoint.x + 20, y: movePoint.y + 15),
            window: panel
        ))
        panel.overlayView.mouseUp(with: regionMouseEvent(
            .leftMouseUp,
            location: CGPoint(x: movePoint.x + 20, y: movePoint.y + 15),
            window: panel
        ))
        XCTAssertEqual(panel.frame.origin.x, oldOrigin.x + 20, accuracy: 1)
        XCTAssertEqual(panel.frame.origin.y, oldOrigin.y + 15, accuracy: 1)
        panel.orderOut(nil)
    }
    func testCapturingToolbarOnlyShowsPinCopyAndCloseIcons() {
        _ = NSApplication.shared
        let view = LongScreenshotControlView()

        view.update(for: .capturing)
        view.setHasCapturedFrame(true)

        XCTAssertEqual(view.actionStack.arrangedSubviews, [
            view.pinButton,
            view.copyButton,
            view.closeButton,
        ])
        XCTAssertTrue(view.pinButton.isEnabled)
        XCTAssertTrue(view.copyButton.isEnabled)
        XCTAssertTrue(view.closeButton.isEnabled)
        XCTAssertEqual(view.pinButton.title, "")
        XCTAssertEqual(view.copyButton.title, "")
        XCTAssertEqual(view.closeButton.title, "")
        XCTAssertEqual(view.pinButton.toolTip, "贴图")
        XCTAssertEqual(view.copyButton.toolTip, "复制")
        XCTAssertEqual(view.closeButton.toolTip, "关闭")
    }

    func testCaptureToolbarDoesNotExposeDirectionSelection() {
        _ = NSApplication.shared
        let view = LongScreenshotControlView()
        var actions: [LongScreenshotControlAction] = []
        view.onAction = { actions.append($0) }

        view.update(for: .capturing)
        view.setHasCapturedFrame(true)

        XCTAssertNil(view.subviewsRecursive.first(where: { $0 is NSPopUpButton }))
        XCTAssertTrue(actions.isEmpty)
    }

    func testPreviewPanelAppearsOnlyWhileCapturingOrPausedAndShowsThumbnail() {
        _ = NSApplication.shared
        let selection = CGRect(x: 100, y: 160, width: 320, height: 260)
        let panel = LongScreenshotPreviewPanel()
        let preview = LongScreenshotPreview(
            image: NSImage(size: CGSize(width: 300, height: 150)),
            direction: .vertical,
            frameCount: 1,
            totalPixelWidth: 300,
            totalPixelHeight: 150,
            viewportPixelWidth: 300,
            viewportPixelHeight: 150,
            viewportPixelOffset: 0
        )

        panel.update(preview: preview, near: selection)
        panel.update(for: .ready, near: selection)
        XCTAssertFalse(panel.isVisible)

        panel.update(for: .capturing, near: selection)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.previewView.image === preview.image)
        XCTAssertEqual(panel.previewView.viewportFraction, 1, accuracy: 0.001)
        XCTAssertEqual(panel.contentView!.frame.width, 180, accuracy: 1)
        XCTAssertEqual(panel.contentView!.frame.height, 90, accuracy: 1)
        XCTAssertTrue(panel.previewView.subviews.compactMap { $0 as? NSTextField }.isEmpty)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, selection.maxX + 8)

        let longerPreview = LongScreenshotPreview(
            image: NSImage(size: CGSize(width: 300, height: 600)),
            direction: .vertical,
            frameCount: 4,
            totalPixelWidth: 300,
            totalPixelHeight: 600,
            viewportPixelWidth: 300,
            viewportPixelHeight: 150,
            viewportPixelOffset: 450
        )
        panel.update(preview: longerPreview, near: selection)
        XCTAssertEqual(panel.contentView!.frame.width, 180, accuracy: 1)
        XCTAssertEqual(panel.contentView!.frame.height, 360, accuracy: 1)
        XCTAssertEqual(panel.previewView.viewportFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(panel.previewView.viewportOffsetFraction, 0.75, accuracy: 0.001)

        let horizontalPreview = LongScreenshotPreview(
            image: NSImage(size: CGSize(width: 600, height: 300)),
            direction: .horizontal,
            frameCount: 4,
            totalPixelWidth: 600,
            totalPixelHeight: 300,
            viewportPixelWidth: 300,
            viewportPixelHeight: 300,
            viewportPixelOffset: 300
        )
        panel.update(preview: horizontalPreview, near: selection)
        XCTAssertEqual(panel.contentView!.frame.width, 360, accuracy: 1)
        XCTAssertEqual(panel.contentView!.frame.height, 180, accuracy: 1)
        XCTAssertFalse(panel.frame.intersects(selection))

        panel.update(for: .paused, near: selection)
        XCTAssertTrue(panel.isVisible)
        panel.update(for: .finished, near: selection)
        XCTAssertFalse(panel.isVisible)
    }

    func testEveryButtonRoutesToItsSemanticCallback() {
        _ = NSApplication.shared
        let view = LongScreenshotControlView()
        var actions: [LongScreenshotControlAction] = []
        view.onAction = { actions.append($0) }

        view.update(for: .capturing)
        view.setHasCapturedFrame(true)
        view.copyButton.performClick(nil)
        view.pinButton.performClick(nil)
        view.closeButton.performClick(nil)

        XCTAssertEqual(actions, [.copy, .pin, .cancel])
    }

    func testControlToolbarNeverCoversTheSelectedRegion() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let selection = CGRect(
            x: screen.visibleFrame.midX - 160,
            y: screen.visibleFrame.minY + 12,
            width: 320,
            height: 220
        )
        let panel = LongScreenshotControlPanel()

        panel.present(near: selection)

        XCTAssertFalse(panel.frame.intersects(selection))
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        panel.orderOut(nil)
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        subviews + subviews.flatMap(\.subviewsRecursive)
    }
}

@MainActor
private func regionMouseEvent(
    _ type: NSEvent.EventType,
    location: CGPoint,
    window: NSWindow
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
