import AppKit
import PolyglanceKit
import XCTest
@testable import Polyglance

@MainActor
final class OCRTranslationPinTests: XCTestCase {
    func testPresentationModelSupportsOriginalImageSourceTextAndTranslation() {
        var model = OCRTranslationPresentationModel(
            sourceText: "Hello",
            translatedText: "你好"
        )

        XCTAssertEqual(model.mode, .translation)
        XCTAssertEqual(model.visibleText, "你好")

        model.showOriginal()
        XCTAssertEqual(model.mode, .original)
        XCTAssertNil(model.visibleText)

        model.showSourceText()
        XCTAssertEqual(model.mode, .sourceText)
        XCTAssertEqual(model.visibleText, "Hello")

        model.showTranslation()
        XCTAssertEqual(model.visibleText, "你好")
    }

    func testTranslationPinViewSwitchesBetweenOriginalImageSourceTextAndTranslation() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )

        XCTAssertEqual(view.mode, .translation)
        XCTAssertFalse(view.isTranslationOverlayHidden)
        XCTAssertTrue(view.isTranslationTextSelectable)
        XCTAssertEqual(view.translationText, "你好，世界")
        XCTAssertTrue(view.showsSourceAlongsideTranslation)
        XCTAssertEqual(view.sourceContextText, "Hello world")
        XCTAssertEqual(view.presentationStyle, .youdaoResultCard)

        view.showOriginal()
        XCTAssertEqual(view.mode, .original)
        XCTAssertTrue(view.isTranslationOverlayHidden)
        XCTAssertNil(view.visibleText)

        view.showSourceText()
        XCTAssertEqual(view.mode, .sourceText)
        XCTAssertFalse(view.isTranslationOverlayHidden)
        XCTAssertEqual(view.visibleText, "Hello world")
        XCTAssertFalse(view.showsSourceAlongsideTranslation)

        view.showTranslation()
        XCTAssertFalse(view.isTranslationOverlayHidden)
        XCTAssertEqual(view.visibleText, "你好，世界")
    }

    func testYoudaoStyleTranslationCardUsesShortActionsAndReadableSurface() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 300)
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.translationSurfaceColor, NSColor.windowBackgroundColor)
        XCTAssertEqual(view.translationActionTitles, ["原图", "原文", "译文", "复制", "关闭"])
        XCTAssertGreaterThanOrEqual(view.minimumResultCardSize.width, 360)
        XCTAssertGreaterThanOrEqual(view.minimumResultCardSize.height, 240)
    }

    func testHoveringSourceHighlightsTheCorrespondingTranslationSegment() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 420, height: 300)),
            sourceText: "Hello. World!",
            translatedText: "你好。世界！"
        )

        view.highlightPairFromSourceCharacterIndex(1)

        XCTAssertEqual(view.highlightedPairID, 0)
        XCTAssertEqual(view.highlightedSourceText, "Hello.")
        XCTAssertEqual(view.highlightedTranslationText, "你好。")

        view.clearPairHighlight()
        XCTAssertNil(view.highlightedPairID)
    }

    func testRightClickInsideTranslationTextUsesThePinMenuAndCanEnterAnnotation() throws {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )
        let menu = try XCTUnwrap(view.visibleTextContextMenu)
        let annotate = try XCTUnwrap(menu.items.first(where: { $0.title == "标注" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "关闭贴图" }))

        XCTAssertTrue(try sendMenuAction(annotate))
        XCTAssertTrue(view.annotationEditor.isEditing)
        XCTAssertEqual(view.mode, .original)
    }

    func testYoudaoStyleTranslationCardAppearsAdjacentToTheCapturedRegion() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let cardSize = CGSize(width: 420, height: 280)

        let below = PinWindowManager.translationResultOrigin(
            sourceFrame: CGRect(x: 180, y: 480, width: 500, height: 160),
            cardSize: cardSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(below, CGPoint(x: 180, y: 188))

        let above = PinWindowManager.translationResultOrigin(
            sourceFrame: CGRect(x: 920, y: 40, width: 200, height: 120),
            cardSize: cardSize,
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(above, CGPoint(x: 780, y: 172))
    }

    func testTranslationPinViewCopyUsesSelectedTranslationWhenAvailable() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界",
            pasteboard: pasteboard
        )
        view.selectTranslationRange(NSRange(location: 0, length: 2))

        try view.copyVisibleText()

        XCTAssertEqual(pasteboard.string(forType: .string), "你好")
    }

    func testTranslationPinCopiesCurrentSourceTextSelectionOrWholeCurrentText() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界",
            pasteboard: pasteboard
        )

        view.showSourceText()
        view.selectVisibleTextRange(NSRange(location: 0, length: 5))
        try view.copyVisibleText()
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        view.showTranslation()
        try view.copyVisibleText()
        XCTAssertEqual(pasteboard.string(forType: .string), "你好，世界")
    }

    func testTranslationPinDoesNotTreatOriginalImageAsTextForCopy() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )
        view.showOriginal()

        XCTAssertThrowsError(try view.copyVisibleText())
    }

    func testShowingOriginalStopsHiddenTextViewFromReceivingKeyboardInput() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)

        view.showOriginal()

        XCTAssertTrue(window.firstResponder === view)
        window.close()
    }

    func testTranslationPinSnapshotPreservesSourceTextDisplayMode() throws {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界"
        )
        view.showSourceText()

        let snapshot = view.snapshot(
            frame: CGRect(x: 10, y: 20, width: 320, height: 180),
            opacity: 1
        )
        guard case let .ocrTranslation(content) = snapshot.content else {
            return XCTFail("Expected OCR translation snapshot")
        }
        XCTAssertEqual(content.displayMode, .sourceText)
    }

    func testTranslationPinManagerCreatesFloatingPanelWithAppManagedResize() throws {
        _ = NSApplication.shared
        let manager = PinWindowManager()

        let panel = try XCTUnwrap(manager.pinTranslation(
            image: NSImage(size: CGSize(width: 400, height: 240)),
            sourceText: "source",
            translatedText: "translation",
            sourceFrame: nil
        ))

        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.canBecomeKey)
        let contentView = try XCTUnwrap(panel.contentView as? OCRTranslationPinContentView)
        XCTAssertTrue(contentView.usesCustomWindowResize)
        XCTAssertEqual(manager.state.activePinCount, 1)
        manager.destroyAllPins()
    }

    func testTranslationPinCustomResizeKeepsTheOppositeCornerAnchored() {
        let resized = OCRTranslationResizeGeometry.resizedFrame(
            startingFrame: CGRect(x: 100, y: 200, width: 400, height: 240),
            dragDelta: CGPoint(x: -80, y: -60),
            edges: [.left, .bottom],
            minimumSize: CGSize(width: 360, height: 240),
            maximumSize: CGSize(width: 900, height: 700)
        )

        XCTAssertEqual(resized, CGRect(x: 20, y: 140, width: 480, height: 300))
    }

    func testTranslationPinCustomResizeClampsSizeWithoutMovingTheAnchoredEdges() {
        let resized = OCRTranslationResizeGeometry.resizedFrame(
            startingFrame: CGRect(x: 100, y: 200, width: 400, height: 240),
            dragDelta: CGPoint(x: 200, y: 180),
            edges: [.left, .bottom],
            minimumSize: CGSize(width: 360, height: 240),
            maximumSize: CGSize(width: 900, height: 700)
        )

        XCTAssertEqual(resized, CGRect(x: 140, y: 200, width: 360, height: 240))
    }

    func testTranslationResultTextViewsUseFiniteAppKitLayoutLimits() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 400, height: 240)),
            sourceText: "source",
            translatedText: "translation"
        )

        let textViews = descendants(of: view).compactMap { $0 as? NSTextView }

        XCTAssertEqual(textViews.count, 2)
        for textView in textViews {
            XCTAssertLessThanOrEqual(textView.maxSize.width, 10_000_000)
            XCTAssertLessThanOrEqual(textView.maxSize.height, 10_000_000)
        }
    }

    func testTranslationPinContextMenuPersistsOpacityAndTopmostStateThroughSharedHistory() throws {
        _ = NSApplication.shared
        let manager = PinWindowManager()
        let panel = manager.createTranslationPinWindow(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "source",
            translatedText: "translation",
            displayMode: .translation,
            initialSize: CGSize(width: 320, height: 180),
            frame: CGRect(x: 200, y: 180, width: 320, height: 180),
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true
        )
        let view = try XCTUnwrap(panel.contentView as? OCRTranslationPinContentView)
        var menu = view.makeContextMenu()
        let opacityItem = try XCTUnwrap(menu.items.first(where: { $0.title == "透明度" }))
        let sixtyPercent = try XCTUnwrap(
            opacityItem.submenu?.items.first(where: { $0.title == "60%" })
        )

        XCTAssertTrue(sixtyPercent.target === view)
        XCTAssertTrue(try sendMenuAction(sixtyPercent))
        XCTAssertEqual(panel.alphaValue, 0.6, accuracy: 0.001)

        menu = view.makeContextMenu()
        let topmost = try XCTUnwrap(menu.items.first(where: { $0.title == "取消置顶" }))
        XCTAssertTrue(try sendMenuAction(topmost))
        XCTAssertFalse(view.isAlwaysOnTop)
        XCTAssertEqual(panel.level, .normal)

        manager.closePin(panel)
        let restored = try XCTUnwrap(manager.restoreMostRecentPin())
        let restoredView = try XCTUnwrap(restored.contentView as? OCRTranslationPinContentView)
        XCTAssertEqual(restored.alphaValue, 0.6, accuracy: 0.001)
        XCTAssertFalse(restoredView.isAlwaysOnTop)
        manager.destroyAllPins()
    }

    func testScreenshotTranslatorStreamsConfiguredTargetLanguageUpdates() async throws {
        let client = RecordingTranslationClient(updates: [
            AppTranslationUpdate(text: "你好", provider: "stub", isFinal: false),
            AppTranslationUpdate(text: "你好，世界", provider: "stub", isFinal: true),
        ])
        let translator = OCRScreenshotTranslator(client: client)

        var received: [AppTranslationUpdate] = []
        for try await update in translator.translationUpdates(
            sourceText: "Hello world",
            targetLanguage: "zh-CN"
        ) {
            received.append(update)
        }

        XCTAssertEqual(received.map(\.text), ["你好", "你好，世界"])
        let request = await client.lastRequest
        XCTAssertEqual(request, AppTranslationRequest(
            text: "Hello world",
            sourceLanguage: nil,
            targetLanguage: "zh-CN"
        ))
    }

    func testTranslationPinCanRenderStreamingProgressBeforeFinalResult() {
        _ = NSApplication.shared
        let view = OCRTranslationPinContentView(
            image: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "",
            isTranslating: true
        )

        XCTAssertTrue(view.isTranslating)
        XCTAssertEqual(view.translationStatusText, "正在翻译…")

        view.updateTranslation("你好", isFinal: false)
        XCTAssertEqual(view.translationText, "你好")
        XCTAssertTrue(view.isTranslating)

        view.updateTranslation("你好，世界", isFinal: true)
        XCTAssertEqual(view.translationText, "你好，世界")
        XCTAssertFalse(view.isTranslating)
        XCTAssertEqual(view.translationStatusText, "截图翻译")
    }
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { child in
        [child] + descendants(of: child)
    }
}

@MainActor
private func sendMenuAction(_ item: NSMenuItem) throws -> Bool {
    let action = try XCTUnwrap(item.action)
    return NSApp.sendAction(action, to: item.target, from: item)
}

private actor RecordingTranslationClient: TranslationClient {
    private let updates: [AppTranslationUpdate]
    private(set) var lastRequest: AppTranslationRequest?

    init(updates: [AppTranslationUpdate]) {
        self.updates = updates
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        XCTFail("OCR screenshot translation must use the streaming client")
        throw RecordingTranslationError.unexpectedNonStreamingCall
    }

    nonisolated func translateStream(
        _ request: AppTranslationRequest
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error> {
        AsyncThrowingStream(AppTranslationUpdate.self, bufferingPolicy: .unbounded) { continuation in
            Task {
                await self.record(request)
                let updates = self.updates
                for update in updates {
                    continuation.yield(update)
                }
                continuation.finish()
            }
        }
    }

    private func record(_ request: AppTranslationRequest) { lastRequest = request }
}

private enum RecordingTranslationError: Error {
    case unexpectedNonStreamingCall
}
