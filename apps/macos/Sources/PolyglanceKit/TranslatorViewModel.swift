import Combine
import Foundation

@MainActor
public final class TranslatorViewModel: ObservableObject {
    @Published public var sourceText = ""
    @Published public private(set) var translatedText = ""
    @Published public private(set) var detectedLanguageDisplayName: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isTranslating = false
    @Published public var sourceLanguage: String?
    @Published public var targetLanguage = "zh-CN"

    public var alignedSegments: [TranslationSegmentPair] {
        TranslationAlignment.pairs(source: sourceText, target: translatedText)
    }

    private let client: any TranslationClient
    private var cancellables = Set<AnyCancellable>()
    private var undoHistory: [(source: String, target: String)] = []

    public init(client: any TranslationClient) {
        self.client = client
        setupDebouncedTranslation()
    }

    private func setupDebouncedTranslation() {
        $sourceText
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] text in
                guard let self = self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.translatedText = ""
                    self.detectedLanguageDisplayName = nil
                    self.errorMessage = nil
                } else {
                    self.detectLanguage(for: trimmed)
                    Task {
                        await self.translate()
                    }
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($sourceLanguage, $targetLanguage)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if !self.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await self.translate()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func detectLanguage(for text: String) {
        if sourceLanguage != nil && !sourceLanguage!.isEmpty {
            detectedLanguageDisplayName = nil
            return
        }

        // 简易语言检测 heuristic
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasJapanese = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hasKorean = text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) }

        if hasJapanese {
            detectedLanguageDisplayName = "日语"
        } else if hasKorean {
            detectedLanguageDisplayName = "韩语"
        } else if hasChinese {
            detectedLanguageDisplayName = "中文"
        } else {
            detectedLanguageDisplayName = "英语"
        }
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

    public func clear() {
        if !sourceText.isEmpty || !translatedText.isEmpty {
            undoHistory.append((source: sourceText, target: translatedText))
        }
        sourceText = ""
        translatedText = ""
        detectedLanguageDisplayName = nil
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
