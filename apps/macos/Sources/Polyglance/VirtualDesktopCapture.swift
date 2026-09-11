import AppKit
import CoreGraphics

struct VirtualDesktopCapture {
    struct Segment {
        let image: CGImage
        let frame: CGRect
        let backingScaleFactor: CGFloat
    }

    let image: CGImage
    let frame: CGRect

    static func unionFrame(_ frames: [CGRect]) -> CGRect {
        frames
            .map(\.standardized)
            .filter { !$0.isNull && !$0.isEmpty }
            .reduce(CGRect.null) { $0.union($1) }
    }

    static func globalFrame(for localFrame: CGRect, in captureFrame: CGRect) -> CGRect {
        localFrame.offsetBy(dx: captureFrame.minX, dy: captureFrame.minY)
    }

    static func compose(_ segments: [Segment]) -> VirtualDesktopCapture? {
        let frame = unionFrame(segments.map(\.frame))
        guard !frame.isNull, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let scale = max(1, segments.map(\.backingScaleFactor).max() ?? 1)
        let pixelWidth = max(1, Int(ceil(frame.width * scale)))
        let pixelHeight = max(1, Int(ceil(frame.height * scale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: frame.size))

        for segment in segments {
            let destination = segment.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            context.draw(segment.image, in: destination)
        }

        guard let image = context.makeImage() else {
            return nil
        }
        return VirtualDesktopCapture(image: image, frame: frame)
    }
}

struct VirtualDesktopRegionDetector: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let frame: CGRect
        let detector: ScreenshotRegionDetector
    }

    let captureFrame: CGRect
    let entries: [Entry]

    func windowRegion(at point: CGPoint) -> CGRect? {
        mappedRegion(at: point) { $0.windowRegion(at: $1) }
    }

    func refinedElementRegion(at point: CGPoint) -> CGRect? {
        mappedRegion(at: point) { $0.refinedElementRegion(at: $1) }
    }

    private func mappedRegion(
        at point: CGPoint,
        lookup: (ScreenshotRegionDetector, CGPoint) -> CGRect?
    ) -> CGRect? {
        let globalPoint = CGPoint(
            x: captureFrame.minX + point.x,
            y: captureFrame.minY + point.y
        )
        guard let entry = entries.first(where: { $0.frame.contains(globalPoint) }) else {
            return nil
        }
        let localPoint = CGPoint(
            x: globalPoint.x - entry.frame.minX,
            y: globalPoint.y - entry.frame.minY
        )
        guard let localRegion = lookup(entry.detector, localPoint) else {
            return nil
        }
        return localRegion.offsetBy(
            dx: entry.frame.minX - captureFrame.minX,
            dy: entry.frame.minY - captureFrame.minY
        )
    }
}
