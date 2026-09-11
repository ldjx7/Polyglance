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
    @Published public var defaultTargetLanguage = "zh-CN"
    @Published public var secondTargetLanguage = "en"
    @Published public var providerStates: [ProviderTranslationState] = []
    @Published public var enabledProviders: [String] = ["free-ai"]
    @Published public var primaryProvider: String = "free-ai"
    @Published public var providerOrder: [String] = [
        "free-ai",
        "microsoft",
        "google",
        "deepl",
        "baidu",
        "youdao",
        "volcano",
        "openai-compatible"
    ]
    @Published public var isOcrLoading: Bool = false

    public var alignedSegments: [TranslationSegmentPair] {
        TranslationAlignment.pairs(source: sourceText, target: translatedText)
    }

    private let client: any TranslationClient
    private var cancellables = Set<AnyCancellable>()
    private var undoHistory: [(source: String, target: String)] = []
    private var lastRequestedSourceText: String?
    private var lastRequestedTargetLanguage: String?
    private var lastRequestedSourceLanguage: String?
    private var activeGeneration: Int = 0
    public private(set) var debouncedTask: Task<Void, Never>?
    @Published public var customAIDisplayNames: [String: String] = [:]

    public func displayName(for provider: String) -> String {
        if let custom = customAIDisplayNames[provider] {
            return custom
        }
        return Self.displayName(for: provider)
    }

    public static func displayName(for provider: String) -> String {
        switch provider.lowercased() {
        case "freeai", "free-ai", "official-ai", "polyglance-ai": return "官方 AI"
        case "microsoft": return "Microsoft 翻译"
        case "google": return "Google 翻译"
        case "deepl": return "DeepL"
        case "baidu": return "百度翻译"
        case "youdao": return "有道翻译"
        case "volcano", "volcengine": return "火山翻译"
        case "openaicompatible", "openai-compatible": return "OpenAI 兼容"
        default: return provider
        }
    }

    public init(client: any TranslationClient) {
        self.client = client
        setupDebouncedTranslation()
    }

    public func startTranslation() {
        debouncedTask?.cancel()
        debouncedTask = Task { [weak self] in
            await self?.translate()
        }
    }

    private func setupDebouncedTranslation() {
        $sourceText
            .sink { [weak self] text in
                guard let self = self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.debouncedTask?.cancel()
                    self.debouncedTask = nil
                    self.activeGeneration += 1
                    self.isTranslating = false
                    self.translatedText = ""
                    self.providerStates.removeAll()
                    self.detectedLanguageDisplayName = nil
                    self.errorMessage = nil
                    self.lastRequestedSourceText = nil
                    self.lastRequestedTargetLanguage = nil
                    self.lastRequestedSourceLanguage = nil
                }
            }
            .store(in: &cancellables)

        $sourceText
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self = self else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                self.detectLanguage(for: trimmed)
                self.updateAutoTargetLanguage(for: trimmed)
                guard trimmed != self.lastRequestedSourceText
                    || self.targetLanguage != self.lastRequestedTargetLanguage
                    || self.sourceLanguage != self.lastRequestedSourceLanguage else { return }
                self.startTranslation()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest($sourceLanguage, $targetLanguage)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] source, target in
                guard let self = self else { return }
                let trimmed = self.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                guard target != self.lastRequestedTargetLanguage
                    || source != self.lastRequestedSourceLanguage
                    || trimmed != self.lastRequestedSourceText else { return }
                self.startTranslation()
            }
            .store(in: &cancellables)
    }

    public func updateAutoTargetLanguage(for text: String) {
        guard sourceLanguage == nil || sourceLanguage?.isEmpty == true else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let hasChinese = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let primaryIsChinese = defaultTargetLanguage.lowercased().starts(with: "zh")
        let newTarget: String
        if primaryIsChinese {
            newTarget = hasChinese ? (secondTargetLanguage.isEmpty ? "en" : secondTargetLanguage) : defaultTargetLanguage
        } else {
            newTarget = hasChinese ? defaultTargetLanguage : (secondTargetLanguage.isEmpty ? "zh-CN" : secondTargetLanguage)
        }

        if targetLanguage != newTarget {
            targetLanguage = newTarget
        }
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

        updateAutoTargetLanguage(for: text)
    }

    public func applyCapturedText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return
        }
        detectLanguage(for: trimmedText)
        updateAutoTargetLanguage(for: trimmedText)
        lastRequestedSourceText = trimmedText
        lastRequestedTargetLanguage = targetLanguage
        lastRequestedSourceLanguage = sourceLanguage
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
        debouncedTask?.cancel()
        debouncedTask = nil
        lastRequestedSourceText = nil
        lastRequestedTargetLanguage = nil
        lastRequestedSourceLanguage = nil
        activeGeneration += 1
        sourceText = ""
        translatedText = ""
        targetLanguage = defaultTargetLanguage
        providerStates.removeAll()
        detectedLanguageDisplayName = nil
        errorMessage = nil
        isOcrLoading = false
    }

    public func startOcrLoading() {
        debouncedTask?.cancel()
        debouncedTask = nil
        lastRequestedSourceText = nil
        lastRequestedTargetLanguage = nil
        lastRequestedSourceLanguage = nil
        activeGeneration += 1
        isOcrLoading = true
        sourceText = ""
        translatedText = ""
        providerStates.removeAll()
        errorMessage = nil
        detectedLanguageDisplayName = nil
    }

    public func finishOcrLoading() {
        isOcrLoading = false
    }

    public func undo() {
        guard let last = undoHistory.popLast() else {
            return
        }
        debouncedTask?.cancel()
        debouncedTask = nil
        let trimmed = last.source.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRequestedSourceText = trimmed.isEmpty ? nil : trimmed
        sourceText = last.source
        translatedText = last.target
        errorMessage = nil
    }

    @Published public var providerModes: [String: String] = [:]
    @Published public var explicitlyTriggeredProviders: Set<String> = []

    public func getProviderMode(for provider: String) -> ProviderDisplayMode {
        guard let raw = providerModes[provider] else { return .normal }
        return ProviderDisplayMode(rawValue: raw) ?? .normal
    }

    public func setProviderMode(provider: String, mode: ProviderDisplayMode) {
        providerModes[provider] = mode.rawValue
        explicitlyTriggeredProviders.remove(provider)

        switch mode {
        case .closed:
            enabledProviders.removeAll { $0 == provider }
            providerStates.removeAll { $0.provider == provider }
        case .pinToBar:
            if !enabledProviders.contains(provider) {
                enabledProviders.append(provider)
            }
            providerStates.removeAll { $0.provider == provider }
        case .alwaysFold:
            if !enabledProviders.contains(provider) {
                enabledProviders.append(provider)
            }
            if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
                providerStates[idx].displayMode = mode
                providerStates[idx].isCollapsed = true
            }
        case .normal:
            if !enabledProviders.contains(provider) {
                enabledProviders.append(provider)
            }
            if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
                providerStates[idx].displayMode = mode
                providerStates[idx].isCollapsed = false
                if providerStates[idx].text.isEmpty && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task {
                        await translateSingleProvider(provider)
                    }
                }
            }
        case .rememberFold:
            if !enabledProviders.contains(provider) {
                enabledProviders.append(provider)
            }
            if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
                providerStates[idx].displayMode = mode
            }
        }
    }

    public var pinnedBarProviders: [String] {
        let base = enabledProviders.isEmpty ? ["free-ai"] : enabledProviders
        return base.filter { getProviderMode(for: $0) == .pinToBar }
    }

    public func triggerPinnedProvider(_ provider: String) async {
        explicitlyTriggeredProviders.insert(provider)
        if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
            providerStates[idx].isCollapsed = false
            if providerStates[idx].text.isEmpty {
                await translateSingleProvider(provider)
            }
        } else {
            let newState = ProviderTranslationState(
                provider: provider,
                displayName: displayName(for: provider),
                text: "",
                isTranslating: true,
                errorMessage: nil,
                isCollapsed: false,
                displayMode: .pinToBar
            )
            providerStates.append(newState)
            await translateSingleProvider(provider)
        }
    }

    public func updateProviderState(provider: String, text: String, isTranslating: Bool, error: String?) {
        if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
            providerStates[idx].text = text
            providerStates[idx].isTranslating = isTranslating
            providerStates[idx].errorMessage = error
        }
    }

    public func toggleProviderCollapse(provider: String) {
        if let idx = providerStates.firstIndex(where: { $0.provider == provider }) {
            providerStates[idx].isCollapsed.toggle()
            if !providerStates[idx].isCollapsed && providerStates[idx].text.isEmpty && !providerStates[idx].isTranslating {
                Task {
                    await translateSingleProvider(provider)
                }
            }
        }
    }

    public func translateSingleProvider(_ prov: String) async {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let currentGen = activeGeneration
        updateProviderState(provider: prov, text: "", isTranslating: true, error: nil)
        if prov == primaryProvider {
            translatedText = ""
        }

        let request = AppTranslationRequest(
            text: trimmedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: prov
        )

        do {
            if prov == primaryProvider {
                for try await update in client.translateStream(request) {
                    guard currentGen == self.activeGeneration, !Task.isCancelled else { return }
                    self.translatedText = update.text
                    self.updateProviderState(provider: prov, text: update.text, isTranslating: !update.isFinal, error: nil)
                }
                guard currentGen == self.activeGeneration, !Task.isCancelled else { return }
                if let state = providerStates.first(where: { $0.provider == prov }), state.isTranslating {
                    updateProviderState(provider: prov, text: state.text, isTranslating: false, error: nil)
                }
            } else {
                let result = try await client.translate(request)
                guard currentGen == self.activeGeneration, !Task.isCancelled else { return }
                self.updateProviderState(provider: prov, text: result.text, isTranslating: false, error: nil)
            }
        } catch {
            guard currentGen == self.activeGeneration, !Task.isCancelled else { return }
            self.updateProviderState(provider: prov, text: "", isTranslating: false, error: error.localizedDescription)
        }
        guard currentGen == self.activeGeneration, !Task.isCancelled else { return }
        if let state = providerStates.first(where: { $0.provider == prov }), state.isTranslating {
            updateProviderState(provider: prov, text: state.text, isTranslating: false, error: nil)
        }
    }

    public func translateNewlyAddedProvider(_ prov: String) async {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let existing = providerStates.first(where: { $0.provider == prov }), !existing.text.isEmpty {
            return
        }

        let mode = getProviderMode(for: prov)
        if mode == .closed || mode == .pinToBar { return }

        if !providerStates.contains(where: { $0.provider == prov }) {
            providerStates.append(ProviderTranslationState(
                provider: prov,
                displayName: displayName(for: prov),
                text: "",
                isTranslating: true,
                errorMessage: nil,
                isCollapsed: mode == .alwaysFold,
                displayMode: mode
            ))
        }

        await translateSingleProvider(prov)
    }

    public func translate() async {
        let trimmedText = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            errorMessage = "请输入要翻译的文本"
            return
        }

        if sourceLanguage == nil || sourceLanguage?.isEmpty == true {
            updateAutoTargetLanguage(for: trimmedText)
        }

        lastRequestedSourceText = trimmedText
        lastRequestedTargetLanguage = targetLanguage
        lastRequestedSourceLanguage = sourceLanguage
        activeGeneration += 1
        let currentGen = activeGeneration

        isTranslating = true
        translatedText = ""
        errorMessage = nil
        defer {
            if currentGen == self.activeGeneration {
                self.isTranslating = false
            }
        }

        let baseProviders = enabledProviders.isEmpty ? ["free-ai"] : enabledProviders
        // Filter out closed providers and sort according to providerOrder
        let activeProviders = baseProviders.filter { getProviderMode(for: $0) != .closed }
            .sorted { a, b in
                let idxA = providerOrder.firstIndex(of: a) ?? Int.max
                let idxB = providerOrder.firstIndex(of: b) ?? Int.max
                if idxA != idxB { return idxA < idxB }
                return a < b
            }

        // Determine which providers should display cards
        var states: [ProviderTranslationState] = []
        for prov in activeProviders {
            let mode = getProviderMode(for: prov)
            if mode == .pinToBar && !explicitlyTriggeredProviders.contains(prov) {
                continue
            }

            let isInitiallyCollapsed: Bool
            let willTranslate: Bool
            switch mode {
            case .alwaysFold:
                isInitiallyCollapsed = true
                willTranslate = false
            case .rememberFold:
                let existingCollapsed = providerStates.first(where: { $0.provider == prov })?.isCollapsed ?? false
                isInitiallyCollapsed = existingCollapsed
                willTranslate = !isInitiallyCollapsed
            case .normal:
                isInitiallyCollapsed = false
                willTranslate = true
            default:
                isInitiallyCollapsed = false
                willTranslate = true
            }

            states.append(ProviderTranslationState(
                provider: prov,
                displayName: displayName(for: prov),
                text: "",
                isTranslating: willTranslate,
                errorMessage: nil,
                isCollapsed: isInitiallyCollapsed,
                displayMode: mode
            ))
        }

        providerStates = states

        let primary = activeProviders.first ?? "free-ai"
        primaryProvider = primary
        let sourceLang = sourceLanguage
        let targetLang = targetLanguage

        // Translate cards that are marked for translation
        let toTranslate = states.filter { $0.isTranslating }.map(\.provider)

        await withTaskGroup(of: Void.self) { group in
            for prov in toTranslate {
                group.addTask { [weak self, client] in
                    let request = AppTranslationRequest(
                        text: trimmedText,
                        sourceLanguage: sourceLang,
                        targetLanguage: targetLang,
                        provider: prov
                    )
                    if prov == primary {
                        do {
                            for try await update in client.translateStream(request) {
                                await MainActor.run {
                                    guard let self = self, currentGen == self.activeGeneration, !Task.isCancelled else { return }
                                    self.translatedText = update.text
                                    self.updateProviderState(provider: prov, text: update.text, isTranslating: !update.isFinal, error: nil)
                                }
                            }
                            await MainActor.run {
                                guard let self = self, currentGen == self.activeGeneration, !Task.isCancelled else { return }
                                if let state = self.providerStates.first(where: { $0.provider == prov }), state.isTranslating {
                                    self.updateProviderState(provider: prov, text: state.text, isTranslating: false, error: nil)
                                }
                            }
                        } catch {
                            await MainActor.run {
                                guard let self = self, currentGen == self.activeGeneration, !Task.isCancelled else { return }
                                self.errorMessage = error.localizedDescription
                                self.updateProviderState(provider: prov, text: "", isTranslating: false, error: error.localizedDescription)
                            }
                        }
                    } else {
                        do {
                            let result = try await client.translate(request)
                            await MainActor.run {
                                guard let self = self, currentGen == self.activeGeneration, !Task.isCancelled else { return }
                                self.updateProviderState(provider: prov, text: result.text, isTranslating: false, error: nil)
                            }
                        } catch {
                            await MainActor.run {
                                guard let self = self, currentGen == self.activeGeneration, !Task.isCancelled else { return }
                                self.updateProviderState(provider: prov, text: "", isTranslating: false, error: error.localizedDescription)
                            }
                        }
                    }
                }
            }
        }

        for idx in providerStates.indices {
            providerStates[idx].isTranslating = false
        }
    }
}
