import XCTest
@testable import NativeTranslatorMac

final class AppConfigurationStoreTests: XCTestCase {
    func testFreshInstallDefaultsToMicrosoftTranslationWithoutAIConfiguration() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryCredentialStore()
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

        let configuration = try store.load()

        XCTAssertEqual(configuration.provider, .microsoft)
        XCTAssertEqual(configuration.apiKey, "")
        XCTAssertEqual(
            TranslationProvider.allCases,
            [.google, .microsoft, .freeAI, .openAICompatible]
        )
        XCTAssertFalse(TranslationProvider.google.requiresUserAPIKey)
        XCTAssertFalse(TranslationProvider.microsoft.requiresUserAPIKey)
        XCTAssertFalse(TranslationProvider.freeAI.requiresUserAPIKey)
        XCTAssertTrue(TranslationProvider.openAICompatible.requiresUserAPIKey)
    }

    func testFreshInstallDoesNotProbeAnInaccessibleLegacyKeychainItem() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FailingCredentialStore()
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

        let configuration = try store.load()

        XCTAssertEqual(configuration.provider, .microsoft)
        XCTAssertEqual(configuration.apiKey, "")
        XCTAssertEqual(credentials.loadCount, 0)
    }

    func testProviderChoiceRoundTripsAndKeepsAIKeyInCredentialStore() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryCredentialStore()
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)
        let configuration = AppConfiguration(
            provider: .openAICompatible,
            endpoint: "https://api.deepseek.com/v1",
            apiKey: "secret",
            model: "deepseek-chat",
            targetLanguage: "zh-CN"
        )

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(try credentials.load(.customAI), "secret")
        XCTAssertEqual(credentials.savedSlots, [.customAI])
    }

    func testBuiltInProvidersNeverReadCustomAICredential() throws {
        for provider in TranslationProvider.allCases where !provider.requiresUserAPIKey {
            let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(provider.rawValue, forKey: "translation.provider")
            let credentials = FailingCredentialStore()
            let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

            let configuration = try store.load()

            XCTAssertEqual(configuration.provider, provider)
            XCTAssertEqual(configuration.apiKey, "")
            XCTAssertEqual(credentials.loadCount, 0)
        }
    }

    func testSavingBuiltInProviderNeverWritesCustomAICredential() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FailingCredentialStore()
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)
        let configuration = AppConfiguration(
            provider: .freeAI,
            endpoint: "https://api.openai.com/v1",
            apiKey: "custom-key-left-in-the-form",
            model: "gpt-4.1-mini",
            targetLanguage: "ja"
        )

        try store.save(configuration)

        XCTAssertEqual(credentials.saveCount, 0)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.provider, .freeAI)
        XCTAssertEqual(reloaded.apiKey, "")
        XCTAssertEqual(reloaded.targetLanguage, "ja")
    }

    func testExistingAIConfigurationMigratesWithoutSilentlyChangingProvider() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://api.deepseek.com/v1", forKey: "provider.endpoint")
        let credentials = InMemoryCredentialStore()
        try credentials.save("existing-key", for: .customAI)
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

        let configuration = try store.load()

        XCTAssertEqual(configuration.provider, .openAICompatible)
        XCTAssertEqual(configuration.endpoint, "https://api.deepseek.com/v1")
    }

    func testRemovedProvidersMigrateToMicrosoftInsteadOfUsingAnOldAIKey() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryCredentialStore()
        try credentials.save("old-custom-ai-key", for: .customAI)
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

        for removedProvider in ["my-memory", "system"] {
            defaults.set(removedProvider, forKey: "translation.provider")
            XCTAssertEqual(try store.load().provider, .microsoft)
        }
    }

    func testBundledFreeAIConfigurationRequiresAnHTTPSBuildTimeKeyConfiguration() {
        XCTAssertNil(BundledFreeAIConfiguration(infoDictionary: [:]))
        XCTAssertNil(BundledFreeAIConfiguration(infoDictionary: [
            "PolyglanceFreeAIAPIKey": "build-secret",
            "PolyglanceFreeAIEndpoint": "http://openrouter.ai/api/v1",
        ]))

        let configuration = BundledFreeAIConfiguration(infoDictionary: [
            "PolyglanceFreeAIAPIKey": "build-secret",
            "PolyglanceFreeAIEndpoint": "https://openrouter.ai/api/v1",
            "PolyglanceFreeAIModel": "openrouter/free",
        ])

        XCTAssertEqual(configuration?.apiKey, "build-secret")
        XCTAssertEqual(configuration?.endpoint, "https://openrouter.ai/api/v1")
        XCTAssertEqual(configuration?.model, "openrouter/free")
    }

}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private var values: [CredentialSlot: String] = [:]
    private(set) var savedSlots: Set<CredentialSlot> = []

    func load(_ slot: CredentialSlot) throws -> String? { values[slot] }
    func save(_ value: String, for slot: CredentialSlot) throws {
        savedSlots.insert(slot)
        values[slot] = value.isEmpty ? nil : value
    }
}

private final class FailingCredentialStore: CredentialStoring, @unchecked Sendable {
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    func load(_ slot: CredentialSlot) throws -> String? {
        loadCount += 1
        throw TestCredentialError.accessDenied
    }

    func save(_ value: String, for slot: CredentialSlot) throws {
        saveCount += 1
        throw TestCredentialError.accessDenied
    }
}

private enum TestCredentialError: Error {
    case accessDenied
}
