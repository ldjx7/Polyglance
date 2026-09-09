import Foundation
import TranslatorCore

public enum TextFormattingMode: Int, CaseIterable, Sendable, Codable {
    case smartMerge = 0
    case preserveBreaks = 1
    case removeSpaces = 2
    case raw = 3

    public var title: String {
        switch self {
        case .smartMerge:
            return "智能合并折行"
        case .preserveBreaks:
            return "保持原样换行"
        case .removeSpaces:
            return "清除多余空格"
        case .raw:
            return "原始文本"
        }
    }
}

/// Thin wrapper over `capture_core::formatting`, so macOS and Windows reflow OCR
/// text identically. Every method forwards to the shared Rust core.
public enum TextFormattingService {
    public static func format(_ text: String, mode: TextFormattingMode) -> String {
        textFormat(text: text, mode: UInt8(mode.rawValue))
    }

    public static func format(lines: [(text: String, boundingBox: CGRect)], mode: TextFormattingMode) -> String {
        guard !lines.isEmpty else { return "" }
        let uniffiLines = lines.map { item in
            LayoutTextLine(
                text: item.text,
                boundingBox: CaptureRect(
                    x: Double(item.boundingBox.origin.x),
                    y: Double(item.boundingBox.origin.y),
                    width: Double(item.boundingBox.size.width),
                    height: Double(item.boundingBox.size.height)
                )
            )
        }
        return layoutFormatText(lines: uniffiLines, mode: UInt8(mode.rawValue))
    }

    public static func smartMergeLines(_ text: String) -> String {
        textSmartMergeLines(text: text)
    }

    public static func applyPanguSpacing(_ text: String) -> String {
        textApplyPanguSpacing(text: text)
    }

    public static func removeExtraneousSpaces(_ text: String) -> String {
        textRemoveExtraneousSpaces(text: text)
    }

    /// Swift compares `Character` values, so the first scalar of the grapheme
    /// cluster decides CJK-ness, matching what the callers already assumed.
    public static func isCjk(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return textIsCjkScalar(scalar: scalar.value)
    }
}
