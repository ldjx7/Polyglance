import AppKit
import XCTest
@testable import NativeTranslatorMac

final class ScreenshotAnnotationTests: XCTestCase {
    func testToolCatalogContainsEveryFirstBatchDrawingTool() {
        XCTAssertEqual(
            Set(ScreenshotAnnotationTool.allCases),
            Set([.freehand, .rectangle, .ellipse, .arrow, .text, .mosaic])
        )
        XCTAssertEqual(ScreenshotAnnotationTool.text.symbolName, "t.square")
    }

    func testEveryToolCreatesAnElementThatTracksItsDragEndpoint() {
        let style = ScreenshotAnnotationStyle(color: .systemBlue, lineWidth: 5)
        let start = CGPoint(x: 10, y: 20)
        let end = CGPoint(x: 80, y: 60)

        for tool in ScreenshotAnnotationTool.allCases {
            let element = ScreenshotAnnotationElement(
                tool: tool,
                start: start,
                style: style
            ).updating(to: end)

            XCTAssertEqual(element.tool, tool)
            XCTAssertEqual(element.style, style)
            XCTAssertEqual(element.endPoint, end)
        }
    }

    func testHistorySupportsUndoRedoAndInvalidatesRedoAfterNewElement() {
        let style = ScreenshotAnnotationStyle.default
        let first = ScreenshotAnnotationElement.rectangle(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 40, y: 30),
            style: style
        )
        let second = ScreenshotAnnotationElement.ellipse(
            start: CGPoint(x: 50, y: 20),
            end: CGPoint(x: 90, y: 70),
            style: style
        )
        var history = ScreenshotAnnotationHistory()

        history.append(first)
        history.append(second)
        XCTAssertEqual(history.elements, [first, second])
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)

        XCTAssertEqual(history.undo(), second)
        XCTAssertEqual(history.elements, [first])
        XCTAssertTrue(history.canRedo)

        XCTAssertEqual(history.redo(), second)
        XCTAssertEqual(history.elements, [first, second])

        _ = history.undo()
        let replacement = ScreenshotAnnotationElement.arrow(
            start: CGPoint(x: 5, y: 5),
            end: CGPoint(x: 25, y: 25),
            style: style
        )
        history.append(replacement)

        XCTAssertEqual(history.elements, [first, replacement])
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo())
    }

    func testTextAndMosaicParticipateInHistoryAndSelectionTranslation() {
        let style = ScreenshotAnnotationStyle(color: .systemBlue, lineWidth: 4)
        let text = ScreenshotAnnotationElement.text(
            origin: CGPoint(x: 20, y: 30),
            text: "Retina",
            style: style
        )
        let mosaic = ScreenshotAnnotationElement.mosaic(
            points: [CGPoint(x: 40, y: 50), CGPoint(x: 90, y: 80)],
            style: style
        )
        var history = ScreenshotAnnotationHistory()
        history.append(text)
        history.append(mosaic)

        let translated = history.transformed {
            CGPoint(x: $0.x + 12, y: $0.y - 8)
        }

        XCTAssertEqual(translated.elements, [
            .text(
                origin: CGPoint(x: 32, y: 22),
                text: "Retina",
                style: style
            ),
            .mosaic(
                points: [CGPoint(x: 52, y: 42), CGPoint(x: 102, y: 72)],
                style: style
            ),
        ])
        var undoable = translated
        XCTAssertEqual(undoable.undo(), translated.elements.last)
        XCTAssertEqual(undoable.redo(), translated.elements.last)
    }

    func testBlankTextAndSinglePointMosaicAreNotMeaningfulAnnotations() {
        XCTAssertFalse(ScreenshotAnnotationElement.text(
            origin: CGPoint(x: 10, y: 10),
            text: " \n\t ",
            style: .default
        ).isMeaningful)
        XCTAssertFalse(ScreenshotAnnotationElement.mosaic(
            points: [CGPoint(x: 10, y: 10)],
            style: .default
        ).isMeaningful)
        XCTAssertTrue(ScreenshotAnnotationElement.mosaic(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 10.5, y: 11)],
            style: .default
        ).isMeaningful)
    }

    func testComposerDrawsEveryElementAtRetinaPixelCoordinates() throws {
        let image = try makeImage(width: 200, height: 200)
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let style = ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)
        let elements: [ScreenshotAnnotationElement] = [
            .freehand(
                points: [CGPoint(x: 5, y: 10), CGPoint(x: 15, y: 10)],
                style: style
            ),
            .rectangle(
                start: CGPoint(x: 20, y: 20),
                end: CGPoint(x: 40, y: 35),
                style: style
            ),
            .ellipse(
                start: CGPoint(x: 50, y: 20),
                end: CGPoint(x: 70, y: 40),
                style: style
            ),
            .arrow(
                start: CGPoint(x: 20, y: 60),
                end: CGPoint(x: 70, y: 60),
                style: style
            ),
        ]

        let output = try XCTUnwrap(ScreenshotImageComposer.compose(
            image: image,
            selection: selection,
            elements: elements
        ))

        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 200)
        try assertRedPixel(in: output, x: 20, y: 20, message: "freehand")
        try assertRedPixel(in: output, x: 60, y: 40, message: "rectangle")
        try assertRedPixel(in: output, x: 120, y: 80, message: "ellipse")
        try assertRedPixel(in: output, x: 90, y: 120, message: "arrow")

        let unscaledLocation = try color(in: output, x: 10, y: 10)
        XCTAssertGreaterThan(unscaledLocation.greenComponent, 0.8)
    }

    func testPreviewRendererAndExportComposerProduceTheSamePixelsAtOneX() throws {
        let image = try makeImage(width: 100, height: 100)
        let style = ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)
        let elements: [ScreenshotAnnotationElement] = [
            .freehand(
                points: [CGPoint(x: 8, y: 12), CGPoint(x: 30, y: 25)],
                style: style
            ),
            .rectangle(
                start: CGPoint(x: 35, y: 10),
                end: CGPoint(x: 70, y: 35),
                style: style
            ),
            .ellipse(
                start: CGPoint(x: 10, y: 50),
                end: CGPoint(x: 40, y: 85),
                style: style
            ),
            .arrow(
                start: CGPoint(x: 50, y: 55),
                end: CGPoint(x: 90, y: 85),
                style: style
            ),
        ]
        let previewContext = try makeContext(width: 100, height: 100)
        previewContext.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        ScreenshotAnnotationRenderer.draw(elements: elements, in: previewContext)
        let preview = try XCTUnwrap(previewContext.makeImage())

        let exported = try XCTUnwrap(ScreenshotImageComposer.compose(
            image: image,
            selection: CGRect(x: 0, y: 0, width: 100, height: 100),
            elements: elements
        ))

        XCTAssertEqual(preview.dataProvider?.data as Data?, exported.dataProvider?.data as Data?)
    }

    func testComposerRendersTextAndPixelatesMosaicFromTheRealSourceImage() throws {
        let image = try makeGradientImage(width: 80, height: 80)
        let selection = CGRect(x: 0, y: 0, width: 40, height: 40)
        let style = ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)
        let output = try XCTUnwrap(ScreenshotImageComposer.compose(
            image: image,
            selection: selection,
            elements: [
                .text(
                    origin: CGPoint(x: 2, y: 2),
                    text: "A",
                    style: style
                ),
                .mosaic(
                    points: [
                        CGPoint(x: 10, y: 10),
                        CGPoint(x: 20, y: 30),
                        CGPoint(x: 30, y: 10),
                    ],
                    style: style
                ),
            ]
        ))

        XCTAssertEqual(output.width, 80)
        XCTAssertEqual(output.height, 80)
        XCTAssertNotEqual(
            output.dataProvider?.data as Data?,
            image.dataProvider?.data as Data?,
            "Text and mosaic must be baked into the exported bitmap"
        )

        // The 20 x 20 point mosaic maps to 40 x 40 Retina pixels. Widely separated
        // source pixels become one of a small number of nearest-neighbour blocks.
        let firstBlockColor = try color(in: output, x: 25, y: 25)
        let sameBlockColor = try color(in: output, x: 30, y: 30)
        XCTAssertEqual(firstBlockColor.redComponent, sameBlockColor.redComponent, accuracy: 0.01)
        XCTAssertEqual(firstBlockColor.greenComponent, sameBlockColor.greenComponent, accuracy: 0.01)

        let outsideBefore = try color(in: image, x: 70, y: 70)
        let outsideAfter = try color(in: output, x: 70, y: 70)
        XCTAssertEqual(outsideBefore.redComponent, outsideAfter.redComponent, accuracy: 0.001)
        XCTAssertEqual(outsideBefore.greenComponent, outsideAfter.greenComponent, accuracy: 0.001)
        XCTAssertEqual(outsideBefore.blueComponent, outsideAfter.blueComponent, accuracy: 0.001)
    }

    func testPreviewAndExportMosaicPixelsMatchAtOneX() throws {
        let image = try makeGradientImage(width: 64, height: 64)
        let elements: [ScreenshotAnnotationElement] = [
            .mosaic(
                points: [CGPoint(x: 8, y: 9), CGPoint(x: 48, y: 45)],
                style: ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)
            ),
        ]
        let previewContext = try makeContext(width: 64, height: 64)
        previewContext.interpolationQuality = .none
        previewContext.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        ScreenshotAnnotationRenderer.draw(
            elements: elements,
            in: previewContext,
            sourceImage: image
        )
        let preview = try XCTUnwrap(previewContext.makeImage())

        let exported = try XCTUnwrap(ScreenshotImageComposer.compose(
            image: image,
            selection: CGRect(x: 0, y: 0, width: 64, height: 64),
            elements: elements
        ))

        XCTAssertEqual(preview.dataProvider?.data as Data?, exported.dataProvider?.data as Data?)
    }

    private func assertRedPixel(
        in image: CGImage,
        x: Int,
        y: Int,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sampled = try color(in: image, x: x, y: y)
        XCTAssertGreaterThan(sampled.redComponent, 0.75, message, file: file, line: line)
        XCTAssertLessThan(sampled.greenComponent, 0.5, message, file: file, line: line)
        XCTAssertLessThan(sampled.blueComponent, 0.5, message, file: file, line: line)
    }

    private func color(in image: CGImage, x: Int, y: Int) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        // Annotation coordinates use AppKit's bottom-left origin, while bitmap rows are top-down.
        let bitmapY = image.height - 1 - y
        return try XCTUnwrap(bitmap.colorAt(x: x, y: bitmapY)?.usingColorSpace(.deviceRGB))
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
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

    private func makeGradientImage(width: Int, height: Int) throws -> CGImage {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    bytes[offset] = UInt8((x * 3) % 256)
                    bytes[offset + 1] = UInt8((y * 5) % 256)
                    bytes[offset + 2] = UInt8((x + y) % 256)
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }
}
