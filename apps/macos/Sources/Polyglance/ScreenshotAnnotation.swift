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
    var arrowStyle: Int
    var lineDashPattern: Int

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
        numberStyle: Int = 0,
        arrowStyle: Int = 0,
        lineDashPattern: Int = 0
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
        self.arrowStyle = arrowStyle
        self.lineDashPattern = lineDashPattern
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
            && lhs.arrowStyle == rhs.arrowStyle
            && lhs.lineDashPattern == rhs.lineDashPattern
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
                } else {
                    applyDashPattern(style.lineDashPattern, isDashed: style.isDashed, lineWidth: lineWidth, in: context)
                    context.stroke(r)
                    context.setLineDash(phase: 0, lengths: [])
                }
            case let .ellipse(start, end, _):
                let r = rect(from: pointTransform(start), to: pointTransform(end))
                if style.isFilled {
                    context.fillEllipse(in: r)
                } else {
                    applyDashPattern(style.lineDashPattern, isDashed: style.isDashed, lineWidth: lineWidth, in: context)
                    context.strokeEllipse(in: r)
                    context.setLineDash(phase: 0, lengths: [])
                }
            case let .line(start, end, _):
                drawLine(
                    from: pointTransform(start),
                    to: pointTransform(end),
                    style: style,
                    lineWidth: lineWidth,
                    in: context
                )
            case let .arrow(start, end, _):
                drawLine(
                    from: pointTransform(start),
                    to: pointTransform(end),
                    style: style,
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

    private static func applyDashPattern(_ pattern: Int, isDashed: Bool, lineWidth: CGFloat, in context: CGContext) {
        if pattern == 1 || (pattern == 0 && isDashed) {
            context.setLineDash(phase: 0, lengths: [lineWidth * 4, lineWidth * 2])
        } else if pattern == 2 {
            context.setLineDash(phase: 0, lengths: [lineWidth * 1.2, lineWidth * 1.8])
        } else if pattern == 3 {
            context.setLineDash(phase: 0, lengths: [lineWidth * 5, lineWidth * 2, lineWidth * 1.2, lineWidth * 2])
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
        context.setStrokeColor(style.color.cgColor)
        context.setFillColor(style.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        drawArrowGeometry(from: start, to: end, style: style, lineWidth: lineWidth, in: context)
        context.restoreGState()
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

    static func drawArrowGeometry(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else {
            drawFreehand([start], lineWidth: lineWidth, in: context)
            return
        }

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = min(max(lineWidth * 3.5, 9), length * 0.45)
        let perpAngle = angle + CGFloat.pi / 2
        let arrowStyle = style.arrowStyle

        var lineStart = start
        var lineEnd = end

        if arrowStyle == 2 || arrowStyle == 3 {
            lineEnd = CGPoint(x: end.x - headLength * 0.7 * cos(angle), y: end.y - headLength * 0.7 * sin(angle))
        }
        if arrowStyle == 3 {
            lineStart = CGPoint(x: start.x + headLength * 0.7 * cos(angle), y: start.y + headLength * 0.7 * sin(angle))
        }

        if arrowStyle != 4 && arrowStyle != 5 {
            context.saveGState()
            applyDashPattern(style.lineDashPattern, isDashed: style.isDashed, lineWidth: lineWidth, in: context)
            context.beginPath()
            context.move(to: lineStart)
            context.addLine(to: lineEnd)
            context.strokePath()
            context.restoreGState()
        }

        switch arrowStyle {
        case 0: // Single open arrow: ——>
            let wingAngle = CGFloat.pi / 6.5
            let h1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let h2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            context.beginPath()
            context.move(to: h1)
            context.addLine(to: end)
            context.addLine(to: h2)
            context.strokePath()

        case 1: // Double open arrow: <——>
            let wingAngle = CGFloat.pi / 6.5
            let eh1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let eh2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            let sh1 = CGPoint(x: start.x + headLength * cos(angle - wingAngle), y: start.y + headLength * sin(angle - wingAngle))
            let sh2 = CGPoint(x: start.x + headLength * cos(angle + wingAngle), y: start.y + headLength * sin(angle + wingAngle))
            context.beginPath()
            context.move(to: eh1)
            context.addLine(to: end)
            context.addLine(to: eh2)
            context.move(to: sh1)
            context.addLine(to: start)
            context.addLine(to: sh2)
            context.strokePath()

        case 2: // Single filled triangle: ——▶
            let baseW = headLength * 0.65
            let tip = end
            let b1 = CGPoint(x: end.x - headLength * cos(angle) + baseW * cos(perpAngle), y: end.y - headLength * sin(angle) + baseW * sin(perpAngle))
            let b2 = CGPoint(x: end.x - headLength * cos(angle) - baseW * cos(perpAngle), y: end.y - headLength * sin(angle) - baseW * sin(perpAngle))
            context.beginPath()
            context.move(to: tip)
            context.addLine(to: b1)
            context.addLine(to: b2)
            context.closePath()
            context.fillPath()

        case 3: // Double filled triangle: ◀——▶
            let baseW = headLength * 0.65
            let eTip = end
            let eb1 = CGPoint(x: end.x - headLength * cos(angle) + baseW * cos(perpAngle), y: end.y - headLength * sin(angle) + baseW * sin(perpAngle))
            let eb2 = CGPoint(x: end.x - headLength * cos(angle) - baseW * cos(perpAngle), y: end.y - headLength * sin(angle) - baseW * sin(perpAngle))
            context.beginPath()
            context.move(to: eTip)
            context.addLine(to: eb1)
            context.addLine(to: eb2)
            context.closePath()
            context.fillPath()

            let sTip = start
            let sb1 = CGPoint(x: start.x + headLength * cos(angle) + baseW * cos(perpAngle), y: start.y + headLength * sin(angle) + baseW * sin(perpAngle))
            let sb2 = CGPoint(x: start.x + headLength * cos(angle) - baseW * cos(perpAngle), y: start.y + headLength * sin(angle) - baseW * sin(perpAngle))
            context.beginPath()
            context.move(to: sTip)
            context.addLine(to: sb1)
            context.addLine(to: sb2)
            context.closePath()
            context.fillPath()

        case 4: // Tapered expanding arrow (从小变大)
            let startW = max(1.2, lineWidth * 0.35)
            let baseW = max(3.5, lineWidth * 1.8)
            let hLen = min(max(lineWidth * 3.6, 11), length * 0.45)
            let wingW = baseW * 1.7
            let baseCenter = CGPoint(x: end.x - hLen * cos(angle), y: end.y - hLen * sin(angle))

            let s1 = CGPoint(x: start.x + (startW / 2) * cos(perpAngle), y: start.y + (startW / 2) * sin(perpAngle))
            let s2 = CGPoint(x: start.x - (startW / 2) * cos(perpAngle), y: start.y - (startW / 2) * sin(perpAngle))
            let b1 = CGPoint(x: baseCenter.x + (baseW / 2) * cos(perpAngle), y: baseCenter.y + (baseW / 2) * sin(perpAngle))
            let b2 = CGPoint(x: baseCenter.x - (baseW / 2) * cos(perpAngle), y: baseCenter.y - (baseW / 2) * sin(perpAngle))
            let w1 = CGPoint(x: baseCenter.x + (wingW / 2) * cos(perpAngle), y: baseCenter.y + (wingW / 2) * sin(perpAngle))
            let w2 = CGPoint(x: baseCenter.x - (wingW / 2) * cos(perpAngle), y: baseCenter.y - (wingW / 2) * sin(perpAngle))

            context.beginPath()
            context.move(to: s1)
            context.addLine(to: b1)
            context.addLine(to: w1)
            context.addLine(to: end)
            context.addLine(to: w2)
            context.addLine(to: b2)
            context.addLine(to: s2)
            context.closePath()
            context.fillPath()

        case 5: // Block / hollow arrow: ===>
            let shaftHalfW = max(3, lineWidth * 1.2)
            let headBaseHalfW = shaftHalfW * 2.2
            let hLen = max(headLength * 1.2, 14)
            let tip = end
            let headBaseCenter = CGPoint(x: end.x - hLen * cos(angle), y: end.y - hLen * sin(angle))
            let h1 = CGPoint(x: headBaseCenter.x + headBaseHalfW * cos(perpAngle), y: headBaseCenter.y + headBaseHalfW * sin(perpAngle))
            let h2 = CGPoint(x: headBaseCenter.x - headBaseHalfW * cos(perpAngle), y: headBaseCenter.y - headBaseHalfW * sin(perpAngle))
            let s1 = CGPoint(x: start.x + shaftHalfW * cos(perpAngle), y: start.y + shaftHalfW * sin(perpAngle))
            let s2 = CGPoint(x: start.x - shaftHalfW * cos(perpAngle), y: start.y - shaftHalfW * sin(perpAngle))
            let j1 = CGPoint(x: headBaseCenter.x + shaftHalfW * cos(perpAngle), y: headBaseCenter.y + shaftHalfW * sin(perpAngle))
            let j2 = CGPoint(x: headBaseCenter.x - shaftHalfW * cos(perpAngle), y: headBaseCenter.y - shaftHalfW * sin(perpAngle))

            context.beginPath()
            context.move(to: s1)
            context.addLine(to: j1)
            context.addLine(to: h1)
            context.addLine(to: tip)
            context.addLine(to: h2)
            context.addLine(to: j2)
            context.addLine(to: s2)
            context.closePath()
            if style.isFilled {
                context.fillPath()
            } else {
                context.setLineWidth(max(1.5, lineWidth * 0.7))
                context.strokePath()
            }

        case 6: // Single T-bar: |——>
            let barHalfLen = headLength * 0.7
            let t1 = CGPoint(x: start.x + barHalfLen * cos(perpAngle), y: start.y + barHalfLen * sin(perpAngle))
            let t2 = CGPoint(x: start.x - barHalfLen * cos(perpAngle), y: start.y - barHalfLen * sin(perpAngle))
            let wingAngle = CGFloat.pi / 6.5
            let h1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let h2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            context.beginPath()
            context.move(to: t1)
            context.addLine(to: t2)
            context.move(to: h1)
            context.addLine(to: end)
            context.addLine(to: h2)
            context.strokePath()

        case 7: // Double T-bar: |——|
            let barHalfLen = headLength * 0.7
            let st1 = CGPoint(x: start.x + barHalfLen * cos(perpAngle), y: start.y + barHalfLen * sin(perpAngle))
            let st2 = CGPoint(x: start.x - barHalfLen * cos(perpAngle), y: start.y - barHalfLen * sin(perpAngle))
            let et1 = CGPoint(x: end.x + barHalfLen * cos(perpAngle), y: end.y + barHalfLen * sin(perpAngle))
            let et2 = CGPoint(x: end.x - barHalfLen * cos(perpAngle), y: end.y - barHalfLen * sin(perpAngle))
            context.beginPath()
            context.move(to: st1)
            context.addLine(to: st2)
            context.move(to: et1)
            context.addLine(to: et2)
            context.strokePath()

        case 8: // Plain line: ————
            break

        default:
            break
        }
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
