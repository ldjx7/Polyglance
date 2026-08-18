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
            return "Google 免费翻译"
        case .microsoft:
            return "Microsoft 免费翻译"
        case .freeAI:
            return "免费 AI 翻译"
        case .openAICompatible:
            return "自定义 AI"
        }
    }

    var requiresUserAPIKey: Bool {
        self == .openAICompatible
    }
}

struct AppConfiguration: Equatable, Sendable {
    var provider: TranslationProvider
    var endpoint: String
    var apiKey: String
    var model: String
    var targetLanguage: String
    var aiStreamingEnabled: Bool

    init(
        provider: TranslationProvider,
        endpoint: String,
        apiKey: String,
        model: String,
        targetLanguage: String,
        aiStreamingEnabled: Bool = true
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.targetLanguage = targetLanguage
        self.aiStreamingEnabled = aiStreamingEnabled
    }
}

enum CredentialSlot: String, Hashable, Sendable {
    case customAI = "openai-compatible-api-key"
}

protocol CredentialStoring: Sendable {
    func load(_ slot: CredentialSlot) throws -> String?
    func save(_ value: String, for slot: CredentialSlot) throws
}

struct BundledFreeAIConfiguration: Equatable, Sendable {
    static let defaultEndpoint = "https://openrouter.ai/api/v1"
    static let defaultModel = "openrouter/free"

    let endpoint: String
    let apiKey: String
    let model: String

    init?(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        let apiKey = (infoDictionary["PolyglanceFreeAIAPIKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            return nil
        }
        let endpoint = ((infoDictionary["PolyglanceFreeAIEndpoint"] as? String)
            ?? Self.defaultEndpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let model = ((infoDictionary["PolyglanceFreeAIModel"] as? String)
            ?? Self.defaultModel)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            return nil
        }
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
    }
}

final class AppConfigurationStore: @unchecked Sendable {
    private enum Key {
        static let provider = "translation.provider"
        static let endpoint = "provider.endpoint"
        static let model = "provider.model"
        static let targetLanguage = "translation.target-language"
        static let aiStreamingEnabled = "translation.ai-streaming-enabled"
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
        return AppConfiguration(
            provider: migratedProvider,
            endpoint: defaults.string(forKey: Key.endpoint) ?? "https://api.openai.com/v1",
            apiKey: apiKey,
            model: defaults.string(forKey: Key.model) ?? "gpt-4.1-mini",
            targetLanguage: defaults.string(forKey: Key.targetLanguage) ?? "zh-CN",
            aiStreamingEnabled: defaults.object(forKey: Key.aiStreamingEnabled) as? Bool ?? true
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
    }
}

struct KeychainCredentialStore: CredentialStoring, Sendable {
    private let service = "io.polyglance.credentials"

    // Credentials saved before the Polyglance rename live under the old service
    // name. Keep adopting them until existing installs have all migrated;
    // removing this drops the user's stored API key without any warning.
    private let renamedFromService = "com.native-translator.credentials"

    func load(_ slot: CredentialSlot) throws -> String? {
        if let value = try loadValue(slot, from: service) {
            return value
        }
        guard let migrated = try loadValue(slot, from: renamedFromService) else {
            return nil
        }
        try save(migrated, for: slot)
        deleteValue(slot, from: renamedFromService)
        return migrated
    }

    private func loadValue(_ slot: CredentialSlot, from service: String) throws -> String? {
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

    private func deleteValue(_ slot: CredentialSlot, from service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
        ] as CFDictionary)
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
