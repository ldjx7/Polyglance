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

                return request.results?.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else {
                        return nil
                    }
                    return OCRTextObservation(
                        text: candidate.string,
                        boundingBox: observation.boundingBox,
                        fragments: Self.selectableFragments(for: candidate)
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
    private static func selectableFragments(for candidate: VNRecognizedText) -> [OCRTextFragment] {
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
        return fragments
    }
}
