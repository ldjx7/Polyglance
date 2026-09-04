import Foundation
import Security

enum TranslationProvider: String, CaseIterable, Codable, Sendable {
    case google
    case microsoft
    case freeAI = "free-ai"
    case openAICompatible = "openai-compatible"

    var displayName: String {
        switch self {
        case .google:
            return "Google 翻译"
        case .microsoft:
            return "Microsoft 翻译"
        case .freeAI:
            return "FreeAI 翻译"
        case .openAICompatible:
            return "OpenAI 兼容"
        }
    }

    var requiresUserAPIKey: Bool {
        self == .openAICompatible
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
    var provider: TranslationProvider
    var endpoint: String
    var apiKey: String
    var model: String
    var targetLanguage: String
    var aiStreamingEnabled: Bool
    var includeBetaUpdates: Bool
    var autoCheckUpdates: Bool
    var screenshotToolbarItems: [ScreenshotToolbarItemConfig]

    init(
        provider: TranslationProvider,
        endpoint: String,
        apiKey: String,
        model: String,
        targetLanguage: String,
        aiStreamingEnabled: Bool = true,
        includeBetaUpdates: Bool = false,
        autoCheckUpdates: Bool = true,
        screenshotToolbarItems: [ScreenshotToolbarItemConfig] = ScreenshotToolbarItemConfig.defaultItems
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.targetLanguage = targetLanguage
        self.aiStreamingEnabled = aiStreamingEnabled
        self.includeBetaUpdates = includeBetaUpdates
        self.autoCheckUpdates = autoCheckUpdates
        self.screenshotToolbarItems = ScreenshotToolbarItemConfig.normalize(screenshotToolbarItems)
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
        static let aiStreamingEnabled = "translation.ai-streaming-enabled"
        static let includeBetaUpdates = "updater.include-beta-updates"
        static let autoCheckUpdates = "updater.auto-check-updates"
        static let screenshotToolbarItems = "screenshot.toolbar-items"
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
        return AppConfiguration(
            provider: migratedProvider,
            endpoint: defaults.string(forKey: Key.endpoint) ?? "https://api.openai.com/v1",
            apiKey: apiKey,
            model: defaults.string(forKey: Key.model) ?? "gpt-4.1-mini",
            targetLanguage: defaults.string(forKey: Key.targetLanguage) ?? "zh-CN",
            aiStreamingEnabled: defaults.object(forKey: Key.aiStreamingEnabled) as? Bool ?? true,
            includeBetaUpdates: defaults.bool(forKey: Key.includeBetaUpdates),
            autoCheckUpdates: defaults.object(forKey: Key.autoCheckUpdates) as? Bool ?? true,
            screenshotToolbarItems: toolbarItems
        )
    }

    func save(_ configuration: AppConfiguration) throws {
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // Built-in providers never depend on the user's custom-AI credential.
        // Avoid touching Keychain for those providers so an inaccessible stale
        // item cannot block settings, Apple translation, or bundled services.
        if configuration.provider.requiresUserAPIKey {
            // The Keychain is the only fallible destination here. Commit it
            // first so a credential error cannot leave non-secret settings
            // updated while the API key remains stale.
            try credentials.save(apiKey, for: .customAI)
        }
        defaults.set(configuration.provider.rawValue, forKey: Key.provider)
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(model, forKey: Key.model)
        defaults.set(configuration.targetLanguage, forKey: Key.targetLanguage)
        defaults.set(configuration.aiStreamingEnabled, forKey: Key.aiStreamingEnabled)
        defaults.set(configuration.includeBetaUpdates, forKey: Key.includeBetaUpdates)
        defaults.set(configuration.autoCheckUpdates, forKey: Key.autoCheckUpdates)
        if let encoded = try? JSONEncoder().encode(configuration.screenshotToolbarItems) {
            defaults.set(encoded, forKey: Key.screenshotToolbarItems)
        }
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
