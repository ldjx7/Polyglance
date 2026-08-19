import CoreGraphics
import Foundation
import TranslatorCore

struct ScreenTranslationParagraph: Equatable {
    let text: String
    let boundingBox: CGRect
    let lineCount: Int
}

/// Thin forwarding layer over `capture-core`.
enum ScreenTranslationLayout {
    static func paragraphs(from document: OCRDocument) -> [ScreenTranslationParagraph] {
        let lines = document.lines.map { line in
            LayoutTextLine(
                text: line.text,
                boundingBox: CaptureRect(
                    x: line.boundingBox.origin.x,
                    y: line.boundingBox.origin.y,
                    width: line.boundingBox.width,
                    height: line.boundingBox.height
                )
            )
        }
        return layoutParagraphs(lines: lines).map { paragraph in
            ScreenTranslationParagraph(
                text: paragraph.text,
                boundingBox: CGRect(
                    x: paragraph.boundingBox.x,
                    y: paragraph.boundingBox.y,
                    width: paragraph.boundingBox.width,
                    height: paragraph.boundingBox.height
                ),
                lineCount: Int(paragraph.lineCount)
            )
        }
    }
}

enum ScreenTranslationColorSampler {
    static func averageColor(
        of image: CGImage,
        inNormalizedRect normalizedRect: CGRect
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return nil
        }
        let box = normalizedRect.standardized
        let expanded = box.insetBy(dx: -box.height * 0.25, dy: -box.height * 0.25)
        let pixelRect = CGRect(
            x: expanded.minX * width,
            y: (1 - expanded.maxY) * height,
            width: expanded.width * width,
            height: expanded.height * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let alpha = CGFloat(pixel[3])
        guard alpha > 0 else {
            return nil
        }
        return (
            red: CGFloat(pixel[0]) / alpha,
            green: CGFloat(pixel[1]) / alpha,
            blue: CGFloat(pixel[2]) / alpha
        )
    }

    static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        0.299 * red + 0.587 * green + 0.114 * blue
    }

    static func dominantTextColor(
        of image: CGImage,
        inNormalizedRect normalizedRect: CGRect,
        background: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else {
            return nil
        }
        let box = normalizedRect.standardized
        let pixelRect = CGRect(
            x: box.minX * width,
            y: (1 - box.maxY) * height,
            width: box.width * width,
            height: box.height * height
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard pixelRect.width >= 2, pixelRect.height >= 2,
              let cropped = image.cropping(to: pixelRect),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let sampleWidth = Int(min(48, pixelRect.width))
        let sampleHeight = Int(min(48, pixelRect.height))
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: sampleWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var sumRed: CGFloat = 0
        var sumGreen: CGFloat = 0
        var sumBlue: CGFloat = 0
        var count = 0
        for pixelIndex in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[pixelIndex + 3])
            guard alpha > 0 else {
                continue
            }
            let red = CGFloat(pixels[pixelIndex]) / alpha
            let green = CGFloat(pixels[pixelIndex + 1]) / alpha
            let blue = CGFloat(pixels[pixelIndex + 2]) / alpha
            let deltaRed = red - background.red
            let deltaGreen = green - background.green
            let deltaBlue = blue - background.blue
            let distance = deltaRed * deltaRed
                + deltaGreen * deltaGreen
                + deltaBlue * deltaBlue
            if distance > 0.06 {
                sumRed += red
                sumGreen += green
                sumBlue += blue
                count += 1
            }
        }
        let totalSamples = sampleWidth * sampleHeight
        guard count >= max(4, totalSamples / 60) else {
            return nil
        }
        return (
            red: sumRed / CGFloat(count),
            green: sumGreen / CGFloat(count),
            blue: sumBlue / CGFloat(count)
        )
    }
}
