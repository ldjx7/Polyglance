import AppKit
import CoreGraphics

/// A selectable subrange of one Vision text observation.
///
/// Bounding boxes use Vision's normalized, lower-left coordinate space. Keeping
/// that representation here avoids losing precision when the same OCR result is
/// rendered in a screenshot window and later in a Retina pin window.
struct OCRTextFragment: Equatable, @unchecked Sendable {
    let text: String
    let boundingBox: CGRect
    let separatorBefore: String

    init(
        text: String,
        boundingBox: CGRect,
        separatorBefore: String = ""
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.separatorBefore = separatorBefore
    }
}

struct OCRTextObservation: Equatable, @unchecked Sendable {
    let text: String
    let boundingBox: CGRect
    let fragments: [OCRTextFragment]

    init(
        text: String,
        boundingBox: CGRect,
        fragments: [OCRTextFragment] = []
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.fragments = fragments
    }
}

/// A stable hit-test unit in an OCR document.
struct OCRTextItem: Identifiable, Equatable, @unchecked Sendable {
    let id: Int
    let lineIndex: Int
    let indexInLine: Int
    let text: String
    let boundingBox: CGRect
    let separatorBefore: String

    init(
        id: Int,
        lineIndex: Int,
        indexInLine: Int,
        text: String,
        boundingBox: CGRect,
        separatorBefore: String = ""
    ) {
        self.id = id
        self.lineIndex = lineIndex
        self.indexInLine = indexInLine
        self.text = text
        self.boundingBox = boundingBox
        self.separatorBefore = separatorBefore
    }
}

struct OCRTextLine: Equatable, @unchecked Sendable {
    let index: Int
    let text: String
    let boundingBox: CGRect
    let items: [OCRTextItem]
}

struct OCRDocument: Equatable, @unchecked Sendable {
    let lines: [OCRTextLine]

    var plainText: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var items: [OCRTextItem] {
        lines.flatMap(\.items)
    }

    /// Returns selected OCR content in reading order. An empty selection means
    /// "copy all", matching the screenshot OCR interaction.
    func text(forItemIDs selectedItemIDs: Set<Int>) -> String {
        guard !selectedItemIDs.isEmpty else {
            return plainText
        }

        let selectedItems = items
            .filter { selectedItemIDs.contains($0.id) }
            .sorted(by: Self.isInReadingOrder)
        guard let firstItem = selectedItems.first else {
            return plainText
        }

        var result = firstItem.text
        var previousItem = firstItem
        for item in selectedItems.dropFirst() {
            if item.lineIndex != previousItem.lineIndex {
                result.append("\n")
            } else if item.indexInLine == previousItem.indexInLine + 1 {
                result.append(item.separatorBefore)
            } else if !item.separatorBefore.isEmpty {
                result.append(item.separatorBefore)
            }
            result.append(item.text)
            previousItem = item
        }
        return result
    }

    private static func isInReadingOrder(_ left: OCRTextItem, _ right: OCRTextItem) -> Bool {
        if left.lineIndex != right.lineIndex {
            return left.lineIndex < right.lineIndex
        }
        if left.indexInLine != right.indexInLine {
            return left.indexInLine < right.indexInLine
        }
        return left.id < right.id
    }
}

protocol OCRRecognitionBackend: Sendable {
    func recognizeText(in image: CGImage) async throws -> [OCRTextObservation]
}

enum OCRError: LocalizedError, Equatable, Sendable {
    case invalidImage
    case noText
    case visionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法从图像中读取有效像素"
        case .noText:
            return "未识别到文字"
        case let .visionFailed(message):
            return "文字识别失败：\(message)"
        }
    }
}

struct OCRService: Sendable {
    private let backend: any OCRRecognitionBackend

    init(backend: any OCRRecognitionBackend = VisionOCRBackend()) {
        self.backend = backend
    }

    func recognizeText(in image: NSImage) async throws -> String {
        try await recognizeDocument(in: image).plainText
    }

    func recognizeDocument(in image: NSImage) async throws -> OCRDocument {
        guard image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            throw OCRError.invalidImage
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), cgImage.width > 0, cgImage.height > 0 else {
            throw OCRError.invalidImage
        }
        return try await recognizeDocument(in: cgImage)
    }

    func recognizeText(in image: CGImage) async throws -> String {
        try await recognizeDocument(in: image).plainText
    }

    func recognizeDocument(in image: CGImage) async throws -> OCRDocument {
        let observations: [OCRTextObservation]
        do {
            observations = try await backend.recognizeText(in: image)
        } catch let error as OCRError {
            throw error
        } catch {
            throw OCRError.visionFailed(error.localizedDescription)
        }

        let document = Self.document(from: observations)
        guard !document.plainText.isEmpty else {
            throw OCRError.noText
        }
        return document
    }

    private static func document(from observations: [OCRTextObservation]) -> OCRDocument {
        let preparedObservations: [PreparedObservation] = observations.enumerated().compactMap {
            index, observation -> PreparedObservation? in
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return PreparedObservation(
                text: text,
                boundingBox: observation.boundingBox.standardized,
                fragments: observation.fragments,
                originalIndex: index
            )
        }

        var nextItemID = 0
        let lines = observationsInReadingOrder(preparedObservations).enumerated().map {
            lineIndex, observation -> OCRTextLine in
            let validFragments = observation.fragments.filter {
                !$0.text.isEmpty && Self.isUsableNormalizedBox($0.boundingBox)
            }
            let sourceFragments = validFragments.isEmpty
                ? [
                    OCRTextFragment(
                        text: observation.text,
                        boundingBox: observation.boundingBox
                    ),
                ]
                : validFragments
            let items = sourceFragments.enumerated().map { indexInLine, fragment in
                defer { nextItemID += 1 }
                return OCRTextItem(
                    id: nextItemID,
                    lineIndex: lineIndex,
                    indexInLine: indexInLine,
                    text: fragment.text,
                    boundingBox: fragment.boundingBox.standardized,
                    separatorBefore: fragment.separatorBefore
                )
            }
            return OCRTextLine(
                index: lineIndex,
                text: observation.text,
                boundingBox: observation.boundingBox,
                items: items
            )
        }
        return OCRDocument(lines: lines)
    }

    private static func isUsableNormalizedBox(_ box: CGRect) -> Bool {
        let box = box.standardized
        return box.origin.x.isFinite
            && box.origin.y.isFinite
            && box.width.isFinite
            && box.height.isFinite
            && box.width > 0
            && box.height > 0
    }

    private static func observationsInReadingOrder(
        _ observations: [PreparedObservation]
    ) -> [PreparedObservation] {
        let topToBottom = observations.sorted { left, right in
            if left.boundingBox.midY != right.boundingBox.midY {
                return left.boundingBox.midY > right.boundingBox.midY
            }
            if left.boundingBox.minX != right.boundingBox.minX {
                return left.boundingBox.minX < right.boundingBox.minX
            }
            return left.originalIndex < right.originalIndex
        }

        var lines: [TextLine] = []
        for observation in topToBottom {
            if let lineIndex = lines.firstIndex(where: { $0.containsSameLine(as: observation) }) {
                lines[lineIndex].append(observation)
            } else {
                lines.append(TextLine(observation: observation))
            }
        }

        return lines
            .sorted { left, right in
                if left.midY != right.midY {
                    return left.midY > right.midY
                }
                return left.minX < right.minX
            }
            .flatMap { line in
                line.observations.sorted { left, right in
                    if left.boundingBox.minX != right.boundingBox.minX {
                        return left.boundingBox.minX < right.boundingBox.minX
                    }
                    return left.originalIndex < right.originalIndex
                }
            }
    }
}

private struct PreparedObservation {
    let text: String
    let boundingBox: CGRect
    let fragments: [OCRTextFragment]
    let originalIndex: Int
}

private struct TextLine {
    private(set) var observations: [PreparedObservation]
    private var minY: CGFloat
    private var maxY: CGFloat

    init(observation: PreparedObservation) {
        observations = [observation]
        minY = observation.boundingBox.minY
        maxY = observation.boundingBox.maxY
    }

    var midY: CGFloat {
        (minY + maxY) / 2
    }

    var minX: CGFloat {
        observations.map(\.boundingBox.minX).min() ?? 0
    }

    func containsSameLine(as observation: PreparedObservation) -> Bool {
        let observationHeight = observation.boundingBox.height
        let lineHeight = maxY - minY
        let overlap = min(maxY, observation.boundingBox.maxY)
            - max(minY, observation.boundingBox.minY)
        let shortestHeight = min(lineHeight, observationHeight)

        if shortestHeight > 0, overlap >= shortestHeight * 0.5 {
            return true
        }
        return abs(midY - observation.boundingBox.midY)
            <= max(lineHeight, observationHeight) * 0.35
    }

    mutating func append(_ observation: PreparedObservation) {
        observations.append(observation)
        minY = min(minY, observation.boundingBox.minY)
        maxY = max(maxY, observation.boundingBox.maxY)
    }
}
