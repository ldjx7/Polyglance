import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class ScreenSelectionWindowTests: XCTestCase {
    func testVirtualDesktopWindowUsesTheCombinedCaptureFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let captureFrame = CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width + 1920,
            height: max(screen.frame.height, 1080)
        )
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 448, height: 144),
            screen: screen,
            captureFrame: captureFrame
        )

        XCTAssertEqual(window.frame, captureFrame)
        XCTAssertEqual(window.selectionView.frame.size, captureFrame.size)
    }

    func testVirtualDesktopWindowIsNotConstrainedBackOntoOneDisplay() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let captureFrame = CGRect(x: -1920, y: 0, width: 4480, height: 1440)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 448, height: 144),
            screen: screen,
            captureFrame: captureFrame
        )

        XCTAssertEqual(window.constrainFrameRect(captureFrame, to: screen), captureFrame)
    }

    func testGlobalDragTrackingFinishesSelectionAcrossTheDisplaySeam() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let captureFrame = CGRect(x: -1920, y: 0, width: 4480, height: 1440)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 448, height: 144),
            screen: screen,
            captureFrame: captureFrame
        )
        window.orderFront(nil)
        let start = CGPoint(x: 40, y: 100)
        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: start, window: window)
        )
        let globalEnd = CGPoint(x: captureFrame.maxX - 60, y: captureFrame.minY + 600)

        window.selectionView.advanceGlobalDragForTesting(
            globalPoint: globalEnd,
            leftButtonPressed: true
        )
        window.selectionView.advanceGlobalDragForTesting(
            globalPoint: globalEnd,
            leftButtonPressed: false
        )

        let selection = try XCTUnwrap(window.selectionView.confirmedSelection)
        XCTAssertGreaterThan(selection.maxX, screen.frame.width)
    }

    func testCrossScreenToolbarStaysInsideTheDisplayWhereDragStarted() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let captureFrame = CGRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: screen.frame.width + 1920,
            height: max(screen.frame.height, 1080)
        )
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 448, height: 144),
            screen: screen,
            captureFrame: captureFrame
        )
        window.orderFront(nil)
        let localScreen = screen.frame.offsetBy(dx: -captureFrame.minX, dy: -captureFrame.minY)
        let start = CGPoint(x: localScreen.minX + 30, y: 100)
        let end = CGPoint(x: captureFrame.width - 30, y: 700)

        dragSelection(in: window, from: start, to: end)

        XCTAssertTrue(localScreen.contains(window.selectionView.toolbarFrameForTesting))
    }

    func testWindowConstructsWithCapturedImage() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(
            image: try makeImage(),
            screen: screen
        )

        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertTrue(window.contentView === window.selectionView)
    }

    func testSelectionWindowDoesNotActivatePolyglanceOverTheCapturedApplication() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(), screen: screen)

        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
    }

    func testSelectionWaitsForExplicitCopyAction() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 200, height: 100), screen: screen)
        var receivedAction: ScreenshotSelectionAction?
        window.onAction = { receivedAction = $0 }
        window.orderFront(nil)

        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        XCTAssertNil(receivedAction)
        let toolbar = try XCTUnwrap(window.selectionView.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertFalse(toolbar.isHidden)

        try button(titled: "复制", in: toolbar).performClick(nil)
        guard case let .copy(result) = receivedAction else {
            return XCTFail("Expected an explicit copy action")
        }
        XCTAssertGreaterThan(result.image.representations.first?.pixelsWide ?? 0, 0)
    }

    func testSaveButtonEmitsExplicitSaveAction() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 200, height: 100), screen: screen)
        var receivedAction: ScreenshotSelectionAction?
        window.onAction = { receivedAction = $0 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        try button(titled: "保存", in: toolbar(in: window)).performClick(nil)

        guard case let .save(result) = receivedAction else {
            return XCTFail("Expected an explicit save action")
        }
        XCTAssertGreaterThan(result.image.representations.first?.pixelsWide ?? 0, 0)
    }

    func testOCRLongScreenshotAndRecordingButtonsEmitDedicatedActions() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)

        let actionCases: [(String, (ScreenshotSelectionAction?) -> Bool)] = [
            ("OCR", { if case .ocrCopy = $0 { return true }; return false }),
            ("OCR翻译", { if case .ocrTranslate = $0 { return true }; return false }),
            ("长截图", { if case .longScreenshot = $0 { return true }; return false }),
            ("录屏", { if case .screenRecording = $0 { return true }; return false }),
        ]
        for (title, assertion) in actionCases {
            let window = ScreenSelectionWindow(
                image: try makeImage(width: 200, height: 100),
                screen: screen
            )
            var receivedAction: ScreenshotSelectionAction?
            window.onAction = { receivedAction = $0 }
            window.orderFront(nil)
            dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

            try button(titled: title, in: toolbar(in: window)).performClick(nil)

            XCTAssertTrue(assertion(receivedAction), "Expected \(title) to emit its dedicated action")
        }
    }

    func testPixPinStyleOCRAndRecordingShortcutsEmitSelectionActions() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let shortcuts: [(String, UInt16, NSEvent.ModifierFlags, (ScreenshotSelectionAction?) -> Bool)] = [
            ("C", 8, [.shift], { if case .ocrCopyAll = $0 { return true }; return false }),
            ("q", 12, [.option], { if case .ocrTranslate = $0 { return true }; return false }),
            ("g", 5, [], { if case .screenRecording = $0 { return true }; return false }),
        ]

        for (characters, keyCode, modifiers, assertion) in shortcuts {
            let window = ScreenSelectionWindow(
                image: try makeImage(width: 200, height: 100),
                screen: screen
            )
            var receivedAction: ScreenshotSelectionAction?
            window.onAction = { receivedAction = $0 }
            window.orderFront(nil)
            dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

            window.selectionView.keyDown(with: characterKeyEvent(
                characters,
                keyCode: keyCode,
                modifiers: modifiers,
                window: window
            ))

            XCTAssertTrue(assertion(receivedAction), "Expected \(characters) to emit its PixPin-style action")
        }
    }

    func testScreenshotToolbarUsesIconOnlyButtonsWithHoverHelpAndAccessibilityLabels() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 300, height: 180),
            screen: screen
        )
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 260, y: 150))

        let buttons = allButtons(in: try toolbar(in: window))
        XCTAssertGreaterThanOrEqual(buttons.count, 16)
        for button in buttons {
            XCTAssertFalse(button.isBordered, "\(button.title) should be a frameless icon button")
            XCTAssertEqual(button.imagePosition, .imageOnly, "\(button.title) should not repeat text beside its icon")
            XCTAssertNotNil(button.image, "\(button.title) needs a meaningful SF Symbol")
            XCTAssertEqual(button.toolTip, button.title)
            XCTAssertEqual(button.accessibilityHelp(), button.title)
            XCTAssertFalse(button.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    func testPreferredRecordingActionCompletesImmediatelyAfterRegionSelection() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 200, height: 100),
            screen: screen,
            preferredAction: .screenRecording
        )
        var receivedAction: ScreenshotSelectionAction?
        window.onAction = { receivedAction = $0 }
        window.orderFront(nil)

        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        guard case .screenRecording = receivedAction else {
            return XCTFail("Expected direct recording action after selecting a region")
        }
    }

    func testAnnotationToolbarSelectsShapesAndProvidesUndoRedo() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let toolbar = try toolbar(in: window)

        for title in ["画笔", "矩形", "椭圆", "箭头", "文字", "马赛克", "撤销", "重做"] {
            _ = try button(titled: title, in: toolbar)
        }

        try button(titled: "矩形", in: toolbar).performClick(nil)
        XCTAssertEqual(window.selectionView.selectedAnnotationTool, .rectangle)
        XCTAssertEqual(
            window.selectionView.capturePhase,
            .annotating(CGRect(x: 20, y: 20, width: 200, height: 100))
        )

        dragSelection(in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 90))
        XCTAssertEqual(window.selectionView.annotationElements.count, 1)
        guard case .rectangle = window.selectionView.annotationElements[0] else {
            return XCTFail("Expected the selected rectangle tool to create a rectangle")
        }

        let undoButton = try button(titled: "撤销", in: toolbar)
        let redoButton = try button(titled: "重做", in: toolbar)
        XCTAssertTrue(undoButton.isEnabled)
        XCTAssertFalse(redoButton.isEnabled)

        undoButton.performClick(nil)
        XCTAssertTrue(window.selectionView.annotationElements.isEmpty)
        XCTAssertTrue(redoButton.isEnabled)

        redoButton.performClick(nil)
        XCTAssertEqual(window.selectionView.annotationElements.count, 1)
    }

    func testAnnotationModeKeepsAccentSelectionBorderAndResizeHandles() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        try button(titled: "矩形", in: toolbar(in: window)).performClick(nil)

        XCTAssertTrue(window.selectionView.selectionBorderColor.isEqual(NSColor.controlAccentColor))
        XCTAssertTrue(window.selectionView.showsSelectionHandles)
    }

    func testAnnotationModePrioritizesSelectionEdgeResizeOverDrawing() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        try button(titled: "矩形", in: toolbar(in: window)).performClick(nil)
        dragSelection(in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 90))

        dragSelection(in: window, from: CGPoint(x: 220, y: 70), to: CGPoint(x: 270, y: 70))

        XCTAssertEqual(
            window.selectionView.capturePhase,
            .annotating(CGRect(x: 20, y: 20, width: 250, height: 100))
        )
        XCTAssertEqual(window.selectionView.annotationElements.count, 1)
        let rectangle = try rectangleEndpoints(in: window.selectionView)
        XCTAssertEqual(rectangle.start, CGPoint(x: 40, y: 40))
        XCTAssertEqual(rectangle.end, CGPoint(x: 120, y: 90))
    }

    func testPinActionUsesTheCompositedImageWithAnnotations() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        var pinnedImage: NSImage?
        window.onAction = { action in
            guard case let .pin(result) = action else { return }
            pinnedImage = result.image
        }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let captureToolbar = try toolbar(in: window)
        try button(titled: "矩形", in: captureToolbar).performClick(nil)
        dragSelection(in: window, from: CGPoint(x: 40, y: 40), to: CGPoint(x: 120, y: 90))
        XCTAssertEqual(window.selectionView.annotationElements.count, 1)

        try button(titled: "贴图", in: captureToolbar).performClick(nil)

        let output = try XCTUnwrap(pinnedImage)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: output.tiffRepresentation!))
        var containsRedAnnotationPixel = false
        for y in 0..<representation.pixelsHigh where !containsRedAnnotationPixel {
            for x in 0..<representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.7,
                   color.redComponent - color.greenComponent > 0.25,
                   color.redComponent - color.blueComponent > 0.25 {
                    containsRedAnnotationPixel = true
                    break
                }
            }
        }
        XCTAssertTrue(containsRedAnnotationPixel, "Pinned output must contain the committed annotation layer")
    }

    func testAnnotationButtonsUseUniformTintWithoutToggleDrawingOverride() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let toolbar = try toolbar(in: window)
        let mosaicButton = try button(titled: "马赛克", in: toolbar)

        let defaultTint = try XCTUnwrap(mosaicButton.contentTintColor)
        for candidate in allButtons(in: toolbar) where candidate.isEnabled {
            XCTAssertTrue(
                candidate.contentTintColor?.isEqual(defaultTint) == true,
                "\(candidate.title) should use the common enabled icon tint"
            )
        }

        mosaicButton.performClick(nil)

        XCTAssertEqual(mosaicButton.state, .off, "selection must not invoke AppKit toggle artwork")
        XCTAssertTrue(mosaicButton.contentTintColor?.isEqual(NSColor.systemBlue) == true || mosaicButton.contentTintColor?.isEqual(NSColor.controlAccentColor) == true)
        for candidate in allButtons(in: toolbar) where candidate !== mosaicButton && candidate.isEnabled {
            XCTAssertTrue(
                candidate.contentTintColor?.isEqual(defaultTint) == true,
                "\(candidate.title) should remain visually consistent"
            )
        }
    }

    func testTextInputCommitsToHistoryWhileBlankAndEscapeCancelOnlyTheInput() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        var cancellationCount = 0
        window.onCancel = { cancellationCount += 1 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let toolbar = try toolbar(in: window)
        try button(titled: "文字", in: toolbar).performClick(nil)

        click(in: window, at: CGPoint(x: 40, y: 40))
        let committedField = try XCTUnwrap(window.selectionView.activeTextField)
        committedField.stringValue = "Retina text"
        XCTAssertTrue(committedField.sendAction(committedField.action, to: committedField.target))

        XCTAssertNil(window.selectionView.activeTextField)
        XCTAssertEqual(window.selectionView.annotationElements.count, 1)
        guard case let .text(origin, text, _) = window.selectionView.annotationElements[0] else {
            return XCTFail("Expected a text annotation")
        }
        XCTAssertEqual(origin, CGPoint(x: 40, y: 40))
        XCTAssertEqual(text, "Retina text")
        let undoButton = try button(titled: "撤销", in: toolbar)
        XCTAssertTrue(undoButton.isEnabled)
        undoButton.performClick(nil)
        XCTAssertTrue(window.selectionView.annotationElements.isEmpty)

        click(in: window, at: CGPoint(x: 60, y: 50))
        let blankField = try XCTUnwrap(window.selectionView.activeTextField)
        blankField.stringValue = " \n\t "
        XCTAssertTrue(blankField.sendAction(blankField.action, to: blankField.target))
        XCTAssertTrue(window.selectionView.annotationElements.isEmpty)
        XCTAssertNil(window.selectionView.activeTextField)

        click(in: window, at: CGPoint(x: 80, y: 60))
        XCTAssertNotNil(window.selectionView.activeTextField)
        window.selectionView.keyDown(with: escapeKeyEvent(window: window))

        XCTAssertNil(window.selectionView.activeTextField)
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(
            window.selectionView.capturePhase,
            .annotating(CGRect(x: 20, y: 20, width: 200, height: 100))
        )
    }

    func testMosaicDragFollowsThePointerPathAndAddsOneUndoableStroke() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let toolbar = try toolbar(in: window)
        try button(titled: "马赛克", in: toolbar).performClick(nil)

        let points = [
            CGPoint(x: 40, y: 40),
            CGPoint(x: 75, y: 85),
            CGPoint(x: 115, y: 45),
            CGPoint(x: 160, y: 90),
        ]
        window.selectionView.mouseDown(with: mouseEvent(.leftMouseDown, at: points[0], window: window))
        for point in points.dropFirst() {
            window.selectionView.mouseDragged(with: mouseEvent(.leftMouseDragged, at: point, window: window))
        }
        window.selectionView.mouseUp(with: mouseEvent(.leftMouseUp, at: points.last!, window: window))

        XCTAssertEqual(window.selectionView.annotationElements.count, 1)
        guard case let .mosaic(strokePoints, _) = window.selectionView.annotationElements[0] else {
            return XCTFail("Expected a mosaic annotation")
        }
        XCTAssertEqual(strokePoints, points)

        let undoButton = try button(titled: "撤销", in: toolbar)
        XCTAssertTrue(undoButton.isEnabled)
        undoButton.performClick(nil)
        XCTAssertTrue(window.selectionView.annotationElements.isEmpty)
    }

    func testReadyAndDragPhasesShowRetinaMagnifierAndColorShortcutsAreUnambiguous() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let image = try makeImage(width: 400, height: 300, color: { x, y in
            x == 100 && y == 200 ? (0x12, 0x34, 0x56) : (0xFF, 0xFF, 0xFF)
        })
        let window = ScreenSelectionWindow(
            image: image,
            screen: screen,
            colorPasteboard: pasteboard
        )
        window.orderFront(nil)
        window.selectionView.setFrameSize(CGSize(width: 200, height: 150))

        window.selectionView.mouseMoved(
            with: mouseEvent(.mouseMoved, at: CGPoint(x: 50, y: 50), window: window)
        )

        let sample = try XCTUnwrap(window.selectionView.currentPixelSample)
        XCTAssertEqual(sample.coordinate, PixelCoordinate(x: 100, y: 200))
        XCTAssertEqual(sample.hex, "#123456")
        XCTAssertEqual(window.selectionView.colorDisplayFormat, .hex)
        let magnifier = try XCTUnwrap(
            window.selectionView.subviews.compactMap { $0 as? ScreenshotMagnifierView }.first
        )
        XCTAssertFalse(magnifier.isHidden)
        XCTAssertTrue(magnifier.displayText.contains("#123456"))
        XCTAssertTrue(magnifier.displayText.contains("100, 200"))
        // The coordinate and the colour each own a line: together they overflow
        // the panel and the value was clipped mid-way.
        XCTAssertEqual(magnifier.coordinateText, "(100, 200) px")
        XCTAssertEqual(magnifier.colorText, "#123456")
        XCTAssertEqual(magnifier.instructionText, "C 复制色值 · ⇧C 切换 HEX/RGB")

        window.selectionView.keyDown(with: characterKeyEvent(
            "c",
            keyCode: 8,
            window: window
        ))
        XCTAssertEqual(pasteboard.string(forType: .string), "#123456")
        XCTAssertEqual(magnifier.instructionText, "已复制 #123456")

        window.selectionView.keyDown(with: characterKeyEvent(
            "C",
            keyCode: 8,
            modifiers: [.shift],
            window: window
        ))
        XCTAssertEqual(window.selectionView.colorDisplayFormat, .rgb)
        XCTAssertTrue(magnifier.displayText.contains("RGB(18, 52, 86)"))
        // The longest value the panel has to hold, and the reason the readout
        // no longer shares a line with the coordinate.
        XCTAssertEqual(magnifier.colorText, "RGB(18, 52, 86)")

        pasteboard.clearContents()
        window.selectionView.keyDown(with: characterKeyEvent(
            "c",
            keyCode: 8,
            window: window
        ))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "RGB(18, 52, 86)",
            "Copy must follow the displayed format instead of always copying HEX"
        )

        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        window.selectionView.keyDown(with: characterKeyEvent(
            "c",
            keyCode: 8,
            modifiers: [.command],
            window: window
        ))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "keep",
            "Command-C remains available to screenshot/app commands and is not color-copy"
        )

        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: 30, y: 30), window: window)
        )
        window.selectionView.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 80, y: 80), window: window)
        )
        XCTAssertFalse(magnifier.isHidden)
        window.selectionView.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: 80, y: 80), window: window)
        )
        XCTAssertTrue(magnifier.isHidden)
    }

    func testDraggingAnnotatedSelectionInteriorTranslatesAnnotationWithContent() throws {
        let window = try makeWindowWithRectangleAnnotation()

        dragSelection(
            in: window,
            from: CGPoint(x: 180, y: 100),
            to: CGPoint(x: 210, y: 120)
        )

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 50, y: 40, width: 200, height: 100)
        )
        let rectangle = try rectangleEndpoints(in: window.selectionView)
        XCTAssertEqual(rectangle.start, CGPoint(x: 70, y: 60))
        XCTAssertEqual(rectangle.end, CGPoint(x: 150, y: 110))
    }

    func testDraggingAnnotatedSelectionEdgeKeepsAnnotationAtAbsoluteScreenCoordinates() throws {
        let window = try makeWindowWithRectangleAnnotation()

        dragSelection(
            in: window,
            from: CGPoint(x: 220, y: 70),
            to: CGPoint(x: 270, y: 70)
        )

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 250, height: 100)
        )
        let rectangle = try rectangleEndpoints(in: window.selectionView)
        XCTAssertEqual(rectangle.start, CGPoint(x: 40, y: 40))
        XCTAssertEqual(rectangle.end, CGPoint(x: 120, y: 90))
    }

    func testDraggingOutsideAnnotatedSelectionKeepsAnnotationAtAbsoluteScreenCoordinates() throws {
        let window = try makeWindowWithRectangleAnnotation()

        dragSelection(
            in: window,
            from: CGPoint(x: 250, y: 70),
            to: CGPoint(x: 280, y: 70)
        )

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 260, height: 100)
        )
        let rectangle = try rectangleEndpoints(in: window.selectionView)
        XCTAssertEqual(rectangle.start, CGPoint(x: 40, y: 40))
        XCTAssertEqual(rectangle.end, CGPoint(x: 120, y: 90))
    }

    func testKeyboardExpansionKeepsAnnotationAtAbsoluteScreenCoordinates() throws {
        let window = try makeWindowWithRectangleAnnotation()

        window.selectionView.keyDown(
            with: arrowKeyEvent(.right, modifiers: [.command], window: window)
        )

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 201, height: 100)
        )
        let rectangle = try rectangleEndpoints(in: window.selectionView)
        XCTAssertEqual(rectangle.start, CGPoint(x: 40, y: 40))
        XCTAssertEqual(rectangle.end, CGPoint(x: 120, y: 90))
    }

    func testCaptureViewAcceptsTheFirstMouseEventAfterShortcutActivation() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(), screen: screen)

        XCTAssertTrue(window.selectionView.acceptsFirstMouse(for: nil))
    }

    func testRightClickAfterSelectingRegionReturnsToInitialStateBeforeCancelling() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 200, height: 100), screen: screen)
        var cancellationCount = 0
        window.onCancel = { cancellationCount += 1 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.rightMouseDown(
            with: mouseEvent(.rightMouseDown, at: CGPoint(x: 100, y: 80), window: window)
        )

        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(window.selectionView.capturePhase, .ready)
        XCTAssertNil(window.selectionView.confirmedSelection)
        XCTAssertEqual(window.selectionView.cursorMode, .crosshair)
        XCTAssertTrue(try toolbar(in: window).isHidden)

        window.selectionView.rightMouseDown(
            with: mouseEvent(.rightMouseDown, at: CGPoint(x: 100, y: 80), window: window)
        )

        XCTAssertEqual(cancellationCount, 1)
    }

    func testCurrentScreenStartsBrightAndOnlyDimsAfterASelectionBegins() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 300, height: 200), screen: screen)
        window.orderFront(nil)

        XCTAssertFalse(window.selectionView.dimsCurrentScreen)

        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        XCTAssertTrue(window.selectionView.dimsCurrentScreen)

        window.selectionView.rightMouseDown(
            with: mouseEvent(.rightMouseDown, at: CGPoint(x: 100, y: 80), window: window)
        )
        XCTAssertFalse(window.selectionView.dimsCurrentScreen)
    }

    func testEscapeAlwaysCancelsInsteadOfReturningToInitialState() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 200, height: 100), screen: screen)
        var cancellationCount = 0
        window.onCancel = { cancellationCount += 1 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.keyDown(with: escapeKeyEvent(window: window))

        XCTAssertEqual(cancellationCount, 1)
    }

    func testArrowKeysMoveSelectedRegionByOnePointAndOptionAcceleratesToTen() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.keyDown(with: arrowKeyEvent(.right, window: window))
        window.selectionView.keyDown(with: arrowKeyEvent(.up, modifiers: [.option], window: window))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 21, y: 30, width: 200, height: 100)
        )
        XCTAssertFalse(try toolbar(in: window).isHidden)
    }

    func testShiftArrowShrinksAndCommandArrowExpandsTheCorrespondingEdge() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.keyDown(with: arrowKeyEvent(.left, modifiers: [.shift], window: window))
        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 21, y: 20, width: 199, height: 100)
        )

        window.selectionView.keyDown(with: arrowKeyEvent(.right, modifiers: [.command], window: window))
        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 21, y: 20, width: 200, height: 100)
        )
    }

    func testArrowKeyUsesHalfPointForOnePhysicalPixelOnRetinaCapture() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let retinaWidth = max(1, Int(screen.frame.width * 2))
        let window = ScreenSelectionWindow(
            image: try makeImage(width: retinaWidth, height: 1),
            screen: screen
        )
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.keyDown(with: arrowKeyEvent(.right, window: window))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20.5, y: 20, width: 200, height: 100)
        )
    }

    func testSingleClickConfirmsCandidateAtMousePosition() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let candidate = CGRect(x: 40, y: 50, width: 160, height: 90)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 400, height: 300),
            screen: screen,
            regionProvider: { point in
                candidate.contains(point) ? candidate : nil
            }
        )
        window.orderFront(nil)

        click(in: window, at: CGPoint(x: 100, y: 80))

        XCTAssertEqual(window.selectionView.capturePhase, .selected(candidate))
        XCTAssertEqual(window.selectionView.confirmedSelection, candidate)
        XCTAssertEqual(window.selectionView.cursorMode, .arrow)
        XCTAssertFalse(try toolbar(in: window).isHidden)
    }

    func testElementRefinementUpdatesHoverCandidateAsynchronously() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let windowCandidate = CGRect(x: 0, y: 0, width: 500, height: 400)
        let elementCandidate = CGRect(x: 40, y: 50, width: 120, height: 60)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 500, height: 400),
            screen: screen,
            regionProvider: { _ in windowCandidate },
            regionRefiner: { _ in elementCandidate }
        )

        window.selectionView.mouseMoved(
            with: mouseEvent(.mouseMoved, at: CGPoint(x: 80, y: 80), window: window)
        )

        XCTAssertEqual(window.selectionView.hoveredCandidate, windowCandidate)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(window.selectionView.hoveredCandidate, elementCandidate)
    }

    func testDragOverridesCandidateAtMousePosition() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let candidate = CGRect(x: 0, y: 0, width: 500, height: 400)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 500, height: 400),
            screen: screen,
            regionProvider: { _ in candidate }
        )
        window.orderFront(nil)

        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 200, height: 100)
        )
    }

    func testRightClickWhileDraggingReturnsToReadyAndIgnoresFollowingMouseUp() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 300, height: 200), screen: screen)
        var cancellationCount = 0
        window.onCancel = { cancellationCount += 1 }
        window.orderFront(nil)
        let view = window.selectionView

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 20, y: 20), window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 180, y: 100), window: window))
        view.rightMouseDown(with: mouseEvent(.rightMouseDown, at: CGPoint(x: 180, y: 100), window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 180, y: 100), window: window))

        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(view.capturePhase, .ready)
        XCTAssertNil(view.confirmedSelection)
    }

    func testLeftClickOutsideSelectionExpandsTowardMouseInsteadOfReplacingCandidate() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let first = CGRect(x: 20, y: 20, width: 120, height: 80)
        let second = CGRect(x: 220, y: 120, width: 100, height: 70)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 400, height: 300),
            screen: screen,
            regionProvider: { point in point.x < 180 ? first : second }
        )
        window.orderFront(nil)
        click(in: window, at: CGPoint(x: 60, y: 60))

        click(in: window, at: CGPoint(x: 250, y: 170))

        let expandedSelection = CGRect(x: 20, y: 20, width: 230, height: 150)
        XCTAssertEqual(window.selectionView.confirmedSelection, expandedSelection)
        XCTAssertEqual(window.selectionView.capturePhase, .selected(expandedSelection))
    }

    func testClickJustOutsideResizeHandleStillExpandsToExactPoint() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        click(in: window, at: CGPoint(x: 223, y: 70))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 203, height: 100)
        )
    }

    func testOutsideExpansionGestureCannotShrinkPastOriginalSelection() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        let originalSelection = CGRect(x: 20, y: 20, width: 200, height: 100)
        dragSelection(
            in: window,
            from: originalSelection.origin,
            to: CGPoint(x: originalSelection.maxX, y: originalSelection.maxY)
        )
        let view = window.selectionView

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 260, y: 70), window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 100, y: 70), window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: CGPoint(x: 100, y: 70), window: window))

        XCTAssertEqual(view.confirmedSelection, originalSelection)
    }

    func testDoubleClickOutsideSelectionExpandsWithoutAccidentallyCopying() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        var receivedAction: ScreenshotSelectionAction?
        window.onAction = { receivedAction = $0 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let view = window.selectionView

        view.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: 250, y: 70), window: window)
        )
        view.mouseUp(
            with: mouseEvent(.leftMouseUp, at: CGPoint(x: 250, y: 70), window: window)
        )
        view.mouseDown(
            with: mouseEvent(
                .leftMouseDown,
                at: CGPoint(x: 249, y: 70),
                window: window,
                clickCount: 2
            )
        )
        view.mouseUp(
            with: mouseEvent(
                .leftMouseUp,
                at: CGPoint(x: 249, y: 70),
                window: window,
                clickCount: 2
            )
        )

        XCTAssertNil(receivedAction)
        XCTAssertEqual(
            view.confirmedSelection,
            CGRect(x: 20, y: 20, width: 230, height: 100)
        )
    }

    func testDraggingInsideSelectedRegionMovesIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        dragSelection(in: window, from: CGPoint(x: 100, y: 70), to: CGPoint(x: 150, y: 110))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 70, y: 60, width: 200, height: 100)
        )
        XCTAssertFalse(try toolbar(in: window).isHidden)
    }

    func testDraggingSelectedRegionEdgeResizesIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        dragSelection(in: window, from: CGPoint(x: 220, y: 70), to: CGPoint(x: 270, y: 70))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 250, height: 100)
        )
        XCTAssertFalse(try toolbar(in: window).isHidden)
    }

    func testDraggingFromOuterHalfOfSelectionEdgeCanShrinkIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        // The visible 6pt handle straddles the selection border. Starting on
        // its outer half must still be a resize gesture, not an outward-only
        // click expansion.
        dragSelection(in: window, from: CGPoint(x: 223, y: 70), to: CGPoint(x: 170, y: 70))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 147, height: 100)
        )
    }

    func testDraggingFromOuterHalfOfCornerCanShrinkBothDimensions() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        dragSelection(in: window, from: CGPoint(x: 223, y: 123), to: CGPoint(x: 170, y: 90))

        XCTAssertEqual(
            window.selectionView.confirmedSelection,
            CGRect(x: 20, y: 20, width: 147, height: 67)
        )
    }

    func testHandleDragThatCrossesThresholdDoesNotBecomeClickExpansionAfterReturning() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        let selection = CGRect(x: 20, y: 20, width: 200, height: 100)
        dragSelection(
            in: window,
            from: selection.origin,
            to: CGPoint(x: selection.maxX, y: selection.maxY)
        )
        let view = window.selectionView
        let handlePoint = CGPoint(x: selection.maxX + 3, y: selection.midY)

        view.mouseDown(with: mouseEvent(.leftMouseDown, at: handlePoint, window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 170, y: 70), window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: handlePoint, window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: handlePoint, window: window))

        XCTAssertEqual(view.confirmedSelection, selection)
    }

    func testToolbarHoverShowsVisibleHelpAndLeavingHidesIt() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let copyButton = try button(titled: "复制", in: toolbar)

        copyButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))

        XCTAssertEqual(window.selectionView.visibleToolbarHelpText, copyButton.toolTip)

        copyButton.mouseExited(with: mouseEvent(.mouseMoved, at: .zero, window: window))

        XCTAssertNil(window.selectionView.visibleToolbarHelpText)
    }

    func testLeavingAnOldToolbarButtonDoesNotHideTheNewButtonsHelp() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let copyButton = try button(titled: "复制", in: toolbar)
        let saveButton = try button(titled: "保存", in: toolbar)

        copyButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))
        saveButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))
        copyButton.mouseExited(with: mouseEvent(.mouseMoved, at: .zero, window: window))

        XCTAssertEqual(window.selectionView.visibleToolbarHelpText, saveButton.toolTip)
    }

    func testDisabledToolbarButtonStillProvidesHoverHelp() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let undoButton = try button(titled: "撤销", in: toolbar)
        XCTAssertFalse(undoButton.isEnabled)

        undoButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))

        XCTAssertEqual(window.selectionView.visibleToolbarHelpText, undoButton.toolTip)
    }

    func testToolbarHelpBubbleStaysOnScreenAndDoesNotInterceptClicks() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))
        window.selectionView.setFrameSize(CGSize(width: 320, height: 240))
        window.selectionView.layoutSubtreeIfNeeded()
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let cancelButton = try button(titled: "取消", in: toolbar)

        cancelButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))

        let bubble = try XCTUnwrap(
            window.selectionView.subviews.compactMap { $0 as? ScreenshotToolbarHelpBubble }.first
        )
        XCTAssertFalse(bubble.isHidden)
        XCTAssertTrue(window.selectionView.bounds.contains(bubble.frame))
        XCTAssertNil(bubble.hitTest(CGPoint(x: bubble.bounds.midX, y: bubble.bounds.midY)))
    }

    func testBeginningAResizeHidesToolbarHelp() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let copyButton = try button(titled: "复制", in: toolbar)
        copyButton.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, window: window))
        XCTAssertNotNil(window.selectionView.visibleToolbarHelpText)

        window.selectionView.mouseDown(
            with: mouseEvent(.leftMouseDown, at: CGPoint(x: 220, y: 70), window: window)
        )

        XCTAssertNil(window.selectionView.visibleToolbarHelpText)
    }

    func testToolbarPaddingDoesNotStartAnotherSelection() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let selection = CGRect(x: 20, y: 20, width: 200, height: 100)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: selection.origin, to: CGPoint(x: selection.maxX, y: selection.maxY))
        let toolbar = try toolbar(in: window)
        let paddingPoint = CGPoint(x: toolbar.frame.minX + 2, y: toolbar.frame.minY + 2)

        window.sendEvent(mouseEvent(.leftMouseDown, at: paddingPoint, window: window))
        window.sendEvent(mouseEvent(.leftMouseUp, at: paddingPoint, window: window))

        XCTAssertEqual(window.selectionView.capturePhase, .selected(selection))
        XCTAssertEqual(window.selectionView.confirmedSelection, selection)
        XCTAssertFalse(toolbar.isHidden)
    }

    func testToolbarFitsInsideANarrowCaptureView() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))

        window.selectionView.setFrameSize(CGSize(width: 640, height: 480))
        window.selectionView.layoutSubtreeIfNeeded()
        let toolbar = try toolbar(in: window)

        XCTAssertLessThanOrEqual(toolbar.frame.maxX, window.selectionView.bounds.maxX - 8)
        XCTAssertGreaterThanOrEqual(toolbar.frame.minX, window.selectionView.bounds.minX + 8)
        XCTAssertEqual(toolbar.frame.width, 624)
    }

    func testToolbarUsesTwoIconRowsWithoutClippingButtonsOnVeryNarrowScreen() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 400, height: 300), screen: screen)
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 80), to: CGPoint(x: 220, y: 180))

        window.selectionView.setFrameSize(CGSize(width: 320, height: 240))
        window.selectionView.layoutSubtreeIfNeeded()
        let toolbar = try toolbar(in: window)
        toolbar.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: toolbar)

        XCTAssertGreaterThanOrEqual(buttons.count, 12)
        XCTAssertTrue(Set(buttons.map(\.title)).isSuperset(of: [
            "画笔", "矩形", "椭圆", "箭头", "文字", "马赛克",
            "撤销", "重做", "复制", "保存", "贴图", "取消",
        ]))
        XCTAssertLessThanOrEqual(toolbar.frame.maxX, window.selectionView.bounds.maxX - 8)
        XCTAssertGreaterThanOrEqual(toolbar.frame.minX, window.selectionView.bounds.minX + 8)
        for button in buttons {
            XCTAssertFalse(button.isHidden, button.title)
            XCTAssertEqual(button.imagePosition, .imageOnly, button.title)
            XCTAssertEqual(button.toolTip, button.title)
            let frameInToolbar = button.convert(button.bounds, to: toolbar)
            XCTAssertTrue(
                toolbar.bounds.contains(frameInToolbar),
                "\(button.title) is clipped outside the compact toolbar"
            )
        }
    }

    func testRightClickFromInactiveScreenUsesBackThenCancelSemantics() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 300, height: 200), screen: screen)
        var cancellationCount = 0
        window.onCancel = { cancellationCount += 1 }
        window.orderFront(nil)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))

        window.selectionView.handleRightClickOutsideTargetScreen()

        XCTAssertEqual(window.selectionView.capturePhase, .ready)
        XCTAssertEqual(cancellationCount, 0)

        window.selectionView.handleRightClickOutsideTargetScreen()

        XCTAssertEqual(cancellationCount, 1)
    }

    func testCursorChangesFromCrosshairToArrowAfterSelection() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(image: try makeImage(width: 200, height: 100), screen: screen)
        window.orderFront(nil)

        XCTAssertEqual(window.selectionView.cursorMode, .crosshair)
        dragSelection(in: window, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 220, y: 120))
        XCTAssertEqual(window.selectionView.cursorMode, .arrow)
    }

    func testComposerPreservesResolutionAndDrawsRedAnnotation() throws {
        let image = try makeImage(width: 100, height: 100)
        let output = try XCTUnwrap(ScreenshotImageComposer.compose(
            image: image,
            selection: CGRect(x: 0, y: 0, width: 100, height: 100),
            strokes: [ScreenshotAnnotationStroke(points: [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 90, y: 90),
            ])]
        ))

        XCTAssertEqual(output.width, 100)
        XCTAssertEqual(output.height, 100)
        let bitmap = NSBitmapImageRep(cgImage: output)
        let centerColor = try XCTUnwrap(bitmap.colorAt(x: 50, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(centerColor.redComponent, 0.8)
        XCTAssertLessThan(centerColor.greenComponent, 0.4)
    }

    private func dragSelection(in window: ScreenSelectionWindow, from start: CGPoint, to end: CGPoint) {
        let view = window.selectionView
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, window: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, window: window))
    }

    private func makeWindowWithRectangleAnnotation() throws -> ScreenSelectionWindow {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenSelectionWindow(
            image: try makeImage(width: 400, height: 300),
            screen: screen
        )
        window.orderFront(nil)
        dragSelection(
            in: window,
            from: CGPoint(x: 20, y: 20),
            to: CGPoint(x: 220, y: 120)
        )
        try button(titled: "矩形", in: toolbar(in: window)).performClick(nil)
        dragSelection(
            in: window,
            from: CGPoint(x: 40, y: 40),
            to: CGPoint(x: 120, y: 90)
        )
        window.selectionView.rightMouseDown(
            with: mouseEvent(
                .rightMouseDown,
                at: CGPoint(x: 180, y: 100),
                window: window
            )
        )
        XCTAssertEqual(
            window.selectionView.capturePhase,
            .selected(CGRect(x: 20, y: 20, width: 200, height: 100))
        )
        return window
    }

    private func rectangleEndpoints(
        in view: ScreenSelectionView
    ) throws -> (start: CGPoint, end: CGPoint) {
        let element = try XCTUnwrap(view.annotationElements.first)
        guard case let .rectangle(start, end, _) = element else {
            throw TestFailure.expectedRectangle
        }
        return (start, end)
    }

    private func click(in window: ScreenSelectionWindow, at point: CGPoint) {
        let view = window.selectionView
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, window: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, window: window))
    }

    private func toolbar(in window: ScreenSelectionWindow) throws -> NSVisualEffectView {
        try XCTUnwrap(window.selectionView.subviews.compactMap { $0 as? NSVisualEffectView }.first)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        window: NSWindow,
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func escapeKeyEvent(window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )!
    }

    private func characterKeyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
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
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private enum ArrowKey: UInt16 {
        case left = 123
        case right = 124
        case down = 125
        case up = 126
    }

    private func arrowKeyEvent(
        _ key: ArrowKey,
        modifiers: NSEvent.ModifierFlags = [],
        window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: key.rawValue
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
        throw TestFailure.buttonNotFound(title)
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        var result = view as? NSButton == nil ? [] : [view as! NSButton]
        for child in view.subviews {
            result.append(contentsOf: allButtons(in: child))
        }
        return result
    }

    private func makeImage(
        width: Int = 1,
        height: Int = 1,
        color: ((_ x: Int, _ topDownY: Int) -> (UInt8, UInt8, UInt8))? = nil
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = Data(repeating: 255, count: width * height * 4)
        if let color {
            pixelData.withUnsafeMutableBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = (y * width + x) * 4
                        let value = color(x, y)
                        bytes[offset] = value.0
                        bytes[offset + 1] = value.1
                        bytes[offset + 2] = value.2
                        bytes[offset + 3] = 255
                    }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixelData as CFData))
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

private enum TestFailure: Error {
    case buttonNotFound(String)
    case expectedRectangle
}
