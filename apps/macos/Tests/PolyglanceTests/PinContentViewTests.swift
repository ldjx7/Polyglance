import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class PinContentViewTests: XCTestCase {
    func testLeftDoubleClickClosesPinnedWindow() {
        _ = NSApplication.shared
        let (panel, view) = makePinnedWindow()
        panel.orderFront(nil)

        view.mouseDown(with: mouseEvent(.leftMouseDown, window: panel, clickCount: 2))

        XCTAssertFalse(panel.isVisible)
    }

    func testSingleClickDoesNotClosePinnedWindow() {
        _ = NSApplication.shared
        let (panel, view) = makePinnedWindow()
        panel.orderFront(nil)

        view.mouseDown(with: mouseEvent(.leftMouseDown, window: panel, clickCount: 1))
        view.mouseUp(with: mouseEvent(.leftMouseUp, window: panel, clickCount: 1))

        XCTAssertTrue(panel.isVisible)
        panel.close()
    }

    func testPinnedContentAcceptsFirstMouse() {
        _ = NSApplication.shared
        let (_, view) = makePinnedWindow()

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testContextMenuReentersAnnotationModeAndMosaicDrawsAFreehandStroke() throws {
        _ = NSApplication.shared
        let (panel, view) = makePinnedWindow()
        panel.orderFront(nil)
        let annotate = try XCTUnwrap(
            view.makeContextMenu().items.first(where: { $0.title == "标注" })
        )

        XCTAssertTrue(try sendPinMenuAction(annotate))
        view.annotationEditor.selectTool(.mosaic)
        view.annotationEditor.beginStroke(at: CGPoint(x: 20, y: 20))
        view.annotationEditor.continueStroke(to: CGPoint(x: 45, y: 35))
        view.annotationEditor.continueStroke(to: CGPoint(x: 80, y: 50))
        view.annotationEditor.endStroke(at: CGPoint(x: 100, y: 60))

        XCTAssertTrue(view.annotationEditor.isEditing)
        XCTAssertEqual(view.annotationEditor.elements.count, 1)
        guard case let .mosaic(points, _) = view.annotationEditor.elements[0] else {
            return XCTFail("Expected a freehand mosaic stroke")
        }
        XCTAssertGreaterThanOrEqual(points.count, 4)
        panel.close()
    }

    func testContextMenuEntersColorPickingAndCopiesTheDisplayedPixel() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = makeSolidImage(red: 0x12, green: 0x34, blue: 0x56)
        let view = PinContentView(image: image, colorPasteboard: pasteboard)
        let panel = PinPanel(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 120),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.orderFront(nil)

        let colorPicker = try XCTUnwrap(
            view.makeContextMenu().items.first(where: { $0.title == "取色" })
        )
        XCTAssertTrue(try sendPinMenuAction(colorPicker))
        XCTAssertTrue(view.isColorPicking)

        view.updateColorPicking(at: CGPoint(x: 100, y: 60))
        XCTAssertEqual(view.currentPixelSample?.hex, "#123456")
        view.keyDown(with: keyEvent(window: panel, modifiers: [], characters: "c"))
        XCTAssertEqual(pasteboard.string(forType: .string), "#123456")

        let exitPicker = try XCTUnwrap(
            view.makeContextMenu().items.first(where: { $0.title == "退出取色" })
        )
        XCTAssertTrue(try sendPinMenuAction(exitPicker))
        XCTAssertFalse(view.isColorPicking)
        panel.close()
    }

    func testTextAnnotationMakesPinKeyAndCommitsTypedText() throws {
        _ = NSApplication.shared
        let image = makeTestImage()
        let editor = PinAnnotationOverlayView(sourceImage: image)
        let panel = PinPanel(
            contentRect: CGRect(x: 100, y: 100, width: 240, height: 160),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = editor
        panel.orderFront(nil)

        editor.beginEditing()
        editor.selectTool(.text)
        editor.beginStroke(at: CGPoint(x: 40, y: 80))

        let field = try XCTUnwrap(editor.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertNotNil(field.currentEditor())

        field.stringValue = "贴图文字"
        XCTAssertTrue(NSApp.sendAction(field.action!, to: field.target, from: field))
        XCTAssertEqual(editor.elements.count, 1)
        guard case let .text(origin, text, _) = editor.elements[0] else {
            return XCTFail("Expected committed text annotation")
        }
        XCTAssertEqual(origin, CGPoint(x: 40, y: 80))
        XCTAssertEqual(text, "贴图文字")
        panel.close()
    }

    func testAnnotationEditorSupportsEveryDrawingToolUndoRedoAndCompletion() {
        _ = NSApplication.shared
        let image = makeTestImage()
        let editor = PinAnnotationOverlayView(sourceImage: image)
        editor.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
        let panel = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 240, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = editor
        panel.orderFront(nil)
        editor.beginEditing()

        for (index, tool) in [
            ScreenshotAnnotationTool.freehand,
            .rectangle,
            .ellipse,
            .arrow,
            .mosaic,
        ].enumerated() {
            editor.selectTool(tool)
            let offset = CGFloat(index * 8)
            editor.beginStroke(at: CGPoint(x: 40 + offset, y: 80))
            editor.continueStroke(to: CGPoint(x: 80 + offset, y: 105))
            editor.endStroke(at: CGPoint(x: 110 + offset, y: 115))
        }
        XCTAssertEqual(editor.elements.map(\.tool), [.freehand, .rectangle, .ellipse, .arrow, .mosaic])

        editor.keyDown(with: keyEvent(window: panel, modifiers: .command, characters: "z"))
        XCTAssertEqual(editor.elements.count, 4)
        editor.keyDown(with: keyEvent(
            window: panel,
            modifiers: [.command, .shift],
            characters: "z"
        ))
        XCTAssertEqual(editor.elements.count, 5)
        XCTAssertFalse(editor.compositedImage() === image)

        editor.finishEditing()
        XCTAssertFalse(editor.isEditing)
        XCTAssertNil(editor.hitTest(CGPoint(x: 100, y: 100)))
        panel.close()
    }

    func testAnnotationToolbarIsAttachedBelowTheImageWithoutCoveringIt() throws {
        _ = NSApplication.shared
        let image = makeTestImage()
        let editor = PinAnnotationOverlayView(sourceImage: image)
        let panel = NSPanel(
            contentRect: CGRect(x: 240, y: 360, width: 240, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = editor
        panel.orderFront(nil)

        editor.beginEditing()

        let toolbarPanel = try XCTUnwrap(editor.toolbarPanel)
        XCTAssertTrue(toolbarPanel.isVisible)
        XCTAssertLessThanOrEqual(toolbarPanel.frame.maxY, panel.frame.minY - 6)
        XCTAssertFalse(toolbarPanel.frame.intersects(panel.frame))

        editor.finishEditing()
        XCTAssertFalse(toolbarPanel.isVisible)
        panel.close()
    }

    private func makePinnedWindow() -> (NSPanel, PinContentView) {
        let image = NSImage(size: CGSize(width: 200, height: 120))
        let view = PinContentView(image: image)
        let panel = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 200, height: 120),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        return (panel, view)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        window: NSWindow,
        clickCount: Int
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: CGPoint(x: 80, y: 60),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func keyEvent(
        window: NSWindow,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 6
        )!
    }

    private func makeTestImage() -> NSImage {
        let width = 240
        let height = 160
        let data = Data(repeating: 180, count: width * height * 4)
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: image, size: CGSize(width: width, height: height))
    }

    private func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8) -> NSImage {
        let width = 200
        let height = 120
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                bytes[offset] = red
                bytes[offset + 1] = green
                bytes[offset + 2] = blue
                bytes[offset + 3] = 0xFF
            }
        }
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: image, size: CGSize(width: width, height: height))
    }
}

@MainActor
private func sendPinMenuAction(_ item: NSMenuItem) throws -> Bool {
    let action = try XCTUnwrap(item.action)
    return NSApp.sendAction(action, to: item.target, from: item)
}
