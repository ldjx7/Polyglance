import Foundation

public struct TranslationSegmentPair: Equatable, Identifiable, Sendable {
    public let id: Int
    public let sourceText: String
    public let targetText: String
    public let sourceRange: NSRange
    public let targetRange: NSRange

    public init(
        id: Int,
        sourceText: String,
        targetText: String,
        sourceRange: NSRange,
        targetRange: NSRange
    ) {
        self.id = id
        self.sourceText = sourceText
        self.targetText = targetText
        self.sourceRange = sourceRange
        self.targetRange = targetRange
    }
}

public enum TranslationAlignment {
    public static func pairs(source: String, target: String) -> [TranslationSegmentPair] {
        let sourceSegments = segments(in: source)
        let targetSegments = segments(in: target)
        let count = max(sourceSegments.count, targetSegments.count)
        return (0..<count).map { index in
            let sourceSegment = sourceSegments[safe: index]
            let targetSegment = targetSegments[safe: index]
            return TranslationSegmentPair(
                id: index,
                sourceText: sourceSegment?.text ?? "",
                targetText: targetSegment?.text ?? "",
                sourceRange: sourceSegment?.range ?? NSRange(location: 0, length: 0),
                targetRange: targetSegment?.range ?? NSRange(location: 0, length: 0)
            )
        }
    }

    public static func pairID(
        at characterIndex: Int,
        inSource: Bool,
        pairs: [TranslationSegmentPair]
    ) -> Int? {
        pairs.first { pair in
            let range = inSource ? pair.sourceRange : pair.targetRange
            return range.length > 0 && NSLocationInRange(characterIndex, range)
        }?.id
    }

    private static func segments(in text: String) -> [(text: String, range: NSRange)] {
        let string = text as NSString
        guard string.length > 0 else { return [] }
        let punctuation = CharacterSet(charactersIn: ".!?。！？；;")
        let whitespace = CharacterSet.whitespacesAndNewlines
        var result: [(String, NSRange)] = []
        var start = 0
        var index = 0

        func appendSegment(endingAt end: Int) {
            guard end > start else { return }
            var lower = start
            var upper = end
            while lower < upper,
                  let scalar = UnicodeScalar(string.character(at: lower)),
                  whitespace.contains(scalar) {
                lower += 1
            }
            while upper > lower,
                  let scalar = UnicodeScalar(string.character(at: upper - 1)),
                  whitespace.contains(scalar) {
                upper -= 1
            }
            guard upper > lower else { return }
            let range = NSRange(location: lower, length: upper - lower)
            result.append((string.substring(with: range), range))
        }

        while index < string.length {
            let codeUnit = string.character(at: index)
            guard let scalar = UnicodeScalar(codeUnit) else {
                index += 1
                continue
            }
            if scalar == "\n" || scalar == "\r" {
                appendSegment(endingAt: index)
                index += 1
                start = index
                continue
            }
            if punctuation.contains(scalar) {
                var end = index + 1
                while end < string.length,
                      let next = UnicodeScalar(string.character(at: end)),
                      punctuation.contains(next) {
                    end += 1
                }
                appendSegment(endingAt: end)
                index = end
                start = end
                continue
            }
            index += 1
        }
        appendSegment(endingAt: string.length)
        return result
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
