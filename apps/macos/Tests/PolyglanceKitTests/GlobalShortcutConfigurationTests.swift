import Foundation
import XCTest
@testable import PolyglanceKit

final class GlobalShortcutConfigurationTests: XCTestCase {
    func testDefaultShortcutsAreValidAndUnique() throws {
        let configuration = GlobalShortcutConfiguration.default

        XCTAssertNoThrow(try configuration.validate())
        XCTAssertEqual(Set(configuration.allShortcuts).count, 7)
        XCTAssertEqual(
            configuration.screenshotAndPin,
            RecordedShortcut(keyCode: 0, modifiers: [.option])
        )
        XCTAssertEqual(
            configuration.pinClipboardImage,
            RecordedShortcut(keyCode: 13, modifiers: [.option])
        )
        XCTAssertEqual(
            configuration.restoreMostRecentPin,
            RecordedShortcut(keyCode: 13, modifiers: [.option, .shift])
        )
        XCTAssertEqual(
            configuration.translateSelection,
            RecordedShortcut(keyCode: 2, modifiers: [.option])
        )
        XCTAssertEqual(
            configuration.screenTranslation,
            RecordedShortcut(keyCode: 1, modifiers: [.option])
        )
        XCTAssertEqual(
            configuration.translateAndReplace,
            RecordedShortcut(keyCode: 15, modifiers: [.option])
        )
        XCTAssertEqual(
            configuration.ocrWorkspace,
            RecordedShortcut(keyCode: 8, modifiers: [.option])
        )
        XCTAssertNil(configuration.longScreenshot)
        XCTAssertNil(configuration.screenRecording)
        XCTAssertNil(configuration.openTranslator)
    }

    func testPresetsAreValid() throws {
        XCTAssertNoThrow(try GlobalShortcutConfiguration.recommended.validate())
        XCTAssertNoThrow(try GlobalShortcutConfiguration.snipaste.validate())
        XCTAssertNoThrow(try GlobalShortcutConfiguration.pixpin.validate())

        XCTAssertEqual(GlobalShortcutConfiguration.snipaste.screenshotAndPin, RecordedShortcut(keyCode: 122, modifiers: []))
        XCTAssertEqual(GlobalShortcutConfiguration.snipaste.pinClipboardImage, RecordedShortcut(keyCode: 99, modifiers: []))
        XCTAssertEqual(GlobalShortcutConfiguration.snipaste.restoreMostRecentPin, RecordedShortcut(keyCode: 99, modifiers: [.shift]))
    }

    func testFunctionKeysWithoutModifiersAreAllowed() throws {
        var configuration = GlobalShortcutConfiguration.default
        configuration.screenshotAndPin = RecordedShortcut(keyCode: 122, modifiers: [])
        XCTAssertNoThrow(try configuration.validate())
    }

    func testDuplicateShortcutIsRejected() {
        var configuration = GlobalShortcutConfiguration.default
        configuration[.pinClipboardImage] = configuration[.screenshotAndPin]

        XCTAssertThrowsError(try configuration.validate()) { error in
            guard case GlobalShortcutValidationError.duplicate = error else {
                return XCTFail("Expected duplicate error, got \(error)")
            }
        }
    }

    func testShortcutWithoutCommandControlOrOptionIsRejected() {
        var configuration = GlobalShortcutConfiguration.default
        configuration[.screenshotAndPin] = RecordedShortcut(
            keyCode: 18,
            modifiers: [.shift]
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            guard case GlobalShortcutValidationError.missingPrimaryModifier(.screenshotAndPin) = error else {
                return XCTFail("Expected missing modifier error, got \(error)")
            }
        }
    }

    func testInvalidKeyCodeIsRejected() {
        var configuration = GlobalShortcutConfiguration.default
        configuration[.translateSelection] = RecordedShortcut(
            keyCode: 128,
            modifiers: [.command]
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? GlobalShortcutValidationError, .invalidKey(.translateSelection))
        }
    }

    func testUnsupportedModifierIsRejected() {
        var configuration = GlobalShortcutConfiguration.default
        configuration[.captureSelection] = RecordedShortcut(
            keyCode: 2,
            modifiers: [.command, ShortcutModifiers(rawValue: 1 << 10)]
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? GlobalShortcutValidationError, .unsupportedModifier(.captureSelection))
        }
    }

    func testEveryActionCanBeUpdatedIndependently() {
        var configuration = GlobalShortcutConfiguration.default

        for (offset, action) in GlobalShortcutAction.allCases.enumerated() {
            let shortcut = RecordedShortcut(
                keyCode: UInt32(40 + offset),
                modifiers: [.control, .shift]
            )
            configuration[action] = shortcut
            XCTAssertEqual(configuration[action], shortcut)
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertEqual(action.eventID, UInt32(offset + 1))
        }

        XCTAssertNoThrow(try configuration.validate())
    }

    func testUnassignedShortcutsAreAllowedAndIgnoredDuringDuplicateValidation() {
        var configuration = GlobalShortcutConfiguration.default
        configuration[.captureSelection] = nil
        configuration[.longScreenshot] = nil

        XCTAssertNoThrow(try configuration.validate())
        XCTAssertEqual(configuration.allShortcuts.count, 7)
    }

    func testStoreRoundTripsCustomConfiguration() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalShortcutConfigurationStore(defaults: defaults)
        var configuration = GlobalShortcutConfiguration.default
        configuration[.screenshotAndPin] = RecordedShortcut(
            keyCode: 20,
            modifiers: [.command, .shift]
        )

        try store.save(configuration)

        XCTAssertEqual(store.load(), configuration)
    }

    func testStoreFallsBackToDefaultsForCorruptData() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: GlobalShortcutConfigurationStore.storageKey)

        let store = GlobalShortcutConfigurationStore(defaults: defaults)

        XCTAssertEqual(store.load(), .default)
    }

    func testStoreRejectsInvalidConfiguration() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = GlobalShortcutConfigurationStore(defaults: defaults)
        var configuration = GlobalShortcutConfiguration.default
        configuration[.captureSelection] = configuration[.translateSelection]

        XCTAssertThrowsError(try store.save(configuration))
        XCTAssertEqual(store.load(), .default)
    }

    func testStoreMigratesLegacyConfigurationWithNewCaptureActions() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyJSON = """
        {
          "translateSelection":{"keyCode":2,"modifiers":2},
          "captureSelection":{"keyCode":2,"modifiers":10},
          "screenshotAndPin":{"keyCode":18,"modifiers":2},
          "pinClipboardImage":{"keyCode":19,"modifiers":2}
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: GlobalShortcutConfigurationStore.storageKey)

        let configuration = GlobalShortcutConfigurationStore(defaults: defaults).load()

        XCTAssertEqual(configuration.translateSelection?.keyCode, 2)
        XCTAssertEqual(configuration.longScreenshot, GlobalShortcutConfiguration.default.longScreenshot)
        XCTAssertEqual(configuration.screenRecording, GlobalShortcutConfiguration.default.screenRecording)
        XCTAssertEqual(
            configuration.restoreMostRecentPin,
            GlobalShortcutConfiguration.default.restoreMostRecentPin
        )
    }

    func testStoreMigratesTheCompleteLegacyDefaultShortcutSet() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = GlobalShortcutConfiguration.legacyDefault
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: GlobalShortcutConfigurationStore.storageKey
        )

        let configuration = GlobalShortcutConfigurationStore(defaults: defaults).load()

        XCTAssertEqual(configuration, .default)
    }

    func testStoreMigratesPreviousControlShiftDefaultShortcuts() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previous = GlobalShortcutConfiguration(
            translateSelection: RecordedShortcut(keyCode: 20, modifiers: [.control, .shift]),
            captureSelection: nil,
            screenshotAndPin: RecordedShortcut(keyCode: 18, modifiers: [.control, .shift]),
            screenshotAndCopy: nil,
            translateAndReplace: nil,
            pinClipboardImage: RecordedShortcut(keyCode: 19, modifiers: [.control, .shift]),
            longScreenshot: nil,
            screenRecording: nil,
            restoreMostRecentPin: RecordedShortcut(keyCode: 23, modifiers: [.control, .shift]),
            screenTranslation: RecordedShortcut(keyCode: 21, modifiers: [.control, .shift]),
            openTranslator: nil,
            ocrTranslate: nil,
            ocrWorkspace: nil,
            ocrTranslationCard: nil
        )
        defaults.set(
            try JSONEncoder().encode(previous),
            forKey: GlobalShortcutConfigurationStore.storageKey
        )

        let configuration = GlobalShortcutConfigurationStore(defaults: defaults).load()

        XCTAssertEqual(configuration, .default)
    }

    func testStoreDoesNotOverwriteCustomizedLegacyShortcuts() throws {
        let suiteName = "GlobalShortcutConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var customized = GlobalShortcutConfiguration.legacyDefault
        customized[.screenshotAndPin] = RecordedShortcut(
            keyCode: 100,
            modifiers: [.control, .shift]
        )
        defaults.set(
            try JSONEncoder().encode(customized),
            forKey: GlobalShortcutConfigurationStore.storageKey
        )

        let configuration = GlobalShortcutConfigurationStore(defaults: defaults).load()

        XCTAssertEqual(configuration, customized)
    }
}
