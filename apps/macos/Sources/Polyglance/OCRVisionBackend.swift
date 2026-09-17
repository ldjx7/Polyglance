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
                        fragments: Self.selectableFragments(
                            for: candidate,
                            observationBox: observation.boundingBox,
                            cleanedText: cleaned
                        )
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

    private static func selectableFragments(
        for candidate: VNRecognizedText,
        observationBox: CGRect,
        cleanedText: String
    ) -> [OCRTextFragment] {
        let string = candidate.string
        guard !cleanedText.isEmpty else { return [] }

        func charWeight(_ c: Character) -> CGFloat {
            if c.unicodeScalars.contains(where: {
                (0x4E00...0x9FFF).contains($0.value) ||
                (0x3400...0x4DBF).contains($0.value) ||
                (0x20000...0x2A6DF).contains($0.value) ||
                (0x3040...0x30FF).contains($0.value) ||
                (0xAC00...0xD7AF).contains($0.value)
            }) {
                return 1.0
            }
            if "mwWM@#%&".contains(c) {
                return 0.85
            }
            if "ijl|!.,:;'`I1t ".contains(c) {
                return 0.35
            }
            if c.isUppercase {
                return 0.7
            }
            return 0.55
        }

        func subdivide(wordText: String, wordBox: CGRect, separatorBefore: String) -> [OCRTextFragment] {
            guard !wordText.isEmpty else { return [] }
            let chars = Array(wordText)
            let weights = chars.map(charWeight)
            let totalWeight = weights.reduce(0, +)
            guard totalWeight > 0 else { return [] }

            var frags: [OCRTextFragment] = []
            var currentX = wordBox.minX
            for (idx, char) in chars.enumerated() {
                let w = wordBox.width * (weights[idx] / totalWeight)
                let charBox = CGRect(
                    x: currentX,
                    y: wordBox.minY,
                    width: max(0.001, w),
                    height: wordBox.height
                )
                frags.append(
                    OCRTextFragment(
                        text: String(char),
                        boundingBox: charBox,
                        separatorBefore: idx == 0 ? separatorBefore : ""
                    )
                )
                currentX += w
            }
            return frags
        }

        var tokens: [(text: String, separatorBefore: String)] = []
        var curWord = ""
        var curSep = ""
        for char in cleanedText {
            if char.isWhitespace {
                if !curWord.isEmpty {
                    tokens.append((curWord, curSep))
                    curWord = ""
                    curSep = ""
                }
                curSep.append(char)
            } else {
                curWord.append(char)
            }
        }
        if !curWord.isEmpty {
            tokens.append((curWord, curSep))
        }

        guard !tokens.isEmpty else { return [] }

        let tokenWeights = tokens.map { token in
            token.text.map(charWeight).reduce(0, +)
        }
        let totalTokenWeight = tokenWeights.reduce(0, +)

        var fragments: [OCRTextFragment] = []
        var runningWeight: CGFloat = 0

        var searchStartIndex = string.startIndex
        for (tIdx, token) in tokens.enumerated() {
            let tWeight = tokenWeights[tIdx]
            var tokenBox: CGRect? = nil
            let tokenRange: Range<String.Index>?
            if let range = string.range(of: token.text, range: searchStartIndex..<string.endIndex) {
                tokenRange = range
                searchStartIndex = range.upperBound
                if let rect = try? candidate.boundingBox(for: range),
                   OCRService.isUsableNormalizedBox(rect.boundingBox) {
                    tokenBox = rect.boundingBox
                }
            } else if let range = string.range(of: token.text) {
                tokenRange = range
                if let rect = try? candidate.boundingBox(for: range),
                   OCRService.isUsableNormalizedBox(rect.boundingBox) {
                    tokenBox = rect.boundingBox
                }
            } else {
                tokenRange = nil
            }

            let effectiveBox: CGRect
            if let tokenBox {
                effectiveBox = tokenBox
            } else if totalTokenWeight > 0 {
                let startFraction = runningWeight / totalTokenWeight
                let widthFraction = tWeight / totalTokenWeight
                effectiveBox = CGRect(
                    x: observationBox.minX + startFraction * observationBox.width,
                    y: observationBox.minY,
                    width: max(0.001, widthFraction * observationBox.width),
                    height: observationBox.height
                )
            } else {
                effectiveBox = observationBox
            }
            runningWeight += tWeight

            var charBoxes: [CGRect] = []
            var allCharsFound = false
            if let tokenRange {
                var currentIdx = tokenRange.lowerBound
                var tempBoxes: [CGRect] = []
                var failed = false
                while currentIdx < tokenRange.upperBound {
                    let nextIdx = string.index(after: currentIdx)
                    let charRange = currentIdx..<nextIdx
                    if let cRect = try? candidate.boundingBox(for: charRange),
                       OCRService.isUsableNormalizedBox(cRect.boundingBox) {
                        tempBoxes.append(cRect.boundingBox)
                    } else {
                        failed = true
                        break
                    }
                    currentIdx = nextIdx
                }
                if !failed && tempBoxes.count == token.text.count {
                    if tempBoxes.count <= 1 {
                        charBoxes = tempBoxes
                        allCharsFound = true
                    } else {
                        let maxAllowedWidth = effectiveBox.width * 0.90
                        let isActuallyPartitioned = zip(tempBoxes, tempBoxes.dropFirst()).allSatisfy { prev, next in
                            prev.width <= maxAllowedWidth && next.width <= maxAllowedWidth && prev.maxX <= next.minX + 0.001
                        }
                        if isActuallyPartitioned {
                            charBoxes = tempBoxes
                            allCharsFound = true
                        }
                    }
                }
            }

            if allCharsFound {
                for (cIdx, char) in token.text.enumerated() {
                    fragments.append(
                        OCRTextFragment(
                            text: String(char),
                            boundingBox: charBoxes[cIdx],
                            separatorBefore: cIdx == 0 ? token.separatorBefore : ""
                        )
                    )
                }
            } else {
                let subFrags = subdivide(
                    wordText: token.text,
                    wordBox: effectiveBox,
                    separatorBefore: token.separatorBefore
                )
                fragments.append(contentsOf: subFrags)
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
            }
        }
        return false
    }
}
