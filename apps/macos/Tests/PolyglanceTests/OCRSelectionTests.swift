import AppKit
import XCTest
@testable import Polyglance

final class OCRDocumentTests: XCTestCase {
    func testRecognizeDocumentPreservesNormalizedBoxesAndReadingOrder() async throws {
        let backend = OCRDocumentBackendStub(observations: [
            OCRTextObservation(
                text: "Second line",
                boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.65, height: 0.10),
                fragments: [
                    OCRTextFragment(
                        text: "Second",
                        boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.10)
                    ),
                    OCRTextFragment(
                        text: "line",
                        boundingBox: CGRect(x: 0.48, y: 0.20, width: 0.27, height: 0.10),
                        separatorBefore: " "
                    ),
                ]
            ),
            OCRTextObservation(
                text: "First line",
                boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.62, height: 0.10),
                fragments: [
                    OCRTextFragment(
                        text: "First",
                        boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.25, height: 0.10)
                    ),
                    OCRTextFragment(
                        text: "line",
                        boundingBox: CGRect(x: 0.43, y: 0.80, width: 0.27, height: 0.10),
                        separatorBefore: " "
                    ),
                ]
            ),
        ])
        let service = OCRService(backend: backend)

        let document = try await service.recognizeDocument(in: makeSelectionCGImage())

        XCTAssertEqual(document.plainText, "First line\nSecond line")
        XCTAssertEqual(document.lines.map(\.text), ["First line", "Second line"])
        XCTAssertEqual(document.items.map(\.text), ["First", "line", "Second", "line"])
        XCTAssertEqual(
            document.items.map(\.boundingBox),
            [
                CGRect(x: 0.08, y: 0.80, width: 0.25, height: 0.10),
                CGRect(x: 0.43, y: 0.80, width: 0.27, height: 0.10),
                CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.10),
                CGRect(x: 0.48, y: 0.20, width: 0.27, height: 0.10),
            ]
        )
    }

    func testSelectedTextKeepsSourceSpacingAndReadingOrder() {
        let document = makeSelectionDocument()

        XCTAssertEqual(document.text(forItemIDs: [1, 0, 2]), "Hello world\n你好")
        XCTAssertEqual(document.text(forItemIDs: [1]), "world")
        XCTAssertEqual(document.text(forItemIDs: []), "Hello world\n你好世界")
    }

    func testDocumentFallsBackToObservationBoxWhenBackendHasNoFragments() async throws {
        let service = OCRService(
            backend: OCRDocumentBackendStub(observations: [
                OCRTextObservation(
                    text: "single observation",
                    boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.2)
                ),
            ])
        )

        let document = try await service.recognizeDocument(in: makeSelectionCGImage())

        XCTAssertEqual(document.items.count, 1)
        XCTAssertEqual(document.items.first?.text, "single observation")
        XCTAssertEqual(
            document.items.first?.boundingBox,
            CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.2)
        )
    }

    func testDocumentRejectsWhitespaceOnlyObservations() async {
        let service = OCRService(
            backend: OCRDocumentBackendStub(observations: [
                OCRTextObservation(text: " \n ", boundingBox: .zero),
            ])
        )

        do {
            _ = try await service.recognizeDocument(in: makeSelectionCGImage())
            XCTFail("Expected an explicit no-text error")
        } catch let error as OCRError {
            XCTAssertEqual(error, .noText)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class OCRSelectionModelTests: XCTestCase {
    func testNormalizedVisionCoordinatesMapIntoAspectFitAppKitRect() {
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 2_000, height: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )

        XCTAssertEqual(layout.imageRect, CGRect(x: 0, y: 100, width: 1_000, height: 500))
        XCTAssertEqual(
            layout.viewRect(forNormalizedRect: CGRect(x: 0.10, y: 0.20, width: 0.25, height: 0.10)),
            CGRect(x: 100, y: 200, width: 250, height: 50)
        )
    }

    func testRetinaPixelDimensionsDoNotShiftNormalizedSelection() {
        let oneX = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let twoX = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 2_000, height: 1_000),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let normalizedBox = CGRect(x: 0.43, y: 0.80, width: 0.27, height: 0.10)

        XCTAssertEqual(oneX.viewRect(forNormalizedRect: normalizedBox),
                       twoX.viewRect(forNormalizedRect: normalizedBox))
    }

    func testForwardAndReverseDragSelectTheSameItems() {
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        var forward = OCRSelectionModel(document: makeSelectionDocument())
        var reverse = OCRSelectionModel(document: makeSelectionDocument())

        forward.select(from: CGPoint(x: 70, y: 390), to: CGPoint(x: 720, y: 470), layout: layout)
        reverse.select(from: CGPoint(x: 720, y: 470), to: CGPoint(x: 70, y: 390), layout: layout)

        XCTAssertEqual(forward.selectedItemIDs, [0, 1])
        XCTAssertEqual(reverse.selectedItemIDs, forward.selectedItemIDs)
        XCTAssertEqual(forward.selectedText, "Hello world")
        XCTAssertEqual(reverse.selectedText, forward.selectedText)
    }

    func testSelectionIsAContinuousReadingOrderRangeAcrossLines() {
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        var forward = OCRSelectionModel(document: makeSelectionDocument())
        var reverse = OCRSelectionModel(document: makeSelectionDocument())

        forward.select(
            from: CGPoint(x: 500, y: 425),
            to: CGPoint(x: 405, y: 125),
            layout: layout
        )
        reverse.select(
            from: CGPoint(x: 405, y: 125),
            to: CGPoint(x: 500, y: 425),
            layout: layout
        )

        XCTAssertEqual(forward.selectedItemIDs, [1, 2, 3])
        XCTAssertEqual(reverse.selectedItemIDs, forward.selectedItemIDs)
        XCTAssertEqual(forward.selectedText, "world\n你好世界")
    }

    func testEmptySelectionIsDistinctFromWholeDocument() {
        var model = OCRSelectionModel(document: makeSelectionDocument())
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        model.select(from: CGPoint(x: 800, y: 20), to: CGPoint(x: 900, y: 60), layout: layout)

        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertNil(model.selectedText)
        XCTAssertEqual(model.allText, "Hello world\n你好世界")
    }

    func testDragWhoseEndpointsAreFarFromTextDoesNotSelectEnclosedItems() {
        var model = OCRSelectionModel(document: makeSelectionDocument())
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        model.select(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 990, y: 490), layout: layout)

        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertNil(model.selectedText)
    }

    func testSingleClickHitTestsOneRecognitionItem() {
        var model = OCRSelectionModel(document: makeSelectionDocument())
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )

        model.select(from: CGPoint(x: 500, y: 425), to: CGPoint(x: 500, y: 425), layout: layout)

        XCTAssertEqual(model.selectedItemIDs, [1])
        XCTAssertEqual(model.selectedText, "world")
    }

    func testSelectedTextCanBecomeAPixPinStyleExternalDragPayload() {
        var model = OCRSelectionModel(document: makeSelectionDocument())
        let layout = OCRSelectionLayout(
            imagePixelSize: CGSize(width: 1_000, height: 500),
            viewport: CGRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let point = CGPoint(x: 500, y: 425)
        model.select(from: point, to: point, layout: layout)

        XCTAssertEqual(model.selectedDragText(at: point, layout: layout), "world")
        XCTAssertNil(model.selectedDragText(at: CGPoint(x: 20, y: 20), layout: layout))
    }
}

@MainActor
final class OCRSelectionResultViewTests: XCTestCase {
    func testPixPinStyleOCRKeepsRecognitionLayerQuietUntilTextIsSelected() {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()

        XCTAssertFalse(resultView.canvasView.showsIdleRecognitionGuides)
        XCTAssertTrue(resultView.contextualActionsHidden)

        click(
            in: resultView.canvasView,
            window: window,
            at: CGPoint(x: 250, y: 225)
        )

        XCTAssertFalse(resultView.contextualActionsHidden)
        XCTAssertEqual(resultView.copySelectionButton.title, "复制")
        XCTAssertEqual(resultView.translateButton.title, "翻译")
        window.close()
    }

    func testMouseDragAndCopyButtonCopyOnlySelectedText() throws {
        _ = NSApplication.shared
        let image = NSImage(
            cgImage: makeSelectionCGImage(width: 1_000, height: 500),
            size: CGSize(width: 500, height: 250)
        )
        var copiedText: String?
        let resultView = OCRSelectionResultView(
            image: image,
            document: makeSelectionDocument(),
            copyHandler: { copiedText = $0 }
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()

        drag(
            in: resultView.canvasView,
            window: window,
            from: CGPoint(x: 40, y: 195),
            to: CGPoint(x: 360, y: 235)
        )
        resultView.copySelectionButton.performClick(nil)

        XCTAssertEqual(resultView.canvasView.selectedItemIDs, [0, 1])
        XCTAssertEqual(copiedText, "Hello world")
        window.close()
    }

    func testSelectionContinuesUpdatingAcrossMultipleDragEvents() {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()
        let canvas = resultView.canvasView

        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 40, y: 195), window: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 235), window: window))
        canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 360, y: 235), window: window))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 360, y: 235), window: window))

        XCTAssertEqual(canvas.selectedItemIDs, [0, 1])
        window.close()
    }

    func testCommandCCopiesSelectionAndConsumesShortcut() {
        _ = NSApplication.shared
        let image = NSImage(
            cgImage: makeSelectionCGImage(width: 1_000, height: 500),
            size: CGSize(width: 500, height: 250)
        )
        var copiedText: String?
        let resultView = OCRSelectionResultView(
            image: image,
            document: makeSelectionDocument(),
            copyHandler: { copiedText = $0 }
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()
        drag(
            in: resultView.canvasView,
            window: window,
            from: CGPoint(x: 215, y: 195),
            to: CGPoint(x: 360, y: 235)
        )
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!

        let handled = resultView.canvasView.performKeyEquivalent(with: event)

        XCTAssertTrue(handled)
        XCTAssertEqual(copiedText, "world")
        window.close()
    }

    func testShiftCKeyDownCopiesWholeDocument() {
        _ = NSApplication.shared
        var copiedText: String?
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument(),
            copyHandler: { copiedText = $0 }
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        let event = keyEvent(
            keyCode: 8,
            characters: "c",
            modifiers: [.shift],
            window: window
        )

        resultView.canvasView.keyDown(with: event)

        XCTAssertEqual(copiedText, "Hello world\n你好世界")
        window.close()
    }

    func testExplicitButtonsSeparateCopySelectionCopyAllAndTranslationScope() {
        _ = NSApplication.shared
        var copiedTexts: [String] = []
        var translatedTexts: [String] = []
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument(),
            copyHandler: { copiedTexts.append($0) },
            translateHandler: { translatedTexts.append($0) }
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()

        XCTAssertFalse(resultView.copySelectionButton.isEnabled)
        XCTAssertTrue(resultView.contextualActionsHidden)
        XCTAssertEqual(resultView.translateButton.title, "翻译")
        resultView.copyAllButton.performClick(nil)
        resultView.translateButton.performClick(nil)

        click(
            in: resultView.canvasView,
            window: window,
            at: CGPoint(x: 250, y: 225)
        )
        XCTAssertTrue(resultView.copySelectionButton.isEnabled)
        XCTAssertFalse(resultView.contextualActionsHidden)
        XCTAssertEqual(resultView.translateButton.title, "翻译")
        resultView.copySelectionButton.performClick(nil)
        resultView.translateButton.performClick(nil)

        XCTAssertEqual(copiedTexts, ["Hello world\n你好世界", "world"])
        XCTAssertEqual(translatedTexts, ["Hello world\n你好世界", "world"])
        window.close()
    }

    func testEscapeExitsTextSelectionModeWithoutClosingPin() {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)

        resultView.canvasView.keyDown(with: keyEvent(
            keyCode: 53,
            characters: "\u{1b}",
            modifiers: [],
            window: window
        ))

        XCTAssertFalse(resultView.canvasView.isSelectionEnabled)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(resultView.selectionModeButton.title, "选择文字")
        window.close()
    }

    func testSecondEscapeAfterLeavingSelectionModeRequestsPinClose() {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        var closeRequestCount = 0
        resultView.onClose = { closeRequestCount += 1 }

        let escape = keyEvent(
            keyCode: 53,
            characters: "\u{1b}",
            modifiers: [],
            window: window
        )
        resultView.canvasView.keyDown(with: escape)
        resultView.canvasView.keyDown(with: escape)

        XCTAssertEqual(closeRequestCount, 1)
        window.close()
    }

    func testExitedTextSelectionSupportsContextMenuAndDoubleClickClose() throws {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)
        var closeRequestCount = 0
        resultView.onClose = { closeRequestCount += 1 }
        resultView.canvasView.setSelectionEnabled(false)

        let menu = resultView.makeContextMenu()
        XCTAssertNotNil(menu.items.first(where: { $0.title == "选择文字" }))
        XCTAssertNotNil(menu.items.first(where: { $0.title == "标注" }))
        let close = try XCTUnwrap(menu.items.first(where: { $0.title == "关闭贴图" }))
        XCTAssertTrue(try sendOCRMenuAction(close))
        XCTAssertEqual(closeRequestCount, 1)

        resultView.canvasView.mouseDown(with: mouseEvent(
            .leftMouseDown,
            at: CGPoint(x: 250, y: 125),
            window: window,
            clickCount: 2
        ))
        XCTAssertEqual(closeRequestCount, 2)
        window.close()
    }

    func testOCRPinCanReenterAnnotationModeFromContextMenu() throws {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.orderFront(nil)

        let annotate = try XCTUnwrap(
            resultView.makeContextMenu().items.first(where: { $0.title == "标注" })
        )
        XCTAssertTrue(try sendOCRMenuAction(annotate))

        XCTAssertTrue(resultView.annotationEditor.isEditing)
        XCTAssertFalse(resultView.canvasView.isSelectionEnabled)
        window.close()
    }

    func testOptionDragMovesPinWithoutChangingTextSelection() {
        _ = NSApplication.shared
        let resultView = OCRSelectionResultView(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        )
        let window = makeSelectionWindow(contentView: resultView)
        window.setFrameOrigin(CGPoint(x: 100, y: 100))
        window.orderFront(nil)
        resultView.layoutSubtreeIfNeeded()
        click(
            in: resultView.canvasView,
            window: window,
            at: CGPoint(x: 250, y: 225)
        )

        drag(
            in: resultView.canvasView,
            window: window,
            from: CGPoint(x: 250, y: 225),
            to: CGPoint(x: 290, y: 255),
            modifiers: [.option]
        )

        XCTAssertEqual(window.frame.origin, CGPoint(x: 140, y: 130))
        XCTAssertEqual(resultView.canvasView.selectedItemIDs, [1])
        XCTAssertTrue(resultView.canvasView.isSelectionEnabled)
        window.close()
    }

    func testWindowManagerPresentsBorderlessFloatingResizablePinAtSourceFrame() throws {
        _ = NSApplication.shared
        let manager = OCRSelectionWindowManager()
        let image = NSImage(
            cgImage: makeSelectionCGImage(width: 1_000, height: 500),
            size: CGSize(width: 500, height: 250)
        )

        let sourceFrame = CGRect(x: 100, y: 100, width: 600, height: 300)
        let panel = try XCTUnwrap(
            manager.present(
                image: image,
                document: makeSelectionDocument(),
                sourceFrame: sourceFrame
            )
        )

        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertFalse(panel.styleMask.contains(.miniaturizable))
        XCTAssertTrue(panel.canBecomeKey)
        let contentView = try XCTUnwrap(panel.contentView as? OCRSelectionResultView)
        XCTAssertTrue(panel.firstResponder === contentView.canvasView)
        XCTAssertEqual(panel.frame, sourceFrame)
        XCTAssertEqual(panel.title, "")
        XCTAssertEqual(manager.activePanelCount, 1)

        panel.close()

        XCTAssertEqual(manager.activePanelCount, 0)
    }

    func testSmallSourceFrameExpandsToAnOperableIconToolbarWithoutOverlap() throws {
        _ = NSApplication.shared
        let manager = OCRSelectionWindowManager()
        let panel = try XCTUnwrap(manager.present(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument(),
            sourceFrame: CGRect(x: 100, y: 100, width: 60, height: 20)
        ))
        let resultView = try XCTUnwrap(panel.contentView as? OCRSelectionResultView)
        resultView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(panel.frame.width, 240)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 140)
        XCTAssertTrue(resultView.contextualActionsHidden)

        click(
            in: resultView.canvasView,
            window: panel,
            at: CGPoint(x: panel.contentLayoutRect.midX, y: panel.contentLayoutRect.midY)
        )
        resultView.layoutSubtreeIfNeeded()

        XCTAssertTrue(resultView.bounds.contains(resultView.contextualActionsFrame))
        XCTAssertFalse(
            resultView.copySelectionButton.frame.intersects(resultView.translateButton.frame)
        )
        panel.close()
    }

    func testWindowManagerRejectsInvalidImageOrEmptyDocument() {
        _ = NSApplication.shared
        let manager = OCRSelectionWindowManager()

        XCTAssertNil(manager.present(image: NSImage(size: .zero), document: makeSelectionDocument()))
        XCTAssertNil(
            manager.present(
                image: NSImage(
                    cgImage: makeSelectionCGImage(),
                    size: CGSize(width: 10, height: 5)
                ),
                document: OCRDocument(lines: [])
            )
        )
        XCTAssertEqual(manager.activePanelCount, 0)
    }

    func testWindowManagerForwardsExplicitTranslationRequest() throws {
        _ = NSApplication.shared
        let manager = OCRSelectionWindowManager()
        var translatedText: String?
        let panel = try XCTUnwrap(manager.present(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument(),
            translateHandler: { translatedText = $0 }
        ))
        let resultView = try XCTUnwrap(panel.contentView as? OCRSelectionResultView)

        resultView.translateButton.performClick(nil)

        XCTAssertEqual(translatedText, "Hello world\n你好世界")
        panel.close()
    }

    func testWindowManagerCloseButtonClosesAndUnregistersOCRPin() throws {
        _ = NSApplication.shared
        let manager = OCRSelectionWindowManager()
        let panel = try XCTUnwrap(manager.present(
            image: NSImage(
                cgImage: makeSelectionCGImage(width: 1_000, height: 500),
                size: CGSize(width: 500, height: 250)
            ),
            document: makeSelectionDocument()
        ))
        let resultView = try XCTUnwrap(panel.contentView as? OCRSelectionResultView)

        resultView.closeButton.performClick(nil)

        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(manager.activePanelCount, 0)
    }

    private func makeSelectionWindow(contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 500, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        return window
    }

    private func drag(
        in view: NSView,
        window: NSWindow,
        from start: CGPoint,
        to end: CGPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        view.mouseDown(with: mouseEvent(
            .leftMouseDown,
            at: start,
            modifiers: modifiers,
            window: window
        ))
        view.mouseDragged(with: mouseEvent(
            .leftMouseDragged,
            at: end,
            modifiers: modifiers,
            window: window
        ))
        view.mouseUp(with: mouseEvent(
            .leftMouseUp,
            at: end,
            modifiers: modifiers,
            window: window
        ))
    }

    private func click(in view: NSView, window: NSWindow, at point: CGPoint) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: CGPoint,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow,
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
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
            keyCode: keyCode
        )!
    }
}

@MainActor
private func sendOCRMenuAction(_ item: NSMenuItem) throws -> Bool {
    let action = try XCTUnwrap(item.action)
    return NSApp.sendAction(action, to: item.target, from: item)
}

private actor OCRDocumentBackendStub: OCRRecognitionBackend {
    let observations: [OCRTextObservation]

    init(observations: [OCRTextObservation]) {
        self.observations = observations
    }

    func recognizeText(in image: CGImage) async throws -> [OCRTextObservation] {
        observations
    }
}

private func makeSelectionDocument() -> OCRDocument {
    OCRDocument(lines: [
        OCRTextLine(
            index: 0,
            text: "Hello world",
            boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.62, height: 0.10),
            items: [
                OCRTextItem(
                    id: 0,
                    lineIndex: 0,
                    indexInLine: 0,
                    text: "Hello",
                    boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.25, height: 0.10)
                ),
                OCRTextItem(
                    id: 1,
                    lineIndex: 0,
                    indexInLine: 1,
                    text: "world",
                    boundingBox: CGRect(x: 0.43, y: 0.80, width: 0.27, height: 0.10),
                    separatorBefore: " "
                ),
            ]
        ),
        OCRTextLine(
            index: 1,
            text: "你好世界",
            boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.40, height: 0.10),
            items: [
                OCRTextItem(
                    id: 2,
                    lineIndex: 1,
                    indexInLine: 0,
                    text: "你好",
                    boundingBox: CGRect(x: 0.10, y: 0.20, width: 0.18, height: 0.10)
                ),
                OCRTextItem(
                    id: 3,
                    lineIndex: 1,
                    indexInLine: 1,
                    text: "世界",
                    boundingBox: CGRect(x: 0.31, y: 0.20, width: 0.19, height: 0.10)
                ),
            ]
        ),
    ])
}

private func makeSelectionCGImage(width: Int = 10, height: Int = 5) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}
