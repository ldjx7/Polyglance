import CoreGraphics

struct PinSizeLimits: Equatable {
    let minimum: CGSize
    let maximum: CGSize
}

enum PinResizeGeometry {
    private static let minimumWidth: CGFloat = 96
    private static let minimumHeight: CGFloat = 64
    private static let minimumScale: CGFloat = 0.1
    private static let maximumScale: CGFloat = 8
    private static let maximumDimension: CGFloat = 8_192

    static func operableInitialSize(
        _ imageSize: CGSize,
        maximumSize: CGSize
    ) -> CGSize {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              maximumSize.width.isFinite,
              maximumSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0,
              maximumSize.width > 0,
              maximumSize.height > 0 else {
            return .zero
        }
        let scaleNeededForMinimumSize = max(
            1,
            minimumWidth / imageSize.width,
            minimumHeight / imageSize.height
        )
        let scaleAllowedByScreen = min(
            maximumSize.width / imageSize.width,
            maximumSize.height / imageSize.height
        )
        return scaled(imageSize, by: min(scaleNeededForMinimumSize, scaleAllowedByScreen))
    }

    static func sizeLimits(for initialSize: CGSize) -> PinSizeLimits {
        guard initialSize.width.isFinite,
              initialSize.height.isFinite,
              initialSize.width > 0,
              initialSize.height > 0 else {
            return PinSizeLimits(
                minimum: CGSize(width: 1, height: 1),
                maximum: CGSize(width: 1, height: 1)
            )
        }

        let scaleNeededForMinimumSize = max(
            minimumWidth / initialSize.width,
            minimumHeight / initialSize.height
        )
        let lowerScale = min(1, max(minimumScale, scaleNeededForMinimumSize))
        let scaleAllowedByDimensionLimit = min(
            maximumDimension / initialSize.width,
            maximumDimension / initialSize.height
        )
        let upperScale = max(
            1,
            min(
                max(maximumScale, scaleNeededForMinimumSize),
                scaleAllowedByDimensionLimit
            )
        )
        return PinSizeLimits(
            minimum: scaled(initialSize, by: lowerScale),
            maximum: scaled(initialSize, by: upperScale)
        )
    }

    static func scaledFrame(
        _ frame: CGRect,
        requestedScale: CGFloat,
        anchorInWindow: CGPoint,
        minimumSize: CGSize,
        maximumSize: CGSize
    ) -> CGRect {
        guard frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return frame
        }

        let proposedScale = requestedScale.isFinite && requestedScale > 0
            ? requestedScale
            : 1
        let lowerScale = max(
            positiveRatio(minimumSize.width, frame.width),
            positiveRatio(minimumSize.height, frame.height)
        )
        let upperScale = min(
            positiveRatio(maximumSize.width, frame.width, fallback: .greatestFiniteMagnitude),
            positiveRatio(maximumSize.height, frame.height, fallback: .greatestFiniteMagnitude)
        )
        let validLowerScale = max(0, min(lowerScale, upperScale))
        let validUpperScale = max(validLowerScale, upperScale)
        let scale = min(max(proposedScale, validLowerScale), validUpperScale)
        let anchor = CGPoint(
            x: min(max(anchorInWindow.x, 0), frame.width),
            y: min(max(anchorInWindow.y, 0), frame.height)
        )
        let newSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        let newOrigin = CGPoint(
            x: frame.minX + anchor.x - anchor.x * scale,
            y: frame.minY + anchor.y - anchor.y * scale
        )
        return CGRect(origin: newOrigin, size: newSize)
    }

    static func originKeepingWindowVisible(
        proposedOrigin: CGPoint,
        windowSize: CGSize,
        visibleFrame: CGRect,
        minimumVisibleLength: CGFloat = 32
    ) -> CGPoint {
        guard windowSize.width.isFinite,
              windowSize.height.isFinite,
              windowSize.width > 0,
              windowSize.height > 0,
              !visibleFrame.isEmpty else {
            return proposedOrigin
        }

        let visibleWidth = min(
            max(0, minimumVisibleLength),
            windowSize.width,
            visibleFrame.width
        )
        let visibleHeight = min(
            max(0, minimumVisibleLength),
            windowSize.height,
            visibleFrame.height
        )
        return CGPoint(
            x: min(
                max(proposedOrigin.x, visibleFrame.minX - windowSize.width + visibleWidth),
                visibleFrame.maxX - visibleWidth
            ),
            y: min(
                max(proposedOrigin.y, visibleFrame.minY - windowSize.height + visibleHeight),
                visibleFrame.maxY - visibleHeight
            )
        )
    }

    private static func scaled(_ size: CGSize, by scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    private static func positiveRatio(
        _ numerator: CGFloat,
        _ denominator: CGFloat,
        fallback: CGFloat = 0
    ) -> CGFloat {
        guard numerator.isFinite, numerator > 0, denominator > 0 else {
            return fallback
        }
        return numerator / denominator
    }
}
