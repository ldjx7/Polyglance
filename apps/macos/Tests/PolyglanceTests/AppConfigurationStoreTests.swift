import XCTest
@testable import Polyglance

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

    func testScreenshotToolbarItemsRoundTripAndNormalization() throws {
        let suite = "AppConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InMemoryCredentialStore()
        let store = AppConfigurationStore(defaults: defaults, credentials: credentials)

        var config = try store.load()
        XCTAssertEqual(config.screenshotToolbarItems, ScreenshotToolbarItemConfig.defaultItems)

        // Reorder and hide some items
        var customized = [
            ScreenshotToolbarItemConfig(id: "pin", isVisible: true),
            ScreenshotToolbarItemConfig(id: "rect", isVisible: false),
        ]
        config.screenshotToolbarItems = customized
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.screenshotToolbarItems.first?.id, "pin")
        XCTAssertEqual(loaded.screenshotToolbarItems.first?.isVisible, true)
        XCTAssertEqual(loaded.screenshotToolbarItems[1].id, "rect")
        XCTAssertEqual(loaded.screenshotToolbarItems[1].isVisible, false)
        // All default items should be present (normalized)
        XCTAssertEqual(loaded.screenshotToolbarItems.count, ScreenshotToolbarItemConfig.defaultItems.count)
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

    /// The bundled service must work out of the box without any injected
    /// secret, because no secret belongs in an open-source bundle.
    func testBundledFreeAIConfigurationShipsWithoutACredential() {
        let plain = BundledFreeAIConfiguration(infoDictionary: [:], environment: [:])

        XCTAssertNotNil(plain)
        XCTAssertEqual(plain?.endpoint, BundledFreeAIConfiguration.defaultEndpoint)
        XCTAssertTrue(BundledFreeAIConfiguration.defaultEndpoint.hasPrefix("https://"))
    }

    func testBundledFreeAIConfigurationHonoursAnHTTPSOverrideAndRefusesHTTP() {
        let overridden = BundledFreeAIConfiguration(infoDictionary: [
            "PolyglanceFreeAIEndpoint": "https://staging.example/api/free-translate",
        ], environment: [:])
        let environmentOverride = BundledFreeAIConfiguration(
            infoDictionary: [:],
            environment: [
                "POLYGLANCE_FREE_AI_ENDPOINT": "https://env.example/api/free-translate"
            ]
        )

        XCTAssertEqual(overridden?.endpoint, "https://staging.example/api/free-translate")
        XCTAssertEqual(environmentOverride?.endpoint, "https://env.example/api/free-translate")
        XCTAssertNil(BundledFreeAIConfiguration(infoDictionary: [
            "PolyglanceFreeAIEndpoint": "http://insecure.example/api/free-translate",
        ], environment: [:]))
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
