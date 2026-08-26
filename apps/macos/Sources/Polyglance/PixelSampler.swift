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
        guard coordinate.x >= 0,
              coordinate.y >= 0,
              coordinate.x < image.width,
              coordinate.y < image.height else {
            return nil
        }

        // Always return the complete odd-sized sampling grid. Cropping the patch
        // at a screen edge and then stretching it back to the preview used to
        // move the sampled pixel away from the fixed centre crosshair.
        let side = radius * 2 + 1
        var pixels = Data(repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for patchY in 0..<side {
                for patchX in 0..<side {
                    let sourceX = coordinate.x - radius + patchX
                    let sourceY = coordinate.y - radius + patchY
                    let offset = (patchY * side + patchX) * 4
                    bytes[offset + 3] = 255
                    guard sourceX >= 0,
                          sourceY >= 0,
                          sourceX < image.width,
                          sourceY < image.height,
                          let color = bitmap.colorAt(x: sourceX, y: sourceY)?
                            .usingColorSpace(.deviceRGB) else {
                        continue
                    }
                    bytes[offset] = Self.byte(from: color.redComponent)
                    bytes[offset + 1] = Self.byte(from: color.greenComponent)
                    bytes[offset + 2] = Self.byte(from: color.blueComponent)
                }
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else {
            return nil
        }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func byte(from component: CGFloat) -> UInt8 {
        UInt8(clamping: Int((min(max(component, 0), 1) * 255).rounded()))
    }
}
