import AppKit
import CoreText
import PolyglanceKit

enum ScreenshotAnnotationTool: Int, CaseIterable, Hashable {
    case freehand
    case rectangle
    case ellipse
    case arrow
    case text
    case mosaic

    var title: String {
        switch self {
        case .freehand:
            return "画笔"
        case .rectangle:
            return "矩形"
        case .ellipse:
            return "椭圆"
        case .arrow:
            return "箭头"
        case .text:
            return "文字"
        case .mosaic:
            return "马赛克"
        }
    }

    var symbolName: String {
        switch self {
        case .freehand:
            return "pencil.tip"
        case .rectangle:
            return "rectangle"
        case .ellipse:
            return "circle"
        case .arrow:
            return "arrow.up.right"
        case .text:
            return "t.square"
        case .mosaic:
            return "square.grid.3x3.fill"
        }
    }
}

struct ScreenshotAnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

    static let `default` = ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)

    init(color: NSColor, lineWidth: CGFloat, fontSize: CGFloat = 16) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.color.isEqual(rhs.color)
            && lhs.lineWidth == rhs.lineWidth
            && lhs.fontSize == rhs.fontSize
    }
}

enum ScreenshotAnnotationElement: Equatable {
    case freehand(points: [CGPoint], style: ScreenshotAnnotationStyle)
    case rectangle(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case ellipse(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case arrow(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case text(origin: CGPoint, text: String, style: ScreenshotAnnotationStyle)
    case mosaic(points: [CGPoint], style: ScreenshotAnnotationStyle)

    init(
        tool: ScreenshotAnnotationTool,
        start: CGPoint,
        style: ScreenshotAnnotationStyle = .default
    ) {
        switch tool {
        case .freehand:
            self = .freehand(points: [start], style: style)
        case .rectangle:
            self = .rectangle(start: start, end: start, style: style)
        case .ellipse:
            self = .ellipse(start: start, end: start, style: style)
        case .arrow:
            self = .arrow(start: start, end: start, style: style)
        case .text:
            self = .text(origin: start, text: "", style: style)
        case .mosaic:
            self = .mosaic(points: [start], style: style)
        }
    }

    var tool: ScreenshotAnnotationTool {
        switch self {
        case .freehand:
            return .freehand
        case .rectangle:
            return .rectangle
        case .ellipse:
            return .ellipse
        case .arrow:
            return .arrow
        case .text:
            return .text
        case .mosaic:
            return .mosaic
        }
    }

    var style: ScreenshotAnnotationStyle {
        switch self {
        case let .freehand(_, style),
             let .rectangle(_, _, style),
             let .ellipse(_, _, style),
             let .arrow(_, _, style),
             let .text(_, _, style),
             let .mosaic(_, style):
            return style
        }
    }

    var endPoint: CGPoint? {
        switch self {
        case let .freehand(points, _):
            return points.last
        case let .rectangle(_, end, _),
             let .ellipse(_, end, _),
             let .arrow(_, end, _):
            return end
        case let .mosaic(points, _):
            return points.last
        case let .text(origin, _, _):
            return origin
        }
    }

    func updating(to point: CGPoint) -> ScreenshotAnnotationElement {
        switch self {
        case let .freehand(existingPoints, style):
            var points = existingPoints
            points.append(point)
            return .freehand(points: points, style: style)
        case let .rectangle(start, _, style):
            return .rectangle(start: start, end: point, style: style)
        case let .ellipse(start, _, style):
            return .ellipse(start: start, end: point, style: style)
        case let .arrow(start, _, style):
            return .arrow(start: start, end: point, style: style)
        case let .text(_, text, style):
            return .text(origin: point, text: text, style: style)
        case let .mosaic(existingPoints, style):
            var points = existingPoints
            points.append(point)
            return .mosaic(points: points, style: style)
        }
    }

    func transformed(
        _ transform: (CGPoint) -> CGPoint
    ) -> ScreenshotAnnotationElement {
        switch self {
        case let .freehand(points, style):
            return .freehand(points: points.map(transform), style: style)
        case let .rectangle(start, end, style):
            return .rectangle(start: transform(start), end: transform(end), style: style)
        case let .ellipse(start, end, style):
            return .ellipse(start: transform(start), end: transform(end), style: style)
        case let .arrow(start, end, style):
            return .arrow(start: transform(start), end: transform(end), style: style)
        case let .text(origin, text, style):
            return .text(origin: transform(origin), text: text, style: style)
        case let .mosaic(points, style):
            return .mosaic(points: points.map(transform), style: style)
        }
    }

    var isMeaningful: Bool {
        switch self {
        case let .freehand(points, _):
            return !points.isEmpty
        case let .text(_, text, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .mosaic(points, _):
            return points.count > 1
        case .rectangle, .ellipse, .arrow:
            return true
        }
    }
}

struct ScreenshotAnnotationHistory {
    private(set) var elements: [ScreenshotAnnotationElement] = []
    private var redoStack: [ScreenshotAnnotationElement] = []

    var canUndo: Bool { !elements.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func append(_ element: ScreenshotAnnotationElement) {
        elements.append(element)
        redoStack.removeAll()
    }

    @discardableResult
    mutating func undo() -> ScreenshotAnnotationElement? {
        guard let element = elements.popLast() else {
            return nil
        }
        redoStack.append(element)
        return element
    }

    @discardableResult
    mutating func redo() -> ScreenshotAnnotationElement? {
        guard let element = redoStack.popLast() else {
            return nil
        }
        elements.append(element)
        return element
    }

    mutating func removeAll() {
        elements.removeAll()
        redoStack.removeAll()
    }

    func transformed(
        _ transform: (CGPoint) -> CGPoint
    ) -> ScreenshotAnnotationHistory {
        var transformedHistory = self
        transformedHistory.elements = elements.map { $0.transformed(transform) }
        transformedHistory.redoStack = redoStack.map { $0.transformed(transform) }
        return transformedHistory
    }
}

enum ScreenshotAnnotationRenderer {
    static func draw(
        elements: [ScreenshotAnnotationElement],
        in context: CGContext,
        sourceImage: CGImage? = nil,
        pointTransform: (CGPoint) -> CGPoint = { $0 },
        sourcePixelTransform: ((CGPoint) -> CGPoint)? = nil,
        lineWidthScale: CGFloat = 1
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        for element in elements {
            let style = element.style
            let lineWidth = max(style.lineWidth * lineWidthScale, 0.5)

            if case let .mosaic(points, _) = element {
                if let sourceImage {
                    let destinationPoints = points.map(pointTransform)
                    let sourcePoints: [CGPoint]
                    if let sourcePixelTransform {
                        sourcePoints = points.map(sourcePixelTransform)
                    } else {
                        sourcePoints = points.map(pointTransform)
                    }
                    let sourceToDestinationScale = averageScale(
                        sourcePoints: sourcePoints,
                        destinationPoints: destinationPoints
                    )
                    let destinationBrushWidth = max(style.lineWidth * 8 * lineWidthScale, 12)
                    drawMosaicStroke(
                        sourceImage: sourceImage,
                        sourcePoints: sourcePoints,
                        destinationPoints: destinationPoints,
                        sourceBrushWidth: destinationBrushWidth * sourceToDestinationScale,
                        destinationBrushWidth: destinationBrushWidth,
                        blockSize: max(
                            style.lineWidth * 4 * max(lineWidthScale, sourceToDestinationScale),
                            4
                        ),
                        in: context
                    )
                }
                continue
            }

            context.setStrokeColor(style.color.cgColor)
            context.setFillColor(style.color.cgColor)
            context.setLineWidth(lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            switch element {
            case let .freehand(points, _):
                drawFreehand(
                    points.map(pointTransform),
                    lineWidth: lineWidth,
                    in: context
                )
            case let .rectangle(start, end, _):
                context.stroke(rect(from: pointTransform(start), to: pointTransform(end)))
            case let .ellipse(start, end, _):
                context.strokeEllipse(in: rect(from: pointTransform(start), to: pointTransform(end)))
            case let .arrow(start, end, _):
                drawArrow(
                    from: pointTransform(start),
                    to: pointTransform(end),
                    lineWidth: lineWidth,
                    in: context
                )
            case let .text(origin, text, _):
                drawText(
                    text,
                    at: pointTransform(origin),
                    style: style,
                    scale: lineWidthScale,
                    in: context
                )
            case .mosaic:
                break
            }
        }
    }

    private static func drawText(
        _ text: String,
        at origin: CGPoint,
        style: ScreenshotAnnotationStyle,
        scale: CGFloat,
        in context: CGContext
    ) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: max(1, style.fontSize * scale),
                    weight: .semibold
                ),
                .foregroundColor: style.color,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawMosaicStroke(
        sourceImage: CGImage,
        sourcePoints: [CGPoint],
        destinationPoints: [CGPoint],
        sourceBrushWidth: CGFloat,
        destinationBrushWidth: CGFloat,
        blockSize: CGFloat,
        in context: CGContext
    ) {
        guard sourcePoints.count > 1, destinationPoints.count > 1 else {
            return
        }
        let bottomLeftSourceRect = boundingRect(
            for: sourcePoints,
            padding: sourceBrushWidth / 2
        )
        let destinationRect = boundingRect(
            for: destinationPoints,
            padding: destinationBrushWidth / 2
        )
        let topLeftSourceRect = CGRect(
            x: bottomLeftSourceRect.minX,
            y: CGFloat(sourceImage.height) - bottomLeftSourceRect.maxY,
            width: bottomLeftSourceRect.width,
            height: bottomLeftSourceRect.height
        ).integral.intersection(CGRect(
            x: 0,
            y: 0,
            width: sourceImage.width,
            height: sourceImage.height
        ))
        guard !topLeftSourceRect.isNull,
              !topLeftSourceRect.isEmpty,
              let sourcePatch = sourceImage.cropping(to: topLeftSourceRect) else {
            return
        }

        let lowWidth = max(1, Int(ceil(topLeftSourceRect.width / blockSize)))
        let lowHeight = max(1, Int(ceil(topLeftSourceRect.height / blockSize)))
        guard let lowResolutionContext = CGContext(
            data: nil,
            width: lowWidth,
            height: lowHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        lowResolutionContext.interpolationQuality = .medium
        lowResolutionContext.draw(
            sourcePatch,
            in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight)
        )
        guard let pixelatedPatch = lowResolutionContext.makeImage() else {
            return
        }

        context.saveGState()
        context.beginPath()
        context.move(to: destinationPoints[0])
        for point in destinationPoints.dropFirst() {
            context.addLine(to: point)
        }
        context.setLineWidth(destinationBrushWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()
        context.interpolationQuality = .none
        context.draw(pixelatedPatch, in: destinationRect)
        context.restoreGState()
    }

    private static func boundingRect(for points: [CGPoint], padding: CGFloat) -> CGRect {
        guard let first = points.first else { return .zero }
        let bounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
        return bounds.insetBy(dx: -padding, dy: -padding)
    }

    private static func averageScale(
        sourcePoints: [CGPoint],
        destinationPoints: [CGPoint]
    ) -> CGFloat {
        guard let sourceFirst = sourcePoints.first,
              let destinationFirst = destinationPoints.first else {
            return 1
        }
        let sourceBounds = boundingRect(for: sourcePoints, padding: 0)
        let destinationBounds = boundingRect(for: destinationPoints, padding: 0)
        let xScale = sourceBounds.width / max(destinationBounds.width, 1)
        let yScale = sourceBounds.height / max(destinationBounds.height, 1)
        if sourceBounds.width > 0, sourceBounds.height > 0 {
            return sqrt(max(xScale * yScale, 1))
        }
        let sourceDistance = hypot(sourcePoints.last!.x - sourceFirst.x, sourcePoints.last!.y - sourceFirst.y)
        let destinationDistance = hypot(
            destinationPoints.last!.x - destinationFirst.x,
            destinationPoints.last!.y - destinationFirst.y
        )
        return max(sourceDistance / max(destinationDistance, 1), 1)
    }

    private static func drawFreehand(
        _ points: [CGPoint],
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        guard let first = points.first else {
            return
        }
        guard points.count > 1 else {
            let radius = lineWidth / 2
            context.fillEllipse(in: CGRect(
                x: first.x - radius,
                y: first.y - radius,
                width: lineWidth,
                height: lineWidth
            ))
            return
        }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        context.strokePath()
    }

    private static func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else {
            drawFreehand([start], lineWidth: lineWidth, in: context)
            return
        }

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = min(max(lineWidth * 4, 8), length * 0.5)
        let headAngle = CGFloat.pi / 7
        let firstHead = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let secondHead = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.move(to: end)
        context.addLine(to: firstHead)
        context.move(to: end)
        context.addLine(to: secondHead)
        context.strokePath()
    }

    private static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }
}

// Compatibility for callers and tests that still construct the original freehand-only model.
struct ScreenshotAnnotationStroke {
    var points: [CGPoint]
}

enum ScreenshotImageComposer {
    static func compose(
        image: CGImage,
        selection: CGRect,
        elements: [ScreenshotAnnotationElement]
    ) -> CGImage? {
        guard !elements.isEmpty else {
            return image
        }
        guard selection.width > 0,
              selection.height > 0,
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        let outputSize = CGSize(width: image.width, height: image.height)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        context.interpolationQuality = .none
        context.draw(image, in: outputRect)

        let scaleX = outputSize.width / selection.width
        let scaleY = outputSize.height / selection.height
        ScreenshotAnnotationRenderer.draw(
            elements: elements,
            in: context,
            sourceImage: image,
            pointTransform: {
                CaptureGeometry.annotationPixelPoint(
                    $0,
                    selection: selection,
                    imagePixelSize: outputSize
                )
            },
            sourcePixelTransform: {
                CaptureGeometry.annotationPixelPoint(
                    $0,
                    selection: selection,
                    imagePixelSize: outputSize
                )
            },
            lineWidthScale: sqrt(scaleX * scaleY)
        )
        return context.makeImage()
    }

    static func compose(
        image: CGImage,
        selection: CGRect,
        strokes: [ScreenshotAnnotationStroke]
    ) -> CGImage? {
        compose(
            image: image,
            selection: selection,
            elements: strokes.map {
                .freehand(points: $0.points, style: .default)
            }
        )
    }
}
