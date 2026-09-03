import AppKit
import CoreText
import PolyglanceKit

enum ScreenshotAnnotationTool: Int, CaseIterable, Hashable {
    case freehand
    case rectangle
    case ellipse
    case line
    case arrow
    case text
    case mosaic
    case number

    var title: String {
        switch self {
        case .freehand:
            return "画笔"
        case .rectangle:
            return "矩形"
        case .ellipse:
            return "椭圆"
        case .line:
            return "线条"
        case .arrow:
            return "箭头"
        case .text:
            return "文字"
        case .mosaic:
            return "马赛克"
        case .number:
            return "序号"
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
        case .line:
            return "line.diagonal"
        case .arrow:
            return "arrow.up.right"
        case .text:
            return "t.square"
        case .mosaic:
            return "square.grid.3x3.fill"
        case .number:
            return "1.circle"
        }
    }
}

struct ScreenshotAnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var fontFamily: String
    var isFilled: Bool
    var isDashed: Bool
    var hasArrow: Bool
    var isBold: Bool
    var isItalic: Bool
    var hasBorder: Bool
    var shapeType: Int
    var numberStyle: Int

    static let `default` = ScreenshotAnnotationStyle(color: .systemRed, lineWidth: 3)

    init(
        color: NSColor = .systemRed,
        lineWidth: CGFloat = 3,
        fontSize: CGFloat = 16,
        fontFamily: String = "",
        isFilled: Bool = false,
        isDashed: Bool = false,
        hasArrow: Bool = false,
        isBold: Bool = false,
        isItalic: Bool = false,
        hasBorder: Bool = false,
        shapeType: Int = 0,
        numberStyle: Int = 0
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.isFilled = isFilled
        self.isDashed = isDashed
        self.hasArrow = hasArrow
        self.isBold = isBold
        self.isItalic = isItalic
        self.hasBorder = hasBorder
        self.shapeType = shapeType
        self.numberStyle = numberStyle
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.color.isEqual(rhs.color)
            && lhs.lineWidth == rhs.lineWidth
            && lhs.fontSize == rhs.fontSize
            && lhs.fontFamily == rhs.fontFamily
            && lhs.isFilled == rhs.isFilled
            && lhs.isDashed == rhs.isDashed
            && lhs.hasArrow == rhs.hasArrow
            && lhs.isBold == rhs.isBold
            && lhs.isItalic == rhs.isItalic
            && lhs.hasBorder == rhs.hasBorder
            && lhs.shapeType == rhs.shapeType
            && lhs.numberStyle == rhs.numberStyle
    }
}

enum ScreenshotAnnotationElement: Equatable {
    case freehand(points: [CGPoint], style: ScreenshotAnnotationStyle)
    case rectangle(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case ellipse(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case line(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case arrow(start: CGPoint, end: CGPoint, style: ScreenshotAnnotationStyle)
    case text(origin: CGPoint, text: String, style: ScreenshotAnnotationStyle)
    case mosaic(points: [CGPoint], style: ScreenshotAnnotationStyle)
    case number(origin: CGPoint, value: Int, style: ScreenshotAnnotationStyle)

    init(
        tool: ScreenshotAnnotationTool,
        start: CGPoint,
        style: ScreenshotAnnotationStyle = .default,
        number: Int = 1
    ) {
        switch tool {
        case .freehand:
            self = .freehand(points: [start], style: style)
        case .rectangle:
            self = .rectangle(start: start, end: start, style: style)
        case .ellipse:
            self = .ellipse(start: start, end: start, style: style)
        case .line:
            self = .line(start: start, end: start, style: style)
        case .arrow:
            self = .arrow(start: start, end: start, style: style)
        case .text:
            self = .text(origin: start, text: "", style: style)
        case .mosaic:
            self = .mosaic(points: [start], style: style)
        case .number:
            self = .number(origin: start, value: max(1, number), style: style)
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
        case .line:
            return .line
        case .arrow:
            return .arrow
        case .text:
            return .text
        case .mosaic:
            return .mosaic
        case .number:
            return .number
        }
    }

    var style: ScreenshotAnnotationStyle {
        switch self {
        case let .freehand(_, style),
             let .rectangle(_, _, style),
             let .ellipse(_, _, style),
             let .line(_, _, style),
             let .arrow(_, _, style),
             let .text(_, _, style),
             let .mosaic(_, style),
             let .number(_, _, style):
            return style
        }
    }

    var endPoint: CGPoint? {
        switch self {
        case let .freehand(points, _):
            return points.last
        case let .rectangle(_, end, _),
             let .ellipse(_, end, _),
             let .line(_, end, _),
             let .arrow(_, end, _):
            return end
        case let .mosaic(points, _):
            return points.last
        case let .text(origin, _, _):
            return origin
        case let .number(origin, _, _):
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
        case let .line(start, _, style):
            return .line(start: start, end: point, style: style)
        case let .arrow(start, _, style):
            return .arrow(start: start, end: point, style: style)
        case let .text(_, text, style):
            return .text(origin: point, text: text, style: style)
        case let .mosaic(existingPoints, style):
            var points = existingPoints
            points.append(point)
            return .mosaic(points: points, style: style)
        case let .number(_, value, style):
            return .number(origin: point, value: value, style: style)
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
        case let .line(start, end, style):
            return .line(start: transform(start), end: transform(end), style: style)
        case let .arrow(start, end, style):
            return .arrow(start: transform(start), end: transform(end), style: style)
        case let .text(origin, text, style):
            return .text(origin: transform(origin), text: text, style: style)
        case let .mosaic(points, style):
            return .mosaic(points: points.map(transform), style: style)
        case let .number(origin, value, style):
            return .number(origin: transform(origin), value: value, style: style)
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
        case .rectangle, .ellipse, .line, .arrow, .number:
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

    mutating func moveText(at index: Int, to origin: CGPoint) -> Bool {
        guard elements.indices.contains(index), case let .text(_, text, style) = elements[index] else {
            return false
        }
        elements[index] = .text(origin: origin, text: text, style: style)
        return true
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

            if case let .mosaic(points, style) = element {
                if let sourceImage {
                    let isBlur = style.hasBorder
                    let destinationPoints = points.map(pointTransform)
                    let sourcePoints: [CGPoint]
                    if let sourcePixelTransform {
                        sourcePoints = points.map(sourcePixelTransform)
                    } else {
                        sourcePoints = points.map(pointTransform)
                    }

                    if style.shapeType == 1,
                       let destFirst = destinationPoints.first,
                       let destLast = destinationPoints.last,
                       let srcFirst = sourcePoints.first,
                       let srcLast = sourcePoints.last {
                        let blockSize = max(style.lineWidth * 3 * lineWidthScale, 4)
                        drawMosaicRect(
                            sourceImage: sourceImage,
                            sourceStart: srcFirst,
                            sourceEnd: srcLast,
                            destinationStart: destFirst,
                            destinationEnd: destLast,
                            blockSize: blockSize,
                            isBlur: isBlur,
                            in: context
                        )
                    } else {
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
                            isBlur: isBlur,
                            in: context
                        )
                    }
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
                let r = rect(from: pointTransform(start), to: pointTransform(end))
                if style.isFilled {
                    context.fill(r)
                }
                if style.isDashed {
                    context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
                }
                context.stroke(r)
                context.setLineDash(phase: 0, lengths: [])
            case let .ellipse(start, end, _):
                let r = rect(from: pointTransform(start), to: pointTransform(end))
                if style.isFilled {
                    context.fillEllipse(in: r)
                }
                if style.isDashed {
                    context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
                }
                context.strokeEllipse(in: r)
                context.setLineDash(phase: 0, lengths: [])
            case let .line(start, end, _):
                drawLine(
                    from: pointTransform(start),
                    to: pointTransform(end),
                    style: style,
                    lineWidth: lineWidth,
                    in: context
                )
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
            case let .number(origin, value, _):
                drawNumber(
                    value,
                    at: pointTransform(origin),
                    style: style,
                    diameter: max(18, lineWidth * 6),
                    in: context
                )
            case .mosaic:
                break
            }
        }
    }

    private static func drawLine(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        guard start != end else { return }
        context.saveGState()
        if style.isDashed {
            context.setLineDash(phase: 0, lengths: [lineWidth * 3, lineWidth * 2])
        }
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()

        if style.hasArrow {
            drawArrow(from: start, to: end, lineWidth: lineWidth, in: context)
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
        let effectiveSize = max(1, style.fontSize * scale)
        var font: NSFont
        if !style.fontFamily.isEmpty, let customFont = NSFont(name: style.fontFamily, size: effectiveSize) {
            font = customFont
        } else {
            font = NSFont.systemFont(
                ofSize: effectiveSize,
                weight: style.isBold ? .bold : .medium
            )
        }
        if style.isItalic {
            let fontDescriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: fontDescriptor, size: effectiveSize) ?? font
        }
        if style.isBold && !style.fontFamily.isEmpty {
            let fontDescriptor = font.fontDescriptor.withSymbolicTraits(.bold)
            font = NSFont(descriptor: fontDescriptor, size: effectiveSize) ?? font
        }
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: style.color,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedText)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        if style.hasBorder {
            context.saveGState()
            let bgRect = CGRect(
                x: origin.x - 4,
                y: origin.y - 2,
                width: bounds.width + 8,
                height: bounds.height + 4
            )
            context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            context.fill(bgRect)
            context.restoreGState()
        }

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = origin
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawNumber(
        _ value: Int,
        at origin: CGPoint,
        style: ScreenshotAnnotationStyle,
        diameter: CGFloat,
        in context: CGContext
    ) {
        let rect = CGRect(
            x: origin.x - diameter / 2,
            y: origin.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        context.saveGState()
        if style.numberStyle == 1 {
            // Outline style
            context.setStrokeColor(style.color.cgColor)
            context.setLineWidth(max(2, diameter * 0.1))
            context.strokeEllipse(in: rect)
        } else {
            // Filled style
            context.setFillColor(style.color.cgColor)
            context.fillEllipse(in: rect)
        }
        let textColor = style.numberStyle == 1 ? style.color : NSColor.white
        let text = NSAttributedString(
            string: String(value),
            attributes: [
                .font: NSFont.systemFont(ofSize: max(10, diameter * 0.55), weight: .bold),
                .foregroundColor: textColor,
            ]
        )
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: origin.x - bounds.width / 2 - bounds.minX,
            y: origin.y - bounds.height / 2 - bounds.minY
        )
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
        isBlur: Bool,
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
        lowResolutionContext.interpolationQuality = isBlur ? .high : .medium
        lowResolutionContext.draw(
            sourcePatch,
            in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight)
        )
        guard let processedPatch = lowResolutionContext.makeImage() else {
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
        context.interpolationQuality = isBlur ? .high : .none
        context.draw(processedPatch, in: destinationRect)
        context.restoreGState()
    }

    private static func drawMosaicRect(
        sourceImage: CGImage,
        sourceStart: CGPoint,
        sourceEnd: CGPoint,
        destinationStart: CGPoint,
        destinationEnd: CGPoint,
        blockSize: CGFloat,
        isBlur: Bool,
        in context: CGContext
    ) {
        let destinationRect = CGRect(
            x: min(destinationStart.x, destinationEnd.x),
            y: min(destinationStart.y, destinationEnd.y),
            width: abs(destinationEnd.x - destinationStart.x),
            height: abs(destinationEnd.y - destinationStart.y)
        )
        guard destinationRect.width >= 1, destinationRect.height >= 1 else { return }

        let bottomLeftSourceRect = CGRect(
            x: min(sourceStart.x, sourceEnd.x),
            y: min(sourceStart.y, sourceEnd.y),
            width: abs(sourceEnd.x - sourceStart.x),
            height: abs(sourceEnd.y - sourceStart.y)
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
        lowResolutionContext.interpolationQuality = isBlur ? .high : .medium
        lowResolutionContext.draw(
            sourcePatch,
            in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight)
        )
        guard let processedPatch = lowResolutionContext.makeImage() else {
            return
        }

        context.saveGState()
        context.interpolationQuality = isBlur ? .high : .none
        context.draw(processedPatch, in: destinationRect)
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
