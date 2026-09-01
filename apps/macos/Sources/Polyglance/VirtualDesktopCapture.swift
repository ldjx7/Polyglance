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

    @MainActor
    static func compose(_ segments: [Segment]) -> VirtualDesktopCapture? {
        let frame = unionFrame(segments.map(\.frame))
        guard !frame.isNull, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let scale = max(1, segments.map(\.backingScaleFactor).max() ?? 1)
        let pixelWidth = max(1, Int(ceil(frame.width * scale)))
        let pixelHeight = max(1, Int(ceil(frame.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.black.setFill()
        CGRect(origin: .zero, size: frame.size).fill()
        for segment in segments {
            let destination = segment.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
            NSImage(cgImage: segment.image, size: segment.frame.size).draw(
                in: destination,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let image = bitmap.cgImage else {
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
