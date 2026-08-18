import CoreGraphics

public enum CaptureSelectionResizeHandle: Equatable, Sendable {
    case topLeft
    case top
    case topRight
    case right
    case bottomRight
    case bottom
    case bottomLeft
    case left
}

public enum CaptureSelectionEditTarget: Equatable, Sendable {
    case move
    case resize(CaptureSelectionResizeHandle)
}

public enum CaptureSelectionKeyboardDirection: Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum CaptureSelectionKeyboardOperation: Equatable, Sendable {
    case move
    case shrink
    case expand
}

public enum CaptureSelectionKeyboardStep: Equatable, Sendable {
    case standard
    case accelerated

    public var points: CGFloat {
        switch self {
        case .standard:
            return 1
        case .accelerated:
            return 10
        }
    }
}

public struct CaptureSelectionKeyboardAdjustment: Equatable, Sendable {
    public let direction: CaptureSelectionKeyboardDirection
    public let operation: CaptureSelectionKeyboardOperation
    public let step: CaptureSelectionKeyboardStep

    public init(
        direction: CaptureSelectionKeyboardDirection,
        operation: CaptureSelectionKeyboardOperation,
        step: CaptureSelectionKeyboardStep = .standard
    ) {
        self.direction = direction
        self.operation = operation
        self.step = step
    }
}

public enum CaptureGeometry {
    public static func selectionRect(
        from start: CGPoint,
        to end: CGPoint,
        in bounds: CGRect
    ) -> CGRect {
        let clampedStart = clamp(start, to: bounds)
        let clampedEnd = clamp(end, to: bounds)
        return CGRect(
            x: min(clampedStart.x, clampedEnd.x),
            y: min(clampedStart.y, clampedEnd.y),
            width: abs(clampedEnd.x - clampedStart.x),
            height: abs(clampedEnd.y - clampedStart.y)
        )
    }

    public static func pixelCropRect(
        selection: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGRect {
        guard viewSize.width > 0,
              viewSize.height > 0,
              imagePixelSize.width > 0,
              imagePixelSize.height > 0 else {
            return .zero
        }

        let viewBounds = CGRect(origin: .zero, size: viewSize)
        let clippedSelection = selection.standardized.intersection(viewBounds)
        guard !clippedSelection.isNull else {
            return .zero
        }

        let scaleX = imagePixelSize.width / viewSize.width
        let scaleY = imagePixelSize.height / viewSize.height
        let crop = CGRect(
            x: clippedSelection.minX * scaleX,
            y: (viewSize.height - clippedSelection.maxY) * scaleY,
            width: clippedSelection.width * scaleX,
            height: clippedSelection.height * scaleY
        ).integral
        return crop.intersection(CGRect(origin: .zero, size: imagePixelSize))
    }

    public static func outputPixelSize(
        selection: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGSize {
        pixelCropRect(
            selection: selection,
            viewSize: viewSize,
            imagePixelSize: imagePixelSize
        ).size
    }

    public static func isUsable(_ selection: CGRect, minimumSide: CGFloat = 4) -> Bool {
        selection.width >= minimumSide && selection.height >= minimumSide
    }

    public static func fittedPinSize(
        imageSize: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              maximumSize.width > 0,
              maximumSize.height > 0 else {
            return .zero
        }

        let scale = min(
            1,
            maximumSize.width / imageSize.width,
            maximumSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    public static func preferredCapturePixelSize(
        screenPointSize: CGSize,
        backingScaleFactor: CGFloat,
        reportedPixelSize: CGSize
    ) -> CGSize {
        let scaledPointSize = CGSize(
            width: ceil(screenPointSize.width * backingScaleFactor),
            height: ceil(screenPointSize.height * backingScaleFactor)
        )
        return CGSize(
            width: max(scaledPointSize.width, reportedPixelSize.width),
            height: max(scaledPointSize.height, reportedPixelSize.height)
        )
    }

    public static func toolbarOrigin(
        selection: CGRect,
        toolbarSize: CGSize,
        bounds: CGRect,
        spacing: CGFloat = 8,
        edgeInset: CGFloat = 8
    ) -> CGPoint {
        let maximumX = max(bounds.minX + edgeInset, bounds.maxX - toolbarSize.width - edgeInset)
        let x = min(
            max(selection.maxX - toolbarSize.width, bounds.minX + edgeInset),
            maximumX
        )
        let belowY = selection.minY - toolbarSize.height - spacing
        let y: CGFloat
        if belowY >= bounds.minY + edgeInset {
            y = belowY
        } else {
            y = min(
                selection.maxY + spacing,
                bounds.maxY - toolbarSize.height - edgeInset
            )
        }
        return CGPoint(x: x, y: y)
    }

    public static func fittedToolbarSize(
        preferred: CGSize,
        bounds: CGRect,
        edgeInset: CGFloat = 8
    ) -> CGSize {
        let bounds = bounds.standardized
        guard preferred.width > 0,
              preferred.height > 0,
              !bounds.isEmpty,
              !bounds.isNull else {
            return .zero
        }
        let availableWidth = max(1, bounds.width - max(0, edgeInset) * 2)
        let availableHeight = max(1, bounds.height - max(0, edgeInset) * 2)
        return CGSize(
            width: min(preferred.width, availableWidth),
            height: min(preferred.height, availableHeight)
        )
    }

    public static func annotationPixelPoint(
        _ point: CGPoint,
        selection: CGRect,
        imagePixelSize: CGSize
    ) -> CGPoint {
        guard selection.width > 0, selection.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: (point.x - selection.minX) * imagePixelSize.width / selection.width,
            y: (point.y - selection.minY) * imagePixelSize.height / selection.height
        )
    }

    public static func selectionEditTarget(
        at point: CGPoint,
        selection: CGRect,
        handleTolerance: CGFloat = 6
    ) -> CaptureSelectionEditTarget? {
        let selection = selection.standardized
        guard selection.insetBy(dx: -handleTolerance, dy: -handleTolerance).contains(point) else {
            return nil
        }

        let distanceToLeft = abs(point.x - selection.minX)
        let distanceToRight = abs(point.x - selection.maxX)
        let distanceToBottom = abs(point.y - selection.minY)
        let distanceToTop = abs(point.y - selection.maxY)
        let horizontalEdge: CaptureSelectionResizeHandle? = {
            guard min(distanceToLeft, distanceToRight) <= handleTolerance else {
                return nil
            }
            return distanceToLeft <= distanceToRight ? .left : .right
        }()
        let verticalEdge: CaptureSelectionResizeHandle? = {
            guard min(distanceToBottom, distanceToTop) <= handleTolerance else {
                return nil
            }
            return distanceToBottom <= distanceToTop ? .bottom : .top
        }()

        switch (horizontalEdge, verticalEdge) {
        case (.left, .top):
            return .resize(.topLeft)
        case (.right, .top):
            return .resize(.topRight)
        case (.right, .bottom):
            return .resize(.bottomRight)
        case (.left, .bottom):
            return .resize(.bottomLeft)
        case let (horizontal?, nil):
            return .resize(horizontal)
        case let (nil, vertical?):
            return .resize(vertical)
        default:
            return selection.contains(point) ? .move : nil
        }
    }

    public static func selectionExpansionTarget(
        at point: CGPoint,
        selection: CGRect
    ) -> CaptureSelectionEditTarget? {
        let selection = selection.standardized
        guard !selection.isNull, !selection.isEmpty else {
            return nil
        }
        let horizontal: CaptureSelectionResizeHandle? = if point.x < selection.minX {
            .left
        } else if point.x > selection.maxX {
            .right
        } else {
            nil
        }
        let vertical: CaptureSelectionResizeHandle? = if point.y < selection.minY {
            .bottom
        } else if point.y > selection.maxY {
            .top
        } else {
            nil
        }

        switch (horizontal, vertical) {
        case (.left, .top):
            return .resize(.topLeft)
        case (.right, .top):
            return .resize(.topRight)
        case (.right, .bottom):
            return .resize(.bottomRight)
        case (.left, .bottom):
            return .resize(.bottomLeft)
        case let (horizontal?, nil):
            return .resize(horizontal)
        case let (nil, vertical?):
            return .resize(vertical)
        default:
            return nil
        }
    }

    public static func expandedSelection(
        _ selection: CGRect,
        toward point: CGPoint,
        in bounds: CGRect
    ) -> CGRect {
        guard let target = selectionExpansionTarget(at: point, selection: selection) else {
            let clippedSelection = selection.standardized.intersection(bounds.standardized)
            return clippedSelection.isNull ? .zero : clippedSelection
        }
        return expandedSelection(
            selection,
            toward: point,
            target: target,
            in: bounds
        )
    }

    public static func expandedSelection(
        _ selection: CGRect,
        toward point: CGPoint,
        target: CaptureSelectionEditTarget,
        in bounds: CGRect
    ) -> CGRect {
        let bounds = bounds.standardized
        let selection = selection.standardized.intersection(bounds)
        guard !selection.isNull, !selection.isEmpty else {
            return .zero
        }
        let point = clamp(point, to: bounds)
        guard case let .resize(handle) = target else {
            return selection
        }
        let expandsLeft: Bool
        let expandsRight: Bool
        let expandsBottom: Bool
        let expandsTop: Bool
        switch handle {
        case .topLeft:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (true, false, false, true)
        case .top:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (false, false, false, true)
        case .topRight:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (false, true, false, true)
        case .right:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (false, true, false, false)
        case .bottomRight:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (false, true, true, false)
        case .bottom:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (false, false, true, false)
        case .bottomLeft:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (true, false, true, false)
        case .left:
            (expandsLeft, expandsRight, expandsBottom, expandsTop) = (true, false, false, false)
        }
        let minimumX = expandsLeft ? min(selection.minX, point.x) : selection.minX
        let maximumX = expandsRight ? max(selection.maxX, point.x) : selection.maxX
        let minimumY = expandsBottom ? min(selection.minY, point.y) : selection.minY
        let maximumY = expandsTop ? max(selection.maxY, point.y) : selection.maxY
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    public static func editedSelection(
        original: CGRect,
        dragStart: CGPoint,
        current: CGPoint,
        target: CaptureSelectionEditTarget,
        bounds: CGRect,
        minimumSide: CGFloat = 4
    ) -> CGRect {
        let original = original.standardized
        let bounds = bounds.standardized

        switch target {
        case .move:
            let proposedOrigin = CGPoint(
                x: original.minX + current.x - dragStart.x,
                y: original.minY + current.y - dragStart.y
            )
            let maximumX = max(bounds.minX, bounds.maxX - original.width)
            let maximumY = max(bounds.minY, bounds.maxY - original.height)
            return CGRect(
                origin: CGPoint(
                    x: clamp(proposedOrigin.x, minimum: bounds.minX, maximum: maximumX),
                    y: clamp(proposedOrigin.y, minimum: bounds.minY, maximum: maximumY)
                ),
                size: original.size
            )

        case let .resize(handle):
            let deltaX = current.x - dragStart.x
            let deltaY = current.y - dragStart.y
            var minimumX = original.minX
            var maximumX = original.maxX
            var minimumY = original.minY
            var maximumY = original.maxY

            switch handle {
            case .topLeft, .left, .bottomLeft:
                minimumX = clamp(
                    original.minX + deltaX,
                    minimum: bounds.minX,
                    maximum: original.maxX - minimumSide
                )
            case .topRight, .right, .bottomRight:
                maximumX = clamp(
                    original.maxX + deltaX,
                    minimum: original.minX + minimumSide,
                    maximum: bounds.maxX
                )
            case .top, .bottom:
                break
            }

            switch handle {
            case .bottomLeft, .bottom, .bottomRight:
                minimumY = clamp(
                    original.minY + deltaY,
                    minimum: bounds.minY,
                    maximum: original.maxY - minimumSide
                )
            case .topLeft, .top, .topRight:
                maximumY = clamp(
                    original.maxY + deltaY,
                    minimum: original.minY + minimumSide,
                    maximum: bounds.maxY
                )
            case .left, .right:
                break
            }

            return CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            )
        }
    }

    public static func adjustedSelection(
        _ selection: CGRect,
        by adjustment: CaptureSelectionKeyboardAdjustment,
        in bounds: CGRect,
        minimumSide: CGFloat = 1,
        pixelsPerPoint: CGFloat = 1
    ) -> CGRect {
        let bounds = bounds.standardized
        guard !bounds.isEmpty, !bounds.isNull else {
            return .zero
        }
        let selection = selection.standardized.intersection(bounds)
        guard !selection.isEmpty, !selection.isNull else {
            return .zero
        }

        let effectivePixelsPerPoint = pixelsPerPoint.isFinite && pixelsPerPoint > 0
            ? pixelsPerPoint
            : 1
        let distance = adjustment.step.points / effectivePixelsPerPoint
        switch adjustment.operation {
        case .move:
            let delta: CGPoint = switch adjustment.direction {
            case .left:
                CGPoint(x: -distance, y: 0)
            case .right:
                CGPoint(x: distance, y: 0)
            case .up:
                CGPoint(x: 0, y: distance)
            case .down:
                CGPoint(x: 0, y: -distance)
            }
            return CGRect(
                x: clamp(
                    selection.minX + delta.x,
                    minimum: bounds.minX,
                    maximum: bounds.maxX - selection.width
                ),
                y: clamp(
                    selection.minY + delta.y,
                    minimum: bounds.minY,
                    maximum: bounds.maxY - selection.height
                ),
                width: selection.width,
                height: selection.height
            )

        case .shrink:
            let requestedMinimumSide = minimumSide.isFinite && minimumSide > 0
                ? minimumSide
                : 1
            let minimumWidth = min(selection.width, requestedMinimumSide)
            let minimumHeight = min(selection.height, requestedMinimumSide)
            var minimumX = selection.minX
            var maximumX = selection.maxX
            var minimumY = selection.minY
            var maximumY = selection.maxY

            switch adjustment.direction {
            case .left:
                minimumX += min(distance, selection.width - minimumWidth)
            case .right:
                maximumX -= min(distance, selection.width - minimumWidth)
            case .up:
                maximumY -= min(distance, selection.height - minimumHeight)
            case .down:
                minimumY += min(distance, selection.height - minimumHeight)
            }
            return CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            )

        case .expand:
            var minimumX = selection.minX
            var maximumX = selection.maxX
            var minimumY = selection.minY
            var maximumY = selection.maxY

            switch adjustment.direction {
            case .left:
                minimumX = max(bounds.minX, minimumX - distance)
            case .right:
                maximumX = min(bounds.maxX, maximumX + distance)
            case .up:
                maximumY = min(bounds.maxY, maximumY + distance)
            case .down:
                minimumY = max(bounds.minY, minimumY - distance)
            }
            return CGRect(
                x: minimumX,
                y: minimumY,
                width: maximumX - minimumX,
                height: maximumY - minimumY
            )
        }
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
