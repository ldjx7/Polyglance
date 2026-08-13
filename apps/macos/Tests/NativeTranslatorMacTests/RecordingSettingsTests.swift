import Foundation
import XCTest
@testable import NativeTranslatorMac

final class RecordingSettingsTests: XCTestCase {
    func testDefaultSettingsFavorCompatibleMP4AndAskForDestination() {
        let settings = RecordingSettings.default

        XCTAssertEqual(settings.format, .mp4)
        XCTAssertEqual(settings.quality, .standard)
        XCTAssertTrue(settings.asksForSaveLocation)
        XCTAssertTrue(settings.capturesSystemAudio)
        XCTAssertFalse(settings.capturesMicrophone)
        XCTAssertTrue(settings.showsCursor)
        XCTAssertEqual(settings.countdownDelay, .threeSeconds)
        XCTAssertEqual(settings.frameRate, 30)
    }

    func testSettingsRoundTripThroughIsolatedDefaults() throws {
        let suiteName = "RecordingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecordingSettingsStore(defaults: defaults)
        let expected = RecordingSettings(
            format: .gif,
            quality: .high,
            asksForSaveLocation: false,
            saveDirectoryPath: "/tmp/Native Translator Clips",
            capturesSystemAudio: false,
            capturesMicrophone: true,
            showsCursor: false,
            countdownDelay: .fiveSeconds,
            frameRate: 24
        )

        try store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testOlderStoredSettingsMigrateToDefaultCountdownDelay() throws {
        let suiteName = "RecordingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyJSON = """
        {
          "format": "mp4",
          "quality": "standard",
          "asksForSaveLocation": false,
          "capturesSystemAudio": true,
          "capturesMicrophone": false,
          "showsCursor": true
        }
        """
        defaults.set(Data(legacyJSON.utf8), forKey: RecordingSettingsStore.storageKey)

        let settings = RecordingSettingsStore(defaults: defaults).load()

        XCTAssertEqual(settings.format, .mp4)
        XCTAssertEqual(settings.countdownDelay, .threeSeconds)
        XCTAssertEqual(settings.frameRate, ScreenRecordingQuality.standard.profile(for: .mp4).frameRate)
    }

    func testRecordingDelaysExposeOnlySupportedPixPinStyleChoices() {
        XCTAssertEqual(ScreenRecordingDelay.allCases.map(\.rawValue), [0, 3, 5])
        XCTAssertEqual(ScreenRecordingDelay.immediate.displayName, "无延时")
        XCTAssertEqual(ScreenRecordingDelay.threeSeconds.displayName, "3 秒")
        XCTAssertEqual(ScreenRecordingDelay.fiveSeconds.displayName, "5 秒")
    }

    func testRecordingFrameRateChoicesMatchPixPinToolbarChoices() {
        XCTAssertEqual(ScreenRecordingFrameRateChoice.allCases.map(\.rawValue), [5, 16, 24, 30, 60])
    }

    func testFrameRatePolicyKeepsMP4ChoiceAndMapsUnsupportedGIFFPS() {
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.normalized(60, for: .mp4), 60)
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.normalized(60, for: .gif), 16)
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.normalized(24, for: .gif), 16)
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.normalized(5, for: .gif), 5)
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.choices(for: .gif), [5, 16])
        XCTAssertEqual(ScreenRecordingFrameRatePolicy.choices(for: .mp4), [5, 16, 24, 30, 60])
    }

    func testQualitySummaryUsesExplicitFrameRateRatherThanProfileDefault() {
        var settings = RecordingSettings.default
        settings.quality = .compact
        settings.frameRate = 60

        let summary = RecordingSettingsPresentation.qualitySummary(settings)

        XCTAssertTrue(summary.contains("60 FPS"))
        XCTAssertFalse(summary.contains("24 FPS"))
    }

    func testReviewSaveDestinationPolicyPromptsOnlyForExplicitSaveWhenEnabled() {
        XCTAssertEqual(
            RecordingReviewDestinationPolicy.mode(for: .save, asksForSaveLocation: true),
            .prompt
        )
        XCTAssertEqual(
            RecordingReviewDestinationPolicy.mode(for: .save, asksForSaveLocation: false),
            .defaultDirectory
        )
        XCTAssertEqual(
            RecordingReviewDestinationPolicy.mode(for: .quickSave, asksForSaveLocation: true),
            .defaultDirectory
        )
        XCTAssertEqual(
            RecordingSettingsPresentation.saveLocationToggleTitle,
            "点击保存时询问保存位置"
        )
        XCTAssertTrue(RecordingReviewDestinationPolicy.revealsInFinder(after: .save))
        XCTAssertFalse(RecordingReviewDestinationPolicy.revealsInFinder(after: .quickSave))
    }

    func testClipboardCopyPersistsRecordingBeyondTemporarySourceLifetime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingClipboard-\(UUID().uuidString)", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = temporary.appendingPathComponent("capture.mp4")
        try Data("recording".utf8).write(to: source)
        let store = RecordingReviewArtifactStore()

        let persisted = try store.persistForClipboard(
            sourceURL: source,
            directory: recordings,
            format: .mp4
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))
        XCTAssertEqual(try Data(contentsOf: persisted), Data("recording".utf8))
        XCTAssertTrue(persisted.path.hasPrefix(recordings.path))
    }

    func testAtomicRecordingSaveReplacesExistingDestinationOnlyAfterStagingSucceeds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingAtomicSave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let destination = root.appendingPathComponent("destination.mp4")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)

        try RecordingFileInstaller().install(source: source, at: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.contains("native-translator-staging")
        })
    }

    func testAtomicRecordingSaveFailurePreservesExistingDestinationAndRemovesStagingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingAtomicFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let destination = root.appendingPathComponent("destination.mp4")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        let installer = RecordingFileInstaller(
            replace: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        XCTAssertThrowsError(try installer.install(source: source, at: destination))

        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.contains("native-translator-staging")
        })
    }

    func testMalformedStoredSettingsFallBackToDefaults() throws {
        let suiteName = "RecordingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: RecordingSettingsStore.storageKey)

        XCTAssertEqual(RecordingSettingsStore(defaults: defaults).load(), .default)
    }

    func testFormatsExposeCorrectExtensionAndAudioCapability() {
        XCTAssertEqual(ScreenRecordingFormat.mp4.fileExtension, "mp4")
        XCTAssertTrue(ScreenRecordingFormat.mp4.supportsAudio)
        XCTAssertEqual(ScreenRecordingFormat.gif.fileExtension, "gif")
        XCTAssertFalse(ScreenRecordingFormat.gif.supportsAudio)
        XCTAssertEqual(ScreenRecordingFormat.mp4.displayName, "MP4")
        XCTAssertEqual(ScreenRecordingFormat.gif.displayName, "GIF")
        XCTAssertTrue(ScreenRecordingFormat.mp4.detail.contains("声音"))
        XCTAssertTrue(ScreenRecordingFormat.gif.detail.contains("无声音"))
    }

    func testEveryQualityAndFormatCombinationHasAUsableProfile() {
        for quality in ScreenRecordingQuality.allCases {
            XCTAssertFalse(quality.displayName.isEmpty)
            XCTAssertFalse(quality.detail.isEmpty)
            for format in ScreenRecordingFormat.allCases {
                let profile = quality.profile(for: format)
                XCTAssertGreaterThan(profile.frameRate, 0)
                XCTAssertGreaterThan(profile.maxDimension, 0)
                if format == .gif {
                    XCTAssertNotNil(profile.maximumDuration)
                    XCTAssertNotNil(profile.maximumFrameCount)
                    XCTAssertEqual(profile.videoBitrate(for: CGSize(width: 640, height: 480)), 0)
                } else {
                    XCTAssertNil(profile.maximumDuration)
                    XCTAssertNil(profile.maximumFrameCount)
                    XCTAssertGreaterThan(profile.videoBitrate(for: CGSize(width: 640, height: 480)), 0)
                }
            }
        }
    }

    func testQualityProfilesHaveStableFrameRateResolutionAndBitrateMapping() {
        let size = CGSize(width: 1_920, height: 1_080)
        let compact = ScreenRecordingQuality.compact.profile(for: .mp4)
        let standard = ScreenRecordingQuality.standard.profile(for: .mp4)
        let high = ScreenRecordingQuality.high.profile(for: .mp4)

        XCTAssertEqual(compact.frameRate, 24)
        XCTAssertEqual(standard.frameRate, 30)
        XCTAssertEqual(high.frameRate, 60)
        XCTAssertLessThan(compact.videoBitrate(for: size), standard.videoBitrate(for: size))
        XCTAssertLessThan(standard.videoBitrate(for: size), high.videoBitrate(for: size))
        XCTAssertEqual(standard.outputSize(for: CGSize(width: 3_841, height: 2_161)),
                       CGSize(width: 2_560, height: 1_440))
    }

    func testProfileDoesNotUpscaleAndKeepsEncoderDimensionsEven() {
        let profile = ScreenRecordingQuality.high.profile(for: .mp4)

        XCTAssertEqual(
            profile.outputSize(for: CGSize(width: 801, height: 601)),
            CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(
            profile.outputSize(for: CGSize(width: 7_681, height: 2_161)),
            CGSize(width: 3_840, height: 1_080)
        )
        XCTAssertEqual(profile.outputSize(for: .zero), .zero)
        XCTAssertEqual(
            profile.outputSize(for: CGSize(width: CGFloat.infinity, height: 100)),
            .zero
        )
    }

    func testOptionsCreatedFromSettingsApplyProfileAndAudioRules() {
        let settings = RecordingSettings(
            format: .mp4,
            quality: .compact,
            asksForSaveLocation: false,
            saveDirectoryPath: nil,
            capturesSystemAudio: false,
            capturesMicrophone: true,
            showsCursor: false
        )
        let options = ScreenRecordingOptions(settings: settings)

        XCTAssertEqual(options.format, .mp4)
        XCTAssertEqual(options.quality, .compact)
        XCTAssertEqual(options.frameRate, 24)
        XCTAssertFalse(options.capturesSystemAudio)
        XCTAssertTrue(options.capturesMicrophone)
        XCTAssertFalse(options.showsCursor)
        XCTAssertNil(options.maximumDuration)
        XCTAssertNil(options.gifLimits)
        XCTAssertGreaterThan(options.videoBitrate(for: CGSize(width: 1_920, height: 1_080)), 0)
    }

    func testStoreResolvesCustomSaveDirectory() throws {
        let suiteName = "RecordingSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var settings = RecordingSettings.default
        settings.saveDirectoryPath = "  /tmp/Native Translator Clips  "
        let store = RecordingSettingsStore(defaults: defaults)
        try store.save(settings)

        XCTAssertEqual(store.resolvedSaveDirectory().path, "/tmp/Native Translator Clips")
    }

    func testGIFOptionsDisableAudioAndUseBoundedProfile() {
        let options = ScreenRecordingOptions(
            format: .gif,
            quality: .high,
            capturesSystemAudio: true,
            capturesMicrophone: true
        )

        XCTAssertFalse(options.capturesSystemAudio)
        XCTAssertFalse(options.capturesMicrophone)
        XCTAssertEqual(options.frameRate, 15)
        XCTAssertEqual(options.maximumDuration, 45)
        XCTAssertLessThanOrEqual(options.encodingSize(for: CGSize(width: 4_000, height: 3_000)).width, 1_600)
    }

    func testOptionsUseExplicitSettingsFrameRateInsteadOfQualityDefault() {
        let settings = RecordingSettings(
            format: .mp4,
            quality: .compact,
            asksForSaveLocation: false,
            saveDirectoryPath: nil,
            capturesSystemAudio: false,
            capturesMicrophone: false,
            showsCursor: true,
            frameRate: 60
        )

        XCTAssertEqual(ScreenRecordingOptions(settings: settings).frameRate, 60)
    }

    func testSuggestedFilenameAndCollisionResolutionUseSelectedExtension() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 0)
        let name = RecordingDestinationPolicy.suggestedFilename(
            format: .gif,
            date: date,
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        )
        XCTAssertEqual(name, "Polyglance Recording 1970-01-01 08.00.00.gif")

        let first = try RecordingDestinationPolicy.availableURL(
            directory: root,
            suggestedFilename: name
        )
        XCTAssertEqual(first.lastPathComponent, name)
        try Data().write(to: first)
        let second = try RecordingDestinationPolicy.availableURL(
            directory: root,
            suggestedFilename: name
        )
        XCTAssertEqual(second.lastPathComponent, "Polyglance Recording 1970-01-01 08.00.00 2.gif")
        try Data().write(to: second)
        let third = try RecordingDestinationPolicy.availableURL(
            directory: root,
            suggestedFilename: name
        )
        XCTAssertEqual(third.lastPathComponent, "Polyglance Recording 1970-01-01 08.00.00 3.gif")
    }
}
