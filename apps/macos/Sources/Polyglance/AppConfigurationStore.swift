import Foundation
import Security
import PolyglanceKit

enum TranslationProvider: String, CaseIterable, Codable, Sendable {
    case freeAI = "free-ai"
    case microsoft
    case google
    case deepl
    case baidu
    case youdao
    case volcano
    case openAICompatible = "openai-compatible"

    var displayName: String {
        switch self {
        case .freeAI:
            return "官方 AI"
        case .microsoft:
            return "Microsoft 翻译"
        case .google:
            return "Google 翻译"
        case .deepl:
            return "DeepL"
        case .baidu:
            return "百度翻译"
        case .youdao:
            return "有道翻译"
        case .volcano:
            return "火山翻译"
        case .openAICompatible:
            return "OpenAI 兼容"
        }
    }

    var requiresUserAPIKey: Bool {
        switch self {
        case .freeAI, .microsoft, .google:
            return false
        case .deepl, .baidu, .youdao, .volcano, .openAICompatible:
            return true
        }
    }
}

struct ScreenshotToolbarItemConfig: Codable, Equatable, Hashable, Sendable {
    var id: String
    var isVisible: Bool

    init(id: String, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
    }

    static let defaultItems: [ScreenshotToolbarItemConfig] = [
        ScreenshotToolbarItemConfig(id: "pen"),
        ScreenshotToolbarItemConfig(id: "line"),
        ScreenshotToolbarItemConfig(id: "arrow"),
        ScreenshotToolbarItemConfig(id: "ellipse"),
        ScreenshotToolbarItemConfig(id: "rect"),
        ScreenshotToolbarItemConfig(id: "text"),
        ScreenshotToolbarItemConfig(id: "mosaic"),
        ScreenshotToolbarItemConfig(id: "number"),
        ScreenshotToolbarItemConfig(id: "undo"),
        ScreenshotToolbarItemConfig(id: "redo"),
        ScreenshotToolbarItemConfig(id: "longScreenshot"),
        ScreenshotToolbarItemConfig(id: "screenRecording"),
        ScreenshotToolbarItemConfig(id: "ocr"),
        ScreenshotToolbarItemConfig(id: "translate"),
        ScreenshotToolbarItemConfig(id: "barcode"),
        ScreenshotToolbarItemConfig(id: "save"),
        ScreenshotToolbarItemConfig(id: "cancel"),
        ScreenshotToolbarItemConfig(id: "pin"),
        ScreenshotToolbarItemConfig(id: "copy"),
    ]

    static func normalize(_ items: [ScreenshotToolbarItemConfig]?) -> [ScreenshotToolbarItemConfig] {
        guard let items else { return defaultItems }
        var result: [ScreenshotToolbarItemConfig] = []
        var seen = Set<String>()
        for item in items {
            if defaultItems.contains(where: { $0.id == item.id }) && !seen.contains(item.id) {
                result.append(item)
                seen.insert(item.id)
            }
        }
        for item in defaultItems {
            if !seen.contains(item.id) {
                result.append(item)
                seen.insert(item.id)
            }
        }
        return result
    }
}

struct AppConfiguration: Equatable, Sendable {
    static let defaultProviderOrder: [String] = [
        "free-ai",
        "microsoft",
        "google",
        "deepl",
        "baidu",
        "youdao",
        "volcano",
        "openai-compatible"
    ]

    var provider: TranslationProvider
    var endpoint: String
    var apiKey: String
    var model: String
    var targetLanguage: String
    var secondTargetLanguage: String
    var aiStreamingEnabled: Bool
    var includeBetaUpdates: Bool
    var autoCheckUpdates: Bool
    var screenshotToolbarItems: [ScreenshotToolbarItemConfig]
    var saveCompletedScreenshotsToHistory: Bool
    var ocrAutoCopyNextTime: Bool
    var ocrDefaultFormatting: Int
    var enabledProviders: [String]
    var deeplAuthKey: String
    var deeplEndpoint: String
    var baiduAppId: String
    var baiduSecretKey: String
    var youdaoAppKey: String
    var youdaoSecret: String
    var volcanoAccessKey: String
    var volcanoSecretKey: String
    var screenshotTranslationStyle: String
    var providerDisplayModes: [String: String]
    var providerOrder: [String]
    var customAIConfigs: [CustomAIServiceConfig]

    init(
        provider: TranslationProvider = .freeAI,
        endpoint: String = "https://api.openai.com/v1",
        apiKey: String = "",
        model: String = "gpt-4o-mini",
        targetLanguage: String = "zh-CN",
        secondTargetLanguage: String = "en",
        aiStreamingEnabled: Bool = true,
        includeBetaUpdates: Bool = false,
        autoCheckUpdates: Bool = true,
        screenshotToolbarItems: [ScreenshotToolbarItemConfig] = ScreenshotToolbarItemConfig.defaultItems,
        saveCompletedScreenshotsToHistory: Bool = false,
        ocrAutoCopyNextTime: Bool = false,
        ocrDefaultFormatting: Int = 0,
        enabledProviders: [String] = ["free-ai"],
        deeplAuthKey: String = "",
        deeplEndpoint: String = "",
        baiduAppId: String = "",
        baiduSecretKey: String = "",
        youdaoAppKey: String = "",
        youdaoSecret: String = "",
        volcanoAccessKey: String = "",
        volcanoSecretKey: String = "",
        screenshotTranslationStyle: String = "bob",
        providerDisplayModes: [String: String] = [:],
        providerOrder: [String] = AppConfiguration.defaultProviderOrder,
        customAIConfigs: [CustomAIServiceConfig] = []
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.targetLanguage = targetLanguage
        self.secondTargetLanguage = secondTargetLanguage
        self.aiStreamingEnabled = aiStreamingEnabled
        self.includeBetaUpdates = includeBetaUpdates
        self.autoCheckUpdates = autoCheckUpdates
        self.screenshotToolbarItems = ScreenshotToolbarItemConfig.normalize(screenshotToolbarItems)
        self.saveCompletedScreenshotsToHistory = saveCompletedScreenshotsToHistory
        self.ocrAutoCopyNextTime = ocrAutoCopyNextTime
        self.ocrDefaultFormatting = ocrDefaultFormatting
        self.enabledProviders = enabledProviders.isEmpty ? ["free-ai"] : enabledProviders
        self.deeplAuthKey = deeplAuthKey
        self.deeplEndpoint = deeplEndpoint
        self.baiduAppId = baiduAppId
        self.baiduSecretKey = baiduSecretKey
        self.youdaoAppKey = youdaoAppKey
        self.youdaoSecret = youdaoSecret
        self.volcanoAccessKey = volcanoAccessKey
        self.volcanoSecretKey = volcanoSecretKey
        self.screenshotTranslationStyle = screenshotTranslationStyle
        self.providerDisplayModes = providerDisplayModes
        self.providerOrder = providerOrder.isEmpty ? AppConfiguration.defaultProviderOrder : providerOrder
        if customAIConfigs.isEmpty {
            self.customAIConfigs = [
                CustomAIServiceConfig(
                    id: "openai-compatible",
                    name: "OpenAI 兼容",
                    endpoint: endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint,
                    apiKey: apiKey,
                    model: model.isEmpty ? "gpt-4o-mini" : model,
                    prompt: "",
                    isEnabled: enabledProviders.contains("openai-compatible")
                )
            ]
        } else {
            self.customAIConfigs = customAIConfigs
        }
    }
}

enum CredentialSlot: String, Hashable, Sendable {
    case customAI = "openai-compatible-api-key"
}

protocol CredentialStoring: Sendable {
    func load(_ slot: CredentialSlot) throws -> String?
    func save(_ value: String, for slot: CredentialSlot) throws
}

/// The bundled free AI service.
///
/// There is deliberately no API key and no model here. Both live in the
/// Cloudflare Worker behind `endpoint`: shipping either of them inside an
/// open-source binary hands every reader a billable credential and the ability
/// to name an expensive model. The client sends text and languages; the Worker
/// decides everything else.
struct BundledFreeAIConfiguration: Equatable, Sendable {
    static let defaultEndpoint = "https://polyglance.ldjx7.dpdns.org/api/free-translate"

    let endpoint: String

    init?(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let endpoint = ((infoDictionary["PolyglanceFreeAIEndpoint"] as? String)
            ?? environment["POLYGLANCE_FREE_AI_ENDPOINT"]
            ?? Self.defaultEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https" else {
            return nil
        }
        self.endpoint = endpoint
    }
}

final class AppConfigurationStore: @unchecked Sendable {
    private enum Key {
        static let provider = "translation.provider"
        static let endpoint = "provider.endpoint"
        static let model = "provider.model"
        static let targetLanguage = "translation.target-language"
        static let secondTargetLanguage = "translation.second-target-language"
        static let aiStreamingEnabled = "translation.ai-streaming-enabled"
        static let includeBetaUpdates = "updater.include-beta-updates"
        static let autoCheckUpdates = "updater.auto-check-updates"
        static let screenshotToolbarItems = "screenshot.toolbar-items"
        static let saveCompletedScreenshotsToHistory = "screenshot.save-completed-to-history"
        static let ocrAutoCopyNextTime = "ocr.auto-copy-next-time"
        static let ocrDefaultFormatting = "ocr.default-formatting"
        static let enabledProviders = "translation.enabled-providers"
        static let deeplAuthKey = "deepl.auth-key"
        static let deeplEndpoint = "deepl.endpoint"
        static let baiduAppId = "baidu.app-id"
        static let baiduSecretKey = "baidu.secret-key"
        static let youdaoAppKey = "youdao.app-key"
        static let youdaoSecret = "youdao.secret"
        static let volcanoAccessKey = "volcano.access-key"
        static let volcanoSecretKey = "volcano.secret-key"
        static let screenshotTranslationStyle = "translation.screenshot-translation-style"
        static let providerDisplayModes = "translation.provider-display-modes"
        static let providerOrder = "translation.provider-order"
        static let customAIConfigs = "translation.custom-ai-configs"
    }

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring

    init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentials = credentials
    }

    func load() throws -> AppConfiguration {
        let storedProviderName = defaults.string(forKey: Key.provider)
        let storedProvider = storedProviderName.flatMap(TranslationProvider.init(rawValue:))
        let isLegacyCustomAIConfiguration = storedProviderName == nil
            && defaults.object(forKey: Key.endpoint) != nil
        let shouldLoadCustomAICredential = storedProvider == .openAICompatible
            || isLegacyCustomAIConfiguration
        let apiKey = shouldLoadCustomAICredential
            ? try credentials.load(.customAI) ?? ""
            : ""
        let migratedProvider: TranslationProvider
        if storedProviderName == "my-memory" || storedProviderName == "system" {
            migratedProvider = .microsoft
        } else {
            migratedProvider = storedProvider ?? (apiKey.isEmpty ? .microsoft : .openAICompatible)
        }
        var toolbarItems = ScreenshotToolbarItemConfig.defaultItems
        if let data = defaults.data(forKey: Key.screenshotToolbarItems),
           let decoded = try? JSONDecoder().decode([ScreenshotToolbarItemConfig].self, from: data) {
            toolbarItems = ScreenshotToolbarItemConfig.normalize(decoded)
        }
        let enabled = defaults.stringArray(forKey: Key.enabledProviders) ?? ["free-ai"]
        let modes = defaults.dictionary(forKey: Key.providerDisplayModes) as? [String: String] ?? [:]

        let storedOrder = defaults.stringArray(forKey: Key.providerOrder) ?? AppConfiguration.defaultProviderOrder
        var loadedCustomAIs: [CustomAIServiceConfig] = []
        if let customData = defaults.data(forKey: Key.customAIConfigs),
           let decoded = try? JSONDecoder().decode([CustomAIServiceConfig].self, from: customData) {
            loadedCustomAIs = decoded
        }
        if loadedCustomAIs.isEmpty {
            loadedCustomAIs = [
                CustomAIServiceConfig(
                    id: "openai-compatible",
                    name: "OpenAI 兼容",
                    endpoint: defaults.string(forKey: Key.endpoint) ?? "https://api.openai.com/v1",
                    apiKey: apiKey,
                    model: defaults.string(forKey: Key.model) ?? "gpt-4o-mini",
                    prompt: "",
                    isEnabled: enabled.contains("openai-compatible")
                )
            ]
        }

        var seenOrder = Set<String>()
        var normalizedOrder: [String] = []
        for p in storedOrder {
            let isValid = AppConfiguration.defaultProviderOrder.contains(p) || loadedCustomAIs.contains(where: { $0.id == p })
            if isValid && !seenOrder.contains(p) {
                normalizedOrder.append(p)
                seenOrder.insert(p)
            }
        }
        for p in AppConfiguration.defaultProviderOrder {
            if !seenOrder.contains(p) {
                normalizedOrder.append(p)
                seenOrder.insert(p)
            }
        }
        for c in loadedCustomAIs {
            if !seenOrder.contains(c.id) {
                normalizedOrder.append(c.id)
                seenOrder.insert(c.id)
            }
        }

        return AppConfiguration(
            provider: migratedProvider,
            endpoint: defaults.string(forKey: Key.endpoint) ?? "https://api.openai.com/v1",
            apiKey: apiKey,
            model: defaults.string(forKey: Key.model) ?? "gpt-4o-mini",
            targetLanguage: defaults.string(forKey: Key.targetLanguage) ?? "zh-CN",
            secondTargetLanguage: defaults.string(forKey: Key.secondTargetLanguage) ?? "en",
            aiStreamingEnabled: defaults.object(forKey: Key.aiStreamingEnabled) as? Bool ?? true,
            includeBetaUpdates: defaults.bool(forKey: Key.includeBetaUpdates),
            autoCheckUpdates: defaults.object(forKey: Key.autoCheckUpdates) as? Bool ?? true,
            screenshotToolbarItems: toolbarItems,
            saveCompletedScreenshotsToHistory: defaults.bool(forKey: Key.saveCompletedScreenshotsToHistory),
            ocrAutoCopyNextTime: defaults.bool(forKey: Key.ocrAutoCopyNextTime),
            ocrDefaultFormatting: defaults.integer(forKey: Key.ocrDefaultFormatting),
            enabledProviders: enabled,
            deeplAuthKey: defaults.string(forKey: Key.deeplAuthKey) ?? "",
            deeplEndpoint: defaults.string(forKey: Key.deeplEndpoint) ?? "",
            baiduAppId: defaults.string(forKey: Key.baiduAppId) ?? "",
            baiduSecretKey: defaults.string(forKey: Key.baiduSecretKey) ?? "",
            youdaoAppKey: defaults.string(forKey: Key.youdaoAppKey) ?? "",
            youdaoSecret: defaults.string(forKey: Key.youdaoSecret) ?? "",
            volcanoAccessKey: defaults.string(forKey: Key.volcanoAccessKey) ?? "",
            volcanoSecretKey: defaults.string(forKey: Key.volcanoSecretKey) ?? "",
            screenshotTranslationStyle: defaults.string(forKey: Key.screenshotTranslationStyle) ?? "bob",
            providerDisplayModes: modes,
            providerOrder: normalizedOrder,
            customAIConfigs: loadedCustomAIs
        )
    }

    func save(_ configuration: AppConfiguration) throws {
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        if configuration.provider.requiresUserAPIKey && configuration.provider == .openAICompatible {
            try credentials.save(apiKey, for: .customAI)
        }
        if let encodedCustomAIs = try? JSONEncoder().encode(configuration.customAIConfigs) {
            defaults.set(encodedCustomAIs, forKey: Key.customAIConfigs)
        }
        defaults.set(configuration.providerOrder, forKey: Key.providerOrder)
        defaults.set(configuration.providerDisplayModes, forKey: Key.providerDisplayModes)
        defaults.set(configuration.provider.rawValue, forKey: Key.provider)
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(model, forKey: Key.model)
        defaults.set(configuration.targetLanguage, forKey: Key.targetLanguage)
        defaults.set(configuration.secondTargetLanguage, forKey: Key.secondTargetLanguage)
        defaults.set(configuration.aiStreamingEnabled, forKey: Key.aiStreamingEnabled)
        defaults.set(configuration.includeBetaUpdates, forKey: Key.includeBetaUpdates)
        defaults.set(configuration.autoCheckUpdates, forKey: Key.autoCheckUpdates)
        if let encoded = try? JSONEncoder().encode(configuration.screenshotToolbarItems) {
            defaults.set(encoded, forKey: Key.screenshotToolbarItems)
        }
        defaults.set(configuration.saveCompletedScreenshotsToHistory, forKey: Key.saveCompletedScreenshotsToHistory)
        defaults.set(configuration.ocrAutoCopyNextTime, forKey: Key.ocrAutoCopyNextTime)
        defaults.set(configuration.ocrDefaultFormatting, forKey: Key.ocrDefaultFormatting)
        defaults.set(configuration.enabledProviders, forKey: Key.enabledProviders)
        defaults.set(configuration.deeplAuthKey, forKey: Key.deeplAuthKey)
        defaults.set(configuration.deeplEndpoint, forKey: Key.deeplEndpoint)
        defaults.set(configuration.baiduAppId, forKey: Key.baiduAppId)
        defaults.set(configuration.baiduSecretKey, forKey: Key.baiduSecretKey)
        defaults.set(configuration.youdaoAppKey, forKey: Key.youdaoAppKey)
        defaults.set(configuration.youdaoSecret, forKey: Key.youdaoSecret)
        defaults.set(configuration.volcanoAccessKey, forKey: Key.volcanoAccessKey)
        defaults.set(configuration.volcanoSecretKey, forKey: Key.volcanoSecretKey)
        defaults.set(configuration.screenshotTranslationStyle, forKey: Key.screenshotTranslationStyle)
        defaults.set(configuration.providerDisplayModes, forKey: Key.providerDisplayModes)
        defaults.set(configuration.providerOrder, forKey: Key.providerOrder)
    }
}

struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let service = "io.polyglance.credentials"

    func load(_ slot: CredentialSlot) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialError.operationFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String, for slot: CredentialSlot) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.operationFailed(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.operationFailed(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.operationFailed(status)
        }
    }
}

private enum CredentialError: LocalizedError {
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(status):
            return "无法访问钥匙串（错误码：\(status)）"
        }
    }
}
