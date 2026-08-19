import Foundation
import TranslatorCore

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

/// Thin forwarding layer over `capture-core`.
///
/// The Rust side indexes text by UTF-16 code unit, so the offsets map onto
/// `NSRange` without conversion.
public enum TranslationAlignment {
    public static func pairs(source: String, target: String) -> [TranslationSegmentPair] {
        translationAlignmentPairs(source: source, target: target).map { pair in
            TranslationSegmentPair(
                id: Int(pair.id),
                sourceText: pair.sourceText,
                targetText: pair.targetText,
                sourceRange: NSRange(
                    location: Int(pair.sourceLocation),
                    length: Int(pair.sourceLength)
                ),
                targetRange: NSRange(
                    location: Int(pair.targetLocation),
                    length: Int(pair.targetLength)
                )
            )
        }
    }

    public static func pairID(
        at characterIndex: Int,
        inSource: Bool,
        pairs: [TranslationSegmentPair]
    ) -> Int? {
        guard characterIndex >= 0 else {
            return nil
        }
        return translationAlignmentPairId(
            characterIndex: UInt32(characterIndex),
            inSource: inSource,
            pairs: pairs.map(\.captureValue)
        ).map(Int.init)
    }
}

private extension TranslationSegmentPair {
    var captureValue: TranslatorCore.TranslationSegmentPair {
        TranslatorCore.TranslationSegmentPair(
            id: UInt32(id),
            sourceText: sourceText,
            targetText: targetText,
            sourceLocation: UInt32(sourceRange.location),
            sourceLength: UInt32(sourceRange.length),
            targetLocation: UInt32(targetRange.location),
            targetLength: UInt32(targetRange.length)
        )
    }
}
