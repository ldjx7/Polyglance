import Foundation
import Security

struct AppConfiguration: Sendable {
    var endpoint: String
    var apiKey: String
    var model: String
    var targetLanguage: String
}

final class AppConfigurationStore: @unchecked Sendable {
    private enum Key {
        static let endpoint = "provider.endpoint"
        static let model = "provider.model"
        static let targetLanguage = "translation.target-language"
    }

    private let defaults: UserDefaults
    private let credentials: KeychainCredentialStore

    init(
        defaults: UserDefaults = .standard,
        credentials: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentials = credentials
    }

    func load() throws -> AppConfiguration {
        AppConfiguration(
            endpoint: defaults.string(forKey: Key.endpoint) ?? "https://api.openai.com/v1",
            apiKey: try credentials.load() ?? "",
            model: defaults.string(forKey: Key.model) ?? "gpt-4.1-mini",
            targetLanguage: defaults.string(forKey: Key.targetLanguage) ?? "zh-CN"
        )
    }

    func save(_ configuration: AppConfiguration) throws {
        let endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        // The Keychain is the only fallible destination here. Commit it first
        // so a credential error cannot leave the non-secret settings updated
        // while the API key remains stale.
        try credentials.save(apiKey)
        defaults.set(endpoint, forKey: Key.endpoint)
        defaults.set(model, forKey: Key.model)
        defaults.set(configuration.targetLanguage, forKey: Key.targetLanguage)
    }
}

struct KeychainCredentialStore: Sendable {
    private let service = "com.native-translator.credentials"
    private let account = "openai-compatible-api-key"

    func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

    func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
