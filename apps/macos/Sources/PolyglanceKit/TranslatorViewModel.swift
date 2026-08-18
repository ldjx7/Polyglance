import Combine
import Foundation

@MainActor
public final class TranslatorViewModel: ObservableObject {
    @Published public var sourceText = ""
    @Published public private(set) var translatedText = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isTranslating = false
    @Published public var sourceLanguage: String?
    @Published public var targetLanguage = "zh-CN"

    public var alignedSegments: [TranslationSegmentPair] {
        TranslationAlignment.pairs(source: sourceText, target: translatedText)
    }

    private let client: any TranslationClient

    public init(client: any TranslationClient) {
        self.client = client
    }

    public func applyCapturedText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }
        sourceText = trimmedText
        errorMessage = nil
    }

    public func presentError(_ message: String) {
        errorMessage = message
    }

    private var undoHistory: [(source: String, target: String)] = []

    public func clear() {
        if !sourceText.isEmpty || !translatedText.isEmpty {
            undoHistory.append((source: sourceText, target: translatedText))
        }
        sourceText = ""
        translatedText = ""
        errorMessage = nil
    }

    public func undo() {
        guard let last = undoHistory.popLast() else {
            return
        }
        sourceText = last.source
        translatedText = last.target
        errorMessage = nil
    }

    public func translate() async {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            errorMessage = "请输入要翻译的文本"
            return
        }

        isTranslating = true
        translatedText = ""
        errorMessage = nil
        defer { isTranslating = false }

        do {
            let request = AppTranslationRequest(
                text: trimmedText,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            for try await update in client.translateStream(request) {
                translatedText = update.text
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
