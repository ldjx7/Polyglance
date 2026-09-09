import AppKit
import CoreGraphics
import PolyglanceKit

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
            guard !text.isEmpty, isUsableNormalizedBox(observation.boundingBox) else {
                return nil
            }
            return PreparedObservation(
                text: text,
                boundingBox: observation.boundingBox.standardized,
                fragments: observation.fragments,
                originalIndex: index
            )
        }

        guard !preparedObservations.isEmpty else {
            return OCRDocument(lines: [])
        }

        let lines = organizeLinesInReadingOrder(preparedObservations)
        return OCRDocument(lines: lines)
    }

    fileprivate static func isUsableNormalizedBox(_ box: CGRect) -> Bool {
        let box = box.standardized
        return box.origin.x.isFinite
            && box.origin.y.isFinite
            && box.width.isFinite
            && box.height.isFinite
            && box.width > 0
            && box.height > 0
    }

    private static func organizeLinesInReadingOrder(
        _ observations: [PreparedObservation]
    ) -> [OCRTextLine] {
        let medianHeight = calculateMedianHeight(observations)
        let blocks = partitionIntoBlocks(observations, medianHeight: medianHeight)

        var nextItemID = 0
        var resultLines: [OCRTextLine] = []

        for block in blocks {
            let blockLines = clusterLinesInBlock(
                block,
                medianHeight: medianHeight,
                startLineIndex: resultLines.count,
                nextItemID: &nextItemID
            )
            resultLines.append(contentsOf: blockLines)
        }

        return resultLines
    }

    private static func calculateMedianHeight(_ observations: [PreparedObservation]) -> CGFloat {
        let heights = observations.map(\.boundingBox.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 0.03 }
        return heights[heights.count / 2]
    }

    private static func partitionIntoBlocks(
        _ observations: [PreparedObservation],
        medianHeight: CGFloat
    ) -> [[PreparedObservation]] {
        guard observations.count >= 4 else {
            return [observations]
        }

        let minX = observations.map(\.boundingBox.minX).min() ?? 0
        let maxX = observations.map(\.boundingBox.maxX).max() ?? 1
        let totalWidth = maxX - minX

        guard totalWidth >= 0.25 else {
            return [observations]
        }

        let minGutterWidth = max(0.025, medianHeight * 1.2)
        let sortedByX = observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }

        var bestSplit: (
            left: [PreparedObservation],
            right: [PreparedObservation],
            headers: [PreparedObservation],
            footers: [PreparedObservation],
            gutterWidth: CGFloat
        )?

        for i in 0..<(sortedByX.count - 1) {
            let leftCandidateMaxX = sortedByX[0...i].map { $0.boundingBox.maxX }.max() ?? 0
            let rightCandidateMinX = sortedByX[(i + 1)...].map { $0.boundingBox.minX }.min() ?? 0
            let gutter = rightCandidateMinX - leftCandidateMaxX

            guard gutter >= minGutterWidth else { continue }

            let gStart = leftCandidateMaxX
            let gEnd = rightCandidateMinX

            let crossingItems = observations.filter {
                $0.boundingBox.minX < gEnd && $0.boundingBox.maxX > gStart
            }

            let nonCrossingLeft = observations.filter { $0.boundingBox.maxX <= gStart }
            let nonCrossingRight = observations.filter { $0.boundingBox.minX >= gEnd }

            guard nonCrossingLeft.count >= 2, nonCrossingRight.count >= 2 else { continue }

            let leftMinY: CGFloat = nonCrossingLeft.map { $0.boundingBox.minY }.min() ?? 0
            let leftMaxY: CGFloat = nonCrossingLeft.map { $0.boundingBox.maxY }.max() ?? 0
            let rightMinY: CGFloat = nonCrossingRight.map { $0.boundingBox.minY }.min() ?? 0
            let rightMaxY: CGFloat = nonCrossingRight.map { $0.boundingBox.maxY }.max() ?? 0

            let columnTopY: CGFloat = min(leftMaxY, rightMaxY)
            let columnBottomY: CGFloat = max(leftMinY, rightMinY)
            let verticalOverlap: CGFloat = columnTopY - columnBottomY

            guard columnTopY > columnBottomY, verticalOverlap >= max(0.04, medianHeight * 1.8) else {
                continue
            }

            let headers = crossingItems.filter { $0.boundingBox.minY >= columnTopY - medianHeight * 0.5 }
            let footers = crossingItems.filter { $0.boundingBox.maxY <= columnBottomY + medianHeight * 0.5 }

            if headers.count + footers.count != crossingItems.count {
                continue
            }

            let leftMinX: CGFloat = nonCrossingLeft.map { $0.boundingBox.minX }.min() ?? 0
            let leftMaxX: CGFloat = nonCrossingLeft.map { $0.boundingBox.maxX }.max() ?? 0
            let rightMinX: CGFloat = nonCrossingRight.map { $0.boundingBox.minX }.min() ?? 0
            let rightMaxX: CGFloat = nonCrossingRight.map { $0.boundingBox.maxX }.max() ?? 0

            let leftWidth = leftMaxX - leftMinX
            let rightWidth = rightMaxX - rightMinX

            guard leftWidth >= max(0.10, medianHeight * 2.0), rightWidth >= max(0.10, medianHeight * 2.0) else {
                continue
            }

            if bestSplit == nil || gutter > (bestSplit?.gutterWidth ?? 0) {
                bestSplit = (nonCrossingLeft, nonCrossingRight, headers, footers, gutter)
            }
        }

        if let split = bestSplit {
            var result: [[PreparedObservation]] = []
            if !split.headers.isEmpty {
                result.append(split.headers)
            }
            result.append(contentsOf: partitionIntoBlocks(split.left, medianHeight: medianHeight))
            result.append(contentsOf: partitionIntoBlocks(split.right, medianHeight: medianHeight))
            if !split.footers.isEmpty {
                result.append(split.footers)
            }
            return result
        }

        return [observations]
    }

    private static func clusterLinesInBlock(
        _ observations: [PreparedObservation],
        medianHeight: CGFloat,
        startLineIndex: Int,
        nextItemID: inout Int
    ) -> [OCRTextLine] {
        guard !observations.isEmpty else { return [] }

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
            if let lineIndex = lines.firstIndex(where: { $0.containsSameLine(as: observation, medianHeight: medianHeight) }) {
                lines[lineIndex].append(observation)
            } else {
                lines.append(TextLine(observation: observation))
            }
        }

        let sortedLines = lines.sorted { left, right in
            if left.midY != right.midY {
                return left.midY > right.midY
            }
            return left.minX < right.minX
        }

        var ocrLines: [OCRTextLine] = []
        for (offset, line) in sortedLines.enumerated() {
            let lineIndex = startLineIndex + offset
            ocrLines.append(
                line.toOCRTextLine(
                    lineIndex: lineIndex,
                    nextItemID: &nextItemID
                )
            )
        }

        return ocrLines
    }
}

private struct PreparedObservation {
    let text: String
    let boundingBox: CGRect
    let fragments: [OCRTextFragment]
    let originalIndex: Int
}

private struct TextLine {
    var observations: [PreparedObservation]
    var minY: CGFloat
    var maxY: CGFloat

    init(observation: PreparedObservation) {
        observations = [observation]
        minY = observation.boundingBox.minY
        maxY = observation.boundingBox.maxY
    }

    var midY: CGFloat {
        (minY + maxY) / 2.0
    }

    var minX: CGFloat {
        observations.map(\.boundingBox.minX).min() ?? 0
    }

    func containsSameLine(as observation: PreparedObservation, medianHeight: CGFloat) -> Bool {
        let observationHeight = observation.boundingBox.height
        let lineHeight = maxY - minY
        let overlap = min(maxY, observation.boundingBox.maxY)
            - max(minY, observation.boundingBox.minY)
        let shortestHeight = min(lineHeight, observationHeight)

        let verticalMatch: Bool
        if shortestHeight > 0, overlap >= shortestHeight * 0.45 {
            verticalMatch = true
        } else {
            verticalMatch = abs(midY - observation.boundingBox.midY)
                <= max(lineHeight, observationHeight) * 0.35
        }
        guard verticalMatch else { return false }

        let minClusterX = observations.map(\.boundingBox.minX).min() ?? 0
        let maxClusterX = observations.map(\.boundingBox.maxX).max() ?? 0
        let obsMinX = observation.boundingBox.minX
        let obsMaxX = observation.boundingBox.maxX
        let gap: CGFloat
        if obsMinX >= maxClusterX {
            gap = obsMinX - maxClusterX
        } else if obsMaxX <= minClusterX {
            gap = minClusterX - obsMaxX
        } else {
            gap = 0
        }

        let maxAllowedGap = max(medianHeight * 2.5, 0.05)
        return gap <= maxAllowedGap
    }

    mutating func append(_ observation: PreparedObservation) {
        observations.append(observation)
        minY = min(minY, observation.boundingBox.minY)
        maxY = max(maxY, observation.boundingBox.maxY)
    }

    func toOCRTextLine(
        lineIndex: Int,
        nextItemID: inout Int
    ) -> OCRTextLine {
        let sortedObs = observations.sorted { left, right in
            if left.boundingBox.minX != right.boundingBox.minX {
                return left.boundingBox.minX < right.boundingBox.minX
            }
            return left.originalIndex < right.originalIndex
        }

        var fullText = ""
        var fullBox = sortedObs[0].boundingBox
        var items: [OCRTextItem] = []
        var indexInLine = 0

        for (i, obs) in sortedObs.enumerated() {
            fullBox = fullBox.union(obs.boundingBox)

            let separator: String
            if i == 0 {
                separator = ""
            } else {
                let prevObs = sortedObs[i - 1]
                let gap = obs.boundingBox.minX - prevObs.boundingBox.maxX
                separator = Self.separatorBetween(
                    leftText: fullText,
                    rightText: obs.text,
                    gap: gap,
                    lineHeight: min(prevObs.boundingBox.height, obs.boundingBox.height)
                )
            }

            fullText.append(separator)
            fullText.append(obs.text)

            let validFragments = obs.fragments.filter {
                !$0.text.isEmpty && OCRService.isUsableNormalizedBox($0.boundingBox)
            }
            let fragments = validFragments.isEmpty
                ? [OCRTextFragment(text: obs.text, boundingBox: obs.boundingBox)]
                : validFragments

            for (fragIdx, fragment) in fragments.enumerated() {
                let sepBefore: String
                if fragIdx == 0 && i > 0 {
                    sepBefore = separator + fragment.separatorBefore
                } else {
                    sepBefore = fragment.separatorBefore
                }

                items.append(
                    OCRTextItem(
                        id: nextItemID,
                        lineIndex: lineIndex,
                        indexInLine: indexInLine,
                        text: fragment.text,
                        boundingBox: fragment.boundingBox.standardized,
                        separatorBefore: sepBefore
                    )
                )
                nextItemID += 1
                indexInLine += 1
            }
        }

        return OCRTextLine(
            index: lineIndex,
            text: fullText,
            boundingBox: fullBox,
            items: items
        )
    }

    private static func separatorBetween(
        leftText: String,
        rightText: String,
        gap: CGFloat,
        lineHeight: CGFloat
    ) -> String {
        guard let lastChar = leftText.last, let firstChar = rightText.first else {
            return ""
        }

        if lastChar.isWhitespace || firstChar.isWhitespace {
            return ""
        }

        let isLeftCjk = TextFormattingService.isCjk(lastChar)
        let isRightCjk = TextFormattingService.isCjk(firstChar)

        if isPunctuation(firstChar) {
            return ""
        }

        let relGap = lineHeight > 0 ? gap / lineHeight : gap

        if isLeftCjk && isRightCjk {
            if relGap >= 0.75 {
                return " "
            }
            return ""
        }

        if (isLeftCjk && !isRightCjk) || (!isLeftCjk && isRightCjk) {
            return " "
        }

        if relGap >= 0.15 || (lastChar.isLetter && firstChar.isLetter) || (lastChar.isNumber && firstChar.isLetter) {
            return " "
        }

        return ""
    }

    private static func isPunctuation(_ c: Character) -> Bool {
        [",", ".", "!", "?", ";", ":", ")", "]", "}", "、", "，", "。", "！", "？", "；", "：", "）", "】", "”", "’"].contains(c)
    }
}
