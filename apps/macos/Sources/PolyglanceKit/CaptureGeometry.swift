import CoreGraphics
import TranslatorCore

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

/// Thin forwarding layer over `capture-core`.
///
/// The geometry itself lives in Rust so Windows and Linux share one
/// implementation; this type only maps between CoreGraphics and the FFI shapes.
public enum CaptureGeometry {
    public static func selectionRect(
        from start: CGPoint,
        to end: CGPoint,
        in bounds: CGRect
    ) -> CGRect {
        captureSelectionRect(
            start: start.captureValue,
            end: end.captureValue,
            bounds: bounds.captureValue
        ).cgValue
    }

    public static func pixelCropRect(
        selection: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGRect {
        capturePixelCropRect(
            selection: selection.captureValue,
            viewSize: viewSize.captureValue,
            imagePixelSize: imagePixelSize.captureValue
        ).cgValue
    }

    public static func outputPixelSize(
        selection: CGRect,
        viewSize: CGSize,
        imagePixelSize: CGSize
    ) -> CGSize {
        captureOutputPixelSize(
            selection: selection.captureValue,
            viewSize: viewSize.captureValue,
            imagePixelSize: imagePixelSize.captureValue
        ).cgValue
    }

    public static func isUsable(_ selection: CGRect, minimumSide: CGFloat = 4) -> Bool {
        captureIsUsable(selection: selection.captureValue, minimumSide: minimumSide)
    }

    public static func fittedPinSize(
        imageSize: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        captureFittedPinSize(
            imageSize: imageSize.captureValue,
            maximumSize: maximumSize.captureValue
        ).cgValue
    }

    public static func preferredCapturePixelSize(
        screenPointSize: CGSize,
        backingScaleFactor: CGFloat,
        reportedPixelSize: CGSize
    ) -> CGSize {
        capturePreferredCapturePixelSize(
            screenPointSize: screenPointSize.captureValue,
            backingScaleFactor: backingScaleFactor,
            reportedPixelSize: reportedPixelSize.captureValue
        ).cgValue
    }

    public static func toolbarOrigin(
        selection: CGRect,
        toolbarSize: CGSize,
        bounds: CGRect,
        spacing: CGFloat = 8,
        edgeInset: CGFloat = 8
    ) -> CGPoint {
        captureToolbarOrigin(
            selection: selection.captureValue,
            toolbarSize: toolbarSize.captureValue,
            bounds: bounds.captureValue,
            spacing: spacing,
            edgeInset: edgeInset
        ).cgValue
    }

    public static func fittedToolbarSize(
        preferred: CGSize,
        bounds: CGRect,
        edgeInset: CGFloat = 8
    ) -> CGSize {
        captureFittedToolbarSize(
            preferred: preferred.captureValue,
            bounds: bounds.captureValue,
            edgeInset: edgeInset
        ).cgValue
    }

    public static func annotationPixelPoint(
        _ point: CGPoint,
        selection: CGRect,
        imagePixelSize: CGSize
    ) -> CGPoint {
        captureAnnotationPixelPoint(
            point: point.captureValue,
            selection: selection.captureValue,
            imagePixelSize: imagePixelSize.captureValue
        ).cgValue
    }

    public static func selectionEditTarget(
        at point: CGPoint,
        selection: CGRect,
        handleTolerance: CGFloat = 6
    ) -> CaptureSelectionEditTarget? {
        captureSelectionEditTarget(
            point: point.captureValue,
            selection: selection.captureValue,
            handleTolerance: handleTolerance
        )?.selectionValue
    }

    public static func selectionExpansionTarget(
        at point: CGPoint,
        selection: CGRect
    ) -> CaptureSelectionEditTarget? {
        captureSelectionExpansionTarget(
            point: point.captureValue,
            selection: selection.captureValue
        )?.selectionValue
    }

    public static func expandedSelection(
        _ selection: CGRect,
        toward point: CGPoint,
        in bounds: CGRect
    ) -> CGRect {
        captureExpandedSelectionToward(
            selection: selection.captureValue,
            point: point.captureValue,
            bounds: bounds.captureValue
        ).cgValue
    }

    public static func expandedSelection(
        _ selection: CGRect,
        toward point: CGPoint,
        target: CaptureSelectionEditTarget,
        in bounds: CGRect
    ) -> CGRect {
        captureExpandedSelection(
            selection: selection.captureValue,
            point: point.captureValue,
            target: target.captureValue,
            bounds: bounds.captureValue
        ).cgValue
    }

    public static func editedSelection(
        original: CGRect,
        dragStart: CGPoint,
        current: CGPoint,
        target: CaptureSelectionEditTarget,
        bounds: CGRect,
        minimumSide: CGFloat = 4
    ) -> CGRect {
        captureEditedSelection(
            original: original.captureValue,
            dragStart: dragStart.captureValue,
            current: current.captureValue,
            target: target.captureValue,
            bounds: bounds.captureValue,
            minimumSide: minimumSide
        ).cgValue
    }

    public static func adjustedSelection(
        _ selection: CGRect,
        by adjustment: CaptureSelectionKeyboardAdjustment,
        in bounds: CGRect,
        minimumSide: CGFloat = 1,
        pixelsPerPoint: CGFloat = 1
    ) -> CGRect {
        captureAdjustedSelection(
            selection: selection.captureValue,
            adjustment: adjustment.captureValue,
            bounds: bounds.captureValue,
            minimumSide: minimumSide,
            pixelsPerPoint: pixelsPerPoint
        ).cgValue
    }
}

private extension CGPoint {
    var captureValue: CapturePoint { CapturePoint(x: x, y: y) }
}

private extension CGSize {
    var captureValue: CaptureSize { CaptureSize(width: width, height: height) }
}

private extension CGRect {
    var captureValue: CaptureRect {
        CaptureRect(x: origin.x, y: origin.y, width: width, height: height)
    }
}

private extension CapturePoint {
    var cgValue: CGPoint { CGPoint(x: x, y: y) }
}

private extension CaptureSize {
    var cgValue: CGSize { CGSize(width: width, height: height) }
}

private extension CaptureRect {
    var cgValue: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

private extension CaptureSelectionResizeHandle {
    var captureValue: CaptureResizeHandle {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}

private extension CaptureResizeHandle {
    var selectionValue: CaptureSelectionResizeHandle {
        switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
    }
}

private extension CaptureSelectionEditTarget {
    var captureValue: CaptureEditTarget {
        switch self {
        case .move:
            return .move
        case let .resize(handle):
            return .resize(handle: handle.captureValue)
        }
    }
}

private extension CaptureEditTarget {
    var selectionValue: CaptureSelectionEditTarget {
        switch self {
        case .move:
            return .move
        case let .resize(handle):
            return .resize(handle.selectionValue)
        }
    }
}

private extension CaptureSelectionKeyboardAdjustment {
    var captureValue: CaptureKeyboardAdjustment {
        let direction: CaptureKeyboardDirection = switch self.direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
        let operation: CaptureKeyboardOperation = switch self.operation {
        case .move: .move
        case .shrink: .shrink
        case .expand: .expand
        }
        let step: CaptureKeyboardStep = switch self.step {
        case .standard: .standard
        case .accelerated: .accelerated
        }
        return CaptureKeyboardAdjustment(
            direction: direction,
            operation: operation,
            step: step
        )
    }
}
