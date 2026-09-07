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

    static let defaultColor = NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1.0)
    static let `default` = ScreenshotAnnotationStyle(color: defaultColor, lineWidth: 3, arrowStyle: 4)

    init(
        color: NSColor = ScreenshotAnnotationStyle.defaultColor,
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

    var boundingBox: CGRect {
        switch self {
        case let .rectangle(start, end, _),
             let .ellipse(start, end, _):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
        case let .line(start, end, _),
             let .arrow(start, end, _):
            return CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
        case let .text(origin, text, style):
            let effectiveSize = max(1, style.fontSize)
            let font = NSFont.systemFont(ofSize: effectiveSize, weight: style.isBold ? .bold : .medium)
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(
                x: origin.x - 4,
                y: origin.y - 2,
                width: max(size.width + 8, 10),
                height: max(size.height + 4, 10)
            )
        case let .number(origin, _, style):
            let radius = max(18, style.lineWidth * 6) / 2.0
            return CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
        case let .freehand(points, _):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for pt in points {
                minX = min(minX, pt.x)
                maxX = max(maxX, pt.x)
                minY = min(minY, pt.y)
                maxY = max(maxY, pt.y)
            }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        case let .mosaic(points, style):
            if style.shapeType == 1, let first = points.first, let last = points.last {
                return CGRect(
                    x: min(first.x, last.x),
                    y: min(first.y, last.y),
                    width: max(abs(last.x - first.x), 1),
                    height: max(abs(last.y - first.y), 1)
                )
            }
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for pt in points {
                minX = min(minX, pt.x)
                maxX = max(maxX, pt.x)
                minY = min(minY, pt.y)
                maxY = max(maxY, pt.y)
            }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        }
    }

    func handles() -> [AnnotationHandle] {
        switch self {
        case let .line(start, end, _),
             let .arrow(start, end, _):
            return [
                AnnotationHandle(type: .start, point: start),
                AnnotationHandle(type: .end, point: end),
            ]
        case .rectangle, .ellipse:
            let box = boundingBox
            return [
                AnnotationHandle(type: .topLeft, point: CGPoint(x: box.minX, y: box.minY)),
                AnnotationHandle(type: .top, point: CGPoint(x: box.midX, y: box.minY)),
                AnnotationHandle(type: .topRight, point: CGPoint(x: box.maxX, y: box.minY)),
                AnnotationHandle(type: .right, point: CGPoint(x: box.maxX, y: box.midY)),
                AnnotationHandle(type: .bottomRight, point: CGPoint(x: box.maxX, y: box.maxY)),
                AnnotationHandle(type: .bottom, point: CGPoint(x: box.midX, y: box.maxY)),
                AnnotationHandle(type: .bottomLeft, point: CGPoint(x: box.minX, y: box.maxY)),
                AnnotationHandle(type: .left, point: CGPoint(x: box.minX, y: box.midY)),
            ]
        case let .mosaic(points, style):
            if style.shapeType == 1, points.count >= 2 {
                let box = boundingBox
                return [
                    AnnotationHandle(type: .topLeft, point: CGPoint(x: box.minX, y: box.minY)),
                    AnnotationHandle(type: .top, point: CGPoint(x: box.midX, y: box.minY)),
                    AnnotationHandle(type: .topRight, point: CGPoint(x: box.maxX, y: box.minY)),
                    AnnotationHandle(type: .right, point: CGPoint(x: box.maxX, y: box.midY)),
                    AnnotationHandle(type: .bottomRight, point: CGPoint(x: box.maxX, y: box.maxY)),
                    AnnotationHandle(type: .bottom, point: CGPoint(x: box.midX, y: box.maxY)),
                    AnnotationHandle(type: .bottomLeft, point: CGPoint(x: box.minX, y: box.maxY)),
                    AnnotationHandle(type: .left, point: CGPoint(x: box.minX, y: box.midY)),
                ]
            }
            return []
        default:
            return []
        }
    }

    func hitTestHandle(point: CGPoint, handleRadius: CGFloat = 8) -> AnnotationHandleType? {
        for handle in handles() {
            if hypot(point.x - handle.point.x, point.y - handle.point.y) <= handleRadius {
                return handle.type
            }
        }
        return nil
    }

    func hitTest(point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let tol = max(tolerance, 4)
        switch self {
        case let .line(start, end, style),
             let .arrow(start, end, style):
            let d = pointToSegmentDistance(point: point, start: start, end: end)
            return d <= (tol + max(style.lineWidth, 4) / 2)

        case let .rectangle(start, end, style):
            let box = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
            if style.isFilled {
                return box.insetBy(dx: -tol, dy: -tol).contains(point)
            }
            let d1 = pointToSegmentDistance(point: point, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.minY))
            let d2 = pointToSegmentDistance(point: point, start: CGPoint(x: box.maxX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY))
            let d3 = pointToSegmentDistance(point: point, start: CGPoint(x: box.maxX, y: box.maxY), end: CGPoint(x: box.minX, y: box.maxY))
            let d4 = pointToSegmentDistance(point: point, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.minX, y: box.minY))
            let minD = min(d1, d2, d3, d4)
            return minD <= (tol + style.lineWidth / 2)

        case let .ellipse(start, end, style):
            let box = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
            let rx = box.width / 2
            let ry = box.height / 2
            guard rx > 0, ry > 0 else { return false }
            let cx = box.midX
            let cy = box.midY
            let dx = point.x - cx
            let dy = point.y - cy
            let d = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)
            if style.isFilled {
                return d <= 1.05
            }
            let normDist = sqrt(d)
            let pixelDist = abs(normDist - 1.0) * min(rx, ry)
            return pixelDist <= (tol + style.lineWidth / 2)

        case .text, .number:
            return boundingBox.insetBy(dx: -tol, dy: -tol).contains(point)

        case let .freehand(points, style):
            guard points.count > 1 else {
                if let pt = points.first {
                    return hypot(point.x - pt.x, point.y - pt.y) <= tol + style.lineWidth / 2
                }
                return false
            }
            for i in 0..<(points.count - 1) {
                if pointToSegmentDistance(point: point, start: points[i], end: points[i + 1]) <= tol + style.lineWidth / 2 {
                    return true
                }
            }
            return false

        case let .mosaic(points, style):
            if style.shapeType == 1, let first = points.first, let last = points.last {
                let box = CGRect(
                    x: min(first.x, last.x),
                    y: min(first.y, last.y),
                    width: max(abs(last.x - first.x), 1),
                    height: max(abs(last.y - first.y), 1)
                )
                return box.insetBy(dx: -tol, dy: -tol).contains(point)
            }
            guard points.count > 1 else { return false }
            for i in 0..<(points.count - 1) {
                if pointToSegmentDistance(point: point, start: points[i], end: points[i + 1]) <= tol + style.lineWidth * 4 {
                    return true
                }
            }
            return false
        }
    }

    func moving(by delta: CGPoint) -> ScreenshotAnnotationElement {
        switch self {
        case let .freehand(points, style):
            return .freehand(points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }, style: style)
        case let .rectangle(start, end, style):
            return .rectangle(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y), end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), style: style)
        case let .ellipse(start, end, style):
            return .ellipse(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y), end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), style: style)
        case let .line(start, end, style):
            return .line(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y), end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), style: style)
        case let .arrow(start, end, style):
            return .arrow(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y), end: CGPoint(x: end.x + delta.x, y: end.y + delta.y), style: style)
        case let .text(origin, text, style):
            return .text(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), text: text, style: style)
        case let .mosaic(points, style):
            return .mosaic(points: points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }, style: style)
        case let .number(origin, value, style):
            return .number(origin: CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), value: value, style: style)
        }
    }

    func resizing(handle: AnnotationHandleType, to point: CGPoint) -> ScreenshotAnnotationElement {
        switch self {
        case let .line(start, end, style):
            if handle == .start {
                return .line(start: point, end: end, style: style)
            } else {
                return .line(start: start, end: point, style: style)
            }
        case let .arrow(start, end, style):
            if handle == .start {
                return .arrow(start: point, end: end, style: style)
            } else {
                return .arrow(start: start, end: point, style: style)
            }
        case let .rectangle(start, end, style):
            let (newStart, newEnd) = resizeRect(start: start, end: end, handle: handle, to: point)
            return .rectangle(start: newStart, end: newEnd, style: style)
        case let .ellipse(start, end, style):
            let (newStart, newEnd) = resizeRect(start: start, end: end, handle: handle, to: point)
            return .ellipse(start: newStart, end: newEnd, style: style)
        case let .mosaic(points, style):
            if style.shapeType == 1, let first = points.first, let last = points.last {
                let (newStart, newEnd) = resizeRect(start: first, end: last, handle: handle, to: point)
                return .mosaic(points: [newStart, newEnd], style: style)
            }
            return self
        default:
            return self
        }
    }

    func withStyle(_ newStyle: ScreenshotAnnotationStyle) -> ScreenshotAnnotationElement {
        switch self {
        case let .freehand(points, _):
            return .freehand(points: points, style: newStyle)
        case let .rectangle(start, end, _):
            return .rectangle(start: start, end: end, style: newStyle)
        case let .ellipse(start, end, _):
            return .ellipse(start: start, end: end, style: newStyle)
        case let .line(start, end, _):
            return .line(start: start, end: end, style: newStyle)
        case let .arrow(start, end, _):
            return .arrow(start: start, end: end, style: newStyle)
        case let .text(origin, text, _):
            return .text(origin: origin, text: text, style: newStyle)
        case let .mosaic(points, _):
            return .mosaic(points: points, style: newStyle)
        case let .number(origin, value, _):
            return .number(origin: origin, value: value, style: newStyle)
        }
    }
}

enum AnnotationHandleType: String, CaseIterable, Equatable {
    case start
    case end
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

struct AnnotationHandle: Equatable {
    let type: AnnotationHandleType
    let point: CGPoint
}

private func pointToSegmentDistance(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    if lengthSquared == 0 {
        return hypot(point.x - start.x, point.y - start.y)
    }
    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    let projX = start.x + t * dx
    let projY = start.y + t * dy
    return hypot(point.x - projX, point.y - projY)
}

private func resizeRect(start: CGPoint, end: CGPoint, handle: AnnotationHandleType, to point: CGPoint) -> (CGPoint, CGPoint) {
    let x1 = min(start.x, end.x)
    let x2 = max(start.x, end.x)
    let y1 = min(start.y, end.y)
    let y2 = max(start.y, end.y)

    switch handle {
    case .topLeft:
        return (point, CGPoint(x: x2, y: y2))
    case .top:
        return (CGPoint(x: x1, y: point.y), CGPoint(x: x2, y: y2))
    case .topRight:
        return (CGPoint(x: x1, y: point.y), CGPoint(x: point.x, y: y2))
    case .right:
        return (CGPoint(x: x1, y: y1), CGPoint(x: point.x, y: y2))
    case .bottomRight:
        return (CGPoint(x: x1, y: y1), point)
    case .bottom:
        return (CGPoint(x: x1, y: y1), CGPoint(x: x2, y: point.y))
    case .bottomLeft:
        return (CGPoint(x: point.x, y: y1), CGPoint(x: x2, y: point.y))
    case .left:
        return (CGPoint(x: point.x, y: y1), CGPoint(x: x2, y: y2))
    case .start, .end:
        return (start, end)
    }
}

struct ScreenshotAnnotationHistory {
    private(set) var elements: [ScreenshotAnnotationElement] = []
    private var undoStack: [[ScreenshotAnnotationElement]] = []
    private var redoStack: [[ScreenshotAnnotationElement]] = []
    var selectedIndex: Int? = nil

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedElement: ScreenshotAnnotationElement? {
        guard let idx = selectedIndex, elements.indices.contains(idx) else { return nil }
        return elements[idx]
    }

    mutating func append(_ element: ScreenshotAnnotationElement) {
        undoStack.append(elements)
        elements.append(element)
        selectedIndex = elements.count - 1
        redoStack.removeAll()
    }

    @discardableResult
    mutating func undo() -> ScreenshotAnnotationElement? {
        guard !undoStack.isEmpty else { return nil }
        let currentLast = elements.last
        redoStack.append(elements)
        elements = undoStack.removeLast()
        if let idx = selectedIndex, !elements.indices.contains(idx) {
            selectedIndex = nil
        }
        return currentLast
    }

    @discardableResult
    mutating func redo() -> ScreenshotAnnotationElement? {
        guard !redoStack.isEmpty else { return nil }
        undoStack.append(elements)
        elements = redoStack.removeLast()
        if let idx = selectedIndex, !elements.indices.contains(idx) {
            selectedIndex = nil
        }
        return elements.last
    }

    mutating func removeAll() {
        if !elements.isEmpty {
            undoStack.append(elements)
        }
        elements.removeAll()
        redoStack.removeAll()
        selectedIndex = nil
    }

    mutating func select(at index: Int?) {
        if let idx = index, elements.indices.contains(idx) {
            selectedIndex = idx
        } else {
            selectedIndex = nil
        }
    }

    mutating func beginInteractiveChange() {
        undoStack.append(elements)
        redoStack.removeAll()
    }

    mutating func updateSelected(to element: ScreenshotAnnotationElement) {
        guard let idx = selectedIndex, elements.indices.contains(idx) else { return }
        elements[idx] = element
    }

    mutating func deleteSelected() -> ScreenshotAnnotationElement? {
        guard let idx = selectedIndex, elements.indices.contains(idx) else { return nil }
        undoStack.append(elements)
        let removed = elements.remove(at: idx)
        selectedIndex = nil
        redoStack.removeAll()
        return removed
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
        transformedHistory.undoStack = undoStack.map { $0.map { $0.transformed(transform) } }
        transformedHistory.redoStack = redoStack.map { $0.map { $0.transformed(transform) } }
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
                drawPlainStraightLine(
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

    private static func drawPlainStraightLine(
        from start: CGPoint,
        to end: CGPoint,
        style: ScreenshotAnnotationStyle,
        lineWidth: CGFloat,
        in context: CGContext
    ) {
        guard start != end else { return }
        context.saveGState()
        context.setStrokeColor(style.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        applyDashPattern(style.lineDashPattern, isDashed: style.isDashed, lineWidth: lineWidth, in: context)
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    private static func drawArrow(
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
        let headLength = min(max(lineWidth * 3.0, 7), length * 0.38)
        let perpAngle = angle + CGFloat.pi / 2
        let arrowStyle = style.arrowStyle

        var lineStart = start
        var lineEnd = end

        if arrowStyle == 7 || arrowStyle == 8 {
            lineEnd = CGPoint(x: end.x - headLength * 0.75 * cos(angle), y: end.y - headLength * 0.75 * sin(angle))
        }
        if arrowStyle == 8 {
            lineStart = CGPoint(x: start.x + headLength * 0.75 * cos(angle), y: start.y + headLength * 0.75 * sin(angle))
        }

        if arrowStyle != 4 && arrowStyle != 5 {
            context.saveGState()
            applyDashPattern(style.lineDashPattern, isDashed: style.isDashed, lineWidth: lineWidth, in: context)
            if arrowStyle == 2 || arrowStyle == 3 {
                context.setLineWidth(max(lineWidth * 1.6, lineWidth + 2.0))
                context.setLineCap(.round)
                context.setLineJoin(.round)
            }
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

        case 2: // Bold single open arrow: ——>
            let wingAngle = CGFloat.pi / 6.5
            let h1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let h2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            context.saveGState()
            context.setLineWidth(max(lineWidth * 1.6, lineWidth + 2.0))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: h1)
            context.addLine(to: end)
            context.addLine(to: h2)
            context.strokePath()
            context.restoreGState()

        case 3: // Bold double open arrow: <——>
            let wingAngle = CGFloat.pi / 6.5
            let eh1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let eh2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            let sh1 = CGPoint(x: start.x + headLength * cos(angle - wingAngle), y: start.y + headLength * sin(angle - wingAngle))
            let sh2 = CGPoint(x: start.x + headLength * cos(angle + wingAngle), y: start.y + headLength * sin(angle + wingAngle))
            context.saveGState()
            context.setLineWidth(max(lineWidth * 1.6, lineWidth + 2.0))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: eh1)
            context.addLine(to: end)
            context.addLine(to: eh2)
            context.move(to: sh1)
            context.addLine(to: start)
            context.addLine(to: sh2)
            context.strokePath()
            context.restoreGState()

        case 4: // Hollow tapered expanding arrow (左小右大空心 - DEFAULT)
            let startW = max(1.2, lineWidth * 0.35)
            let baseW = max(3.2, lineWidth * 1.5)
            let hLen = min(max(lineWidth * 3.2, 9), length * 0.4)
            let wingW = baseW * 1.6
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
            context.saveGState()
            context.setLineWidth(max(1.5, lineWidth * 0.7))
            context.strokePath()
            context.restoreGState()

        case 5: // Solid tapered expanding arrow (左小右大实心)
            let startW = max(1.2, lineWidth * 0.35)
            let baseW = max(3.2, lineWidth * 1.5)
            let hLen = min(max(lineWidth * 3.2, 9), length * 0.4)
            let wingW = baseW * 1.6
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

        case 6: // Double T-bar line: |——|
            let barHalfLen = headLength * 0.65
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

        case 7: // Single filled triangle: ——▶
            let baseW = headLength * 0.6
            let tip = end
            let b1 = CGPoint(x: end.x - headLength * cos(angle) + baseW * cos(perpAngle), y: end.y - headLength * sin(angle) + baseW * sin(perpAngle))
            let b2 = CGPoint(x: end.x - headLength * cos(angle) - baseW * cos(perpAngle), y: end.y - headLength * sin(angle) - baseW * sin(perpAngle))
            context.beginPath()
            context.move(to: tip)
            context.addLine(to: b1)
            context.addLine(to: b2)
            context.closePath()
            context.fillPath()

        case 8: // Double filled triangle: ◀——▶
            let baseW = headLength * 0.6
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

        case 9: // Double T-bar with arrows: |<——>|
            let barHalfLen = headLength * 0.65
            let st1 = CGPoint(x: start.x + barHalfLen * cos(perpAngle), y: start.y + barHalfLen * sin(perpAngle))
            let st2 = CGPoint(x: start.x - barHalfLen * cos(perpAngle), y: start.y - barHalfLen * sin(perpAngle))
            let et1 = CGPoint(x: end.x + barHalfLen * cos(perpAngle), y: end.y + barHalfLen * sin(perpAngle))
            let et2 = CGPoint(x: end.x - barHalfLen * cos(perpAngle), y: end.y - barHalfLen * sin(perpAngle))
            let wingAngle = CGFloat.pi / 6.5
            let eh1 = CGPoint(x: end.x - headLength * cos(angle - wingAngle), y: end.y - headLength * sin(angle - wingAngle))
            let eh2 = CGPoint(x: end.x - headLength * cos(angle + wingAngle), y: end.y - headLength * sin(angle + wingAngle))
            let sh1 = CGPoint(x: start.x + headLength * cos(angle - wingAngle), y: start.y + headLength * sin(angle - wingAngle))
            let sh2 = CGPoint(x: start.x + headLength * cos(angle + wingAngle), y: start.y + headLength * sin(angle + wingAngle))
            context.beginPath()
            context.move(to: st1)
            context.addLine(to: st2)
            context.move(to: et1)
            context.addLine(to: et2)
            context.move(to: eh1)
            context.addLine(to: end)
            context.addLine(to: eh2)
            context.move(to: sh1)
            context.addLine(to: start)
            context.addLine(to: sh2)
            context.strokePath()

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

    static func drawSelection(
        for element: ScreenshotAnnotationElement,
        in context: CGContext,
        pointTransform: (CGPoint) -> CGPoint = { $0 },
        handleRadius: CGFloat = 5
    ) {
        context.saveGState()
        defer { context.restoreGState() }

        let selectionColor = NSColor(srgbRed: 0.12, green: 0.53, blue: 0.90, alpha: 1.0).cgColor
        let handleFillColor = NSColor.white.cgColor

        switch element {
        case .line, .arrow:
            break
        default:
            let box = element.boundingBox
            let p1 = pointTransform(box.origin)
            let p2 = pointTransform(CGPoint(x: box.maxX, y: box.maxY))
            let transformedBox = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: max(abs(p2.x - p1.x), 2),
                height: max(abs(p2.y - p1.y), 2)
            )
            context.setStrokeColor(selectionColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.stroke(transformedBox.insetBy(dx: -2, dy: -2))
        }

        for handle in element.handles() {
            let pt = pointTransform(handle.point)
            let handleRect = CGRect(
                x: pt.x - handleRadius,
                y: pt.y - handleRadius,
                width: handleRadius * 2,
                height: handleRadius * 2
            )
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(handleFillColor)
            context.fillEllipse(in: handleRect)
            context.setStrokeColor(selectionColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: handleRect)
        }
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
