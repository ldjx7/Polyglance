import CoreGraphics
import Foundation
import ImageIO
import Vision

struct VisionOCRBackend: OCRRecognitionBackend {
    static let preferredRecognitionLanguages = [
        "zh-Hans",
        "zh-Hant",
        "en-US",
        "ja-JP",
        "ko-KR",
    ]

    func recognizeText(in image: CGImage) async throws -> [OCRTextObservation] {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let request = try Self.configuredRequest()
                let handler = VNImageRequestHandler(
                    cgImage: image,
                    orientation: .up,
                    options: [:]
                )
                try handler.perform([request])

                let imgW = image.width
                let imgH = image.height
                return request.results?.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    if Self.isIconOrNoise(
                        text: candidate.string,
                        box: observation.boundingBox,
                        confidence: candidate.confidence,
                        imageWidth: imgW,
                        imageHeight: imgH
                    ) {
                        return nil
                    }
                    let cleaned = Self.cleanIconArtifacts(candidate.string)
                    return OCRTextObservation(
                        text: cleaned,
                        boundingBox: observation.boundingBox,
                        fragments: Self.selectableFragments(for: candidate, cleanedText: cleaned)
                    )
                } ?? []
            }.value
        } catch let error as OCRError {
            throw error
        } catch {
            throw OCRError.visionFailed(error.localizedDescription)
        }
    }

    static func configuredRequest() throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let supportedLanguages = Set(try request.supportedRecognitionLanguages())
        request.recognitionLanguages = preferredRecognitionLanguages.filter(
            supportedLanguages.contains
        )
        return request
    }

    /// Vision exposes geometry for arbitrary recognized string ranges. Building
    /// character-level items gives the overlay native-feeling partial selection
    /// for both whitespace-delimited languages and CJK text. If Vision cannot
    /// provide every non-whitespace range, the caller deliberately falls back to
    /// the observation's line box rather than returning incomplete selectable
    /// text.
    private static func selectableFragments(
        for candidate: VNRecognizedText,
        cleanedText: String
    ) -> [OCRTextFragment] {
        let string = candidate.string
        var fragments: [OCRTextFragment] = []
        var separatorBefore = ""
        var currentIndex = string.startIndex

        while currentIndex < string.endIndex {
            let nextIndex = string.index(after: currentIndex)
            let range = currentIndex..<nextIndex
            let text = String(string[range])
            if text.allSatisfy(\.isWhitespace) {
                separatorBefore.append(text)
                currentIndex = nextIndex
                continue
            }

            guard let rectangle = try? candidate.boundingBox(for: range) else {
                return []
            }
            fragments.append(
                OCRTextFragment(
                    text: text,
                    boundingBox: rectangle.boundingBox,
                    separatorBefore: separatorBefore
                )
            )
            separatorBefore = ""
            currentIndex = nextIndex
        }

        if cleanedText != string {
            let cleanedChars = Array(cleanedText.filter { !$0.isWhitespace })
            var fragIdx = 0
            var matchedFragments: [OCRTextFragment] = []
            for frag in fragments {
                if fragIdx < cleanedChars.count && frag.text == String(cleanedChars[fragIdx]) {
                    matchedFragments.append(frag)
                    fragIdx += 1
                }
            }
            if matchedFragments.count == cleanedChars.count {
                return matchedFragments
            }
        }

        return fragments
    }

    static func cleanIconArtifacts(_ text: String) -> String {
        var result = text
        let pattern1 = #"([:：•·\-\*]\s*)([A-Za-z@~^#])\s+([A-Z][a-zA-Z0-9_\.]+|\w+\.(?:swift|cs|rs|py|js|ts|cpp|c|h|java|kt|go|html|css|json|xml|md)\b)"#
        if let regex = try? NSRegularExpression(pattern: pattern1) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$3")
        }
        let pattern2 = #"^(\s*)([A-Za-z@~^#])\s+([A-Z][a-zA-Z0-9_\.]+|\w+\.(?:swift|cs|rs|py|js|ts|cpp|c|h|java|kt|go|html|css|json|xml|md)\b)"#
        if let regex = try? NSRegularExpression(pattern: pattern2) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1$3")
        }
        return result
    }

    private static func isIconOrNoise(
        text: String,
        box: CGRect,
        confidence: Float,
        imageWidth: Int,
        imageHeight: Int
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        if trimmed.contains(where: { ("\u{4E00}"..."\u{9FFF}").contains($0) }) {
            return false
        }

        if trimmed.count >= 3 && trimmed.contains(where: { $0.isLetter || $0.isNumber }) {
            return false
        }

        let pixelWidth = box.width * CGFloat(imageWidth)
        let pixelHeight = box.height * CGFloat(imageHeight)
        let aspect = pixelWidth / max(1.0, pixelHeight)
        let isRoughlySquare = aspect >= 0.55 && aspect <= 1.55
        let isSmallBox = pixelWidth <= 48 && pixelHeight <= 48

        if confidence < 0.20 { return true }

        if trimmed.count <= 2 {
            if isRoughlySquare && isSmallBox {
                if trimmed.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                    return true
                }
                if trimmed.count == 1, let first = trimmed.first, first.isASCII, first.isLetter {
                    return true
                }
            }
        }
        return false
    }
}
