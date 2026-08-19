import CoreGraphics
import TranslatorCore

struct PinSizeLimits: Equatable {
    let minimum: CGSize
    let maximum: CGSize
}

/// Thin forwarding layer over `capture-core`.
enum PinResizeGeometry {
    static func operableInitialSize(
        _ imageSize: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        pinOperableInitialSize(
            imageSize: CaptureSize(width: imageSize.width, height: imageSize.height),
            maximumSize: CaptureSize(width: maximumSize.width, height: maximumSize.height)
        ).cgValue
    }

    static func sizeLimits(for initialSize: CGSize) -> PinSizeLimits {
        let limits = pinSizeLimits(
            initialSize: CaptureSize(width: initialSize.width, height: initialSize.height)
        )
        return PinSizeLimits(
            minimum: limits.minimum.cgValue,
            maximum: limits.maximum.cgValue
        )
    }

    static func scaledFrame(
        _ frame: CGRect,
        requestedScale: CGFloat,
        anchorInWindow: CGPoint,
        minimumSize: CGSize,
        maximumSize: CGSize
    ) -> CGRect {
        pinScaledFrame(
            frame: CaptureRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            requestedScale: requestedScale,
            anchorInWindow: CapturePoint(x: anchorInWindow.x, y: anchorInWindow.y),
            minimumSize: CaptureSize(width: minimumSize.width, height: minimumSize.height),
            maximumSize: CaptureSize(width: maximumSize.width, height: maximumSize.height)
        ).cgValue
    }

    static func originKeepingWindowVisible(
        proposedOrigin: CGPoint,
        windowSize: CGSize,
        visibleFrame: CGRect,
        minimumVisibleLength: CGFloat = 32
    ) -> CGPoint {
        pinOriginKeepingWindowVisible(
            proposedOrigin: CapturePoint(x: proposedOrigin.x, y: proposedOrigin.y),
            windowSize: CaptureSize(width: windowSize.width, height: windowSize.height),
            visibleFrame: CaptureRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.origin.y,
                width: visibleFrame.width,
                height: visibleFrame.height
            ),
            minimumVisibleLength: minimumVisibleLength
        ).cgValue
    }
}

private extension CaptureSize {
    var cgValue: CGSize { CGSize(width: width, height: height) }
}

private extension CapturePoint {
    var cgValue: CGPoint { CGPoint(x: x, y: y) }
}

private extension CaptureRect {
    var cgValue: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
