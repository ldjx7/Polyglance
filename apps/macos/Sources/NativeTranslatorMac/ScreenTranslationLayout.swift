import CoreGraphics
import Foundation

struct ScreenTranslationParagraph: Equatable {
    let text: String
    let boundingBox: CGRect
    let lineCount: Int
}

enum ScreenTranslationLayout {
    static func paragraphs(from document: OCRDocument) -> [ScreenTranslationParagraph] {
        var groups: [[OCRTextLine]] = []
        for line in document.lines where !line.text.isEmpty {
            if var currentGroup = groups.last,
               let previousLine = currentGroup.last,
               belongsToSameParagraph(previousLine, line) {
                currentGroup.append(line)
                groups[groups.count - 1] = currentGroup
            } else {
                groups.append([line])
            }
        }
        return groups.map { lines in
            ScreenTranslationParagraph(
                text: joinedText(of: lines),
                boundingBox: unionBox(of: lines),
                lineCount: lines.count
            )
        }
    }

    private static func belongsToSameParagraph(
        _ above: OCRTextLine,
        _ below: OCRTextLine
    ) -> Bool {
        let aboveBox = above.boundingBox.standardized
        let belowBox = below.boundingBox.standardized
        let referenceHeight = min(aboveBox.height, belowBox.height)
        guard referenceHeight > 0 else {
            return false
        }
        let verticalGap = aboveBox.minY - belowBox.maxY
        guard verticalGap <= referenceHeight * 0.85, verticalGap >= -referenceHeight * 0.4 else {
            return false
        }
        let horizontalOverlap = min(aboveBox.maxX, belowBox.maxX)
            - max(aboveBox.minX, belowBox.minX)
        guard horizontalOverlap >= -referenceHeight * 1.5 else {
            return false
        }
        let heightRatio = max(aboveBox.height, belowBox.height)
            / max(referenceHeight, .leastNonzeroMagnitude)
        return heightRatio <= 1.9
    }

    private static func joinedText(of lines: [OCRTextLine]) -> String {
        var result = ""
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            if result.isEmpty {
                result = text
            } else if let previous = result.last, let next = text.first,
                      isCJK(previous) || isCJK(next) {
                result += text
            } else {
                result += " " + text
            }
        }
        return result
    }

    private static func unionBox(of lines: [OCRTextLine]) -> CGRect {
        lines.dropFirst().reduce(lines[0].boundingBox.standardized) { box, line in
            box.union(line.boundingBox.standardized)
        }
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x2E80...0x303F,
             0x3040...0x30FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0xFF00...0xFF60:
            return true
        default:
            return false
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
}
