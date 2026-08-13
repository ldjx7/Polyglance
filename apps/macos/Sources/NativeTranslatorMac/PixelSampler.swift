import AppKit

struct PixelCoordinate: Equatable, Sendable {
    let x: Int
    let y: Int
}

enum ScreenshotColorDisplayFormat: Equatable, Sendable {
    case hex
    case rgb

    mutating func toggle() {
        self = self == .hex ? .rgb : .hex
    }
}

struct PixelSample: Equatable, Sendable {
    let coordinate: PixelCoordinate
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var rgb: String {
        "RGB(\(red), \(green), \(blue))"
    }

    func text(format: ScreenshotColorDisplayFormat) -> String {
        switch format {
        case .hex:
            return hex
        case .rgb:
            return rgb
        }
    }
}

/// Maps AppKit's bottom-left view coordinates onto top-left physical image pixels.
/// Keeping this conversion in one place prevents Retina rounding differences between
/// the magnifier, coordinate label, and copied color value.
final class PixelSampler {
    let image: CGImage
    private let bitmap: NSBitmapImageRep

    init?(image: CGImage) {
        guard image.width > 0, image.height > 0 else {
            return nil
        }
        self.image = image
        bitmap = NSBitmapImageRep(cgImage: image)
    }

    func sample(atViewPoint point: CGPoint, viewSize: CGSize) -> PixelSample? {
        guard viewSize.width > 0,
              viewSize.height > 0,
              point.x >= 0,
              point.y >= 0,
              point.x <= viewSize.width,
              point.y <= viewSize.height else {
            return nil
        }

        let physicalX = min(
            image.width - 1,
            max(0, Int(floor(point.x * CGFloat(image.width) / viewSize.width)))
        )
        let topDownY = min(
            image.height - 1,
            max(0, Int(floor(
                (viewSize.height - point.y) * CGFloat(image.height) / viewSize.height
            )))
        )
        guard let color = bitmap.colorAt(x: physicalX, y: topDownY)?
            .usingColorSpace(.deviceRGB) else {
            return nil
        }

        return PixelSample(
            coordinate: PixelCoordinate(x: physicalX, y: topDownY),
            red: Self.byte(from: color.redComponent),
            green: Self.byte(from: color.greenComponent),
            blue: Self.byte(from: color.blueComponent)
        )
    }

    func patch(around coordinate: PixelCoordinate, radius: Int) -> CGImage? {
        let radius = max(0, radius)
        let requested = CGRect(
            x: coordinate.x - radius,
            y: coordinate.y - radius,
            width: radius * 2 + 1,
            height: radius * 2 + 1
        )
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = requested.intersection(imageBounds).integral
        guard !clipped.isNull, !clipped.isEmpty else {
            return nil
        }
        return image.cropping(to: clipped)
    }

    private static func byte(from component: CGFloat) -> UInt8 {
        UInt8(clamping: Int((min(max(component, 0), 1) * 255).rounded()))
    }
}
