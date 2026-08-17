import AppKit
import NativeTranslatorMacKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let configurationStore = AppConfigurationStore()
    let shortcutStore = GlobalShortcutConfigurationStore()
    let recordingSettingsStore = RecordingSettingsStore()

    private lazy var translationClient: any TranslationClient = makeTranslationClient()
    private(set) lazy var viewModel = TranslatorViewModel(client: translationClient)
    private let selectedTextReader = SelectedTextReader()
    private let hotKeyManager = GlobalHotKeyManager()
    private let pinWindowManager = PinWindowManager()
    private let operationErrorPresenter = OperationErrorPresenter()
    private lazy var appUpdater = AppUpdater()
    private var shortcutConfiguration = GlobalShortcutConfiguration.default
    private var translatorPanel: NSPanel?
    private var selectionCaptureTask: Task<Void, Never>?
    private lazy var settingsWindowCoordinator = AuxiliaryWindowCoordinator<NSWindow>(
        makeWindow: { [unowned self] in makeSettingsWindow() },
        present: { $0.makeKeyAndOrderFront(nil) },
        close: { $0.close() }
    )
    private lazy var screenshotCoordinator = ScreenshotCoordinator(
        pinWindowManager: pinWindowManager,
        onOCRTranslate: { [weak self] screenshot, text in
            guard let self else { return }
            try await translateOCRScreenshot(screenshot, sourceText: text)
        },
        onLongScreenshot: { [weak self] screenFrame in
            guard let self else { return }
            try startLongScreenshot(in: screenFrame)
        },
        onScreenRecording: { [weak self] screenFrame in
            guard let self else { return }
            try await screenRecordingCoordinator.start(region: screenFrame)
        }
    )
    private lazy var longScreenshotCoordinator = LongScreenshotCoordinator(
        pinWindowManager: pinWindowManager
    )
    private lazy var screenRecordingCoordinator = ScreenRecordingCoordinator(
        errorPresenter: operationErrorPresenter,
        settingsStore: recordingSettingsStore
    )
    private lazy var applicationTerminationCoordinator = ApplicationTerminationCoordinator(
        hasPendingWork: { [unowned self] in
            screenRecordingCoordinator.isRecording
        },
        prepare: { [unowned self] in
            return await screenRecordingCoordinator.prepareForApplicationTermination()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        createTranslatorPanel()
        if let configuration = try? configurationStore.load() {
            apply(configuration)
        }
        hotKeyManager.onTranslateSelection = { [weak self] in
            self?.showTranslator(capturingSelection: true, translateImmediately: true)
        }
        hotKeyManager.onCaptureSelection = { [weak self] in
            self?.showTranslator(capturingSelection: true, translateImmediately: false)
        }
        hotKeyManager.onScreenshotAndPin = { [weak self] in
            self?.captureScreenshotAndPin()
        }
        hotKeyManager.onPinClipboardImage = { [weak self] in
            self?.pinClipboardImage()
        }
        hotKeyManager.onLongScreenshot = { [weak self] in
            self?.captureLongScreenshot()
        }
        hotKeyManager.onScreenRecording = { [weak self] in
            self?.captureScreenRecordingRegion()
        }
        hotKeyManager.onRestoreMostRecentPin = { [weak self] in
            self?.restoreMostRecentPin()
        }
        do {
            shortcutConfiguration = shortcutStore.load()
            try hotKeyManager.register(shortcutConfiguration)
        } catch {
            showTranslator(capturingSelection: false, translateImmediately: false)
            viewModel.presentError(error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationTerminationCoordinator.requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func apply(_ configuration: AppConfiguration) {
        viewModel.targetLanguage = configuration.targetLanguage
    }

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindowCoordinator.window, !window.isVisible {
            settingsWindowCoordinator.discard()
        }
        settingsWindowCoordinator.show()
    }

    func checkForUpdates() {
        appUpdater.checkForUpdates()
    }

    func captureScreenshotAndPin() {
        captureScreenshot(preferredAction: nil)
    }

    func captureLongScreenshot() {
        captureScreenshot(preferredAction: .longScreenshot)
    }

    func captureScreenRecordingRegion() {
        if screenRecordingCoordinator.handleRecordingShortcut() {
            return
        }
        captureScreenshot(preferredAction: .screenRecording)
    }

    private func captureScreenshot(preferredAction: ScreenshotPreferredAction?) {
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await screenshotCoordinator.captureAndPin(preferredAction: preferredAction)
            } catch {
                operationErrorPresenter.present(.screenshot(error))
            }
        }
    }

    func pinClipboardImage() {
        do {
            try pinWindowManager.pinClipboardImage()
        } catch {
            operationErrorPresenter.present(.clipboardPin(error))
        }
    }

    func restoreMostRecentPin() {
        _ = pinWindowManager.restoreMostRecentPin()
    }

    func hideAllPins() {
        pinWindowManager.hideAllPins()
    }

    func showAllPins() {
        pinWindowManager.showAllPins()
    }

    func closeAllPins() {
        pinWindowManager.closeAllPins()
    }

    func destroyAllPins() {
        pinWindowManager.destroyAllPins()
    }

    func showTranslator(
        capturingSelection: Bool = false,
        translateImmediately: Bool = false
    ) {
        if capturingSelection {
            selectionCaptureTask?.cancel()
            selectionCaptureTask = Task { [weak self] in
                await self?.captureSelectionAndShow(translateImmediately: translateImmediately)
            }
            return
        }

        presentTranslatorPanel()
    }

    private func captureSelectionAndShow(translateImmediately: Bool) async {
        let result = await selectedTextReader.read()
        guard !Task.isCancelled else { return }
        let selectedText: String
        switch result {
        case let .text(text):
            selectedText = text
        case .permissionRequired:
            operationErrorPresenter.present(.accessibilityPermissionRequired())
            return
        case .noSelection:
            if !Task.isCancelled {
                viewModel.presentError("没有检测到选中文字。请先选中文字，或复制后粘贴到输入框。")
                presentTranslatorPanel()
            }
            return
        }

        viewModel.applyCapturedText(selectedText)
        presentTranslatorPanel()
        if translateImmediately {
            await viewModel.translate()
        }
    }

    private func translateOCRScreenshot(
        _ screenshot: SelectedScreenshot,
        sourceText: String
    ) async throws {
        let configuration = try configurationStore.load()
        guard let panel = pinWindowManager.pinTranslation(
            image: screenshot.image,
            sourceText: sourceText,
            translatedText: "",
            sourceFrame: screenshot.screenFrame,
            isTranslating: true
        ), let contentView = panel.contentView as? OCRTranslationPinContentView else {
            throw AppCaptureActionError.pinCreationFailed
        }

        NSApp.activate(ignoringOtherApps: true)
        do {
            for try await update in OCRScreenshotTranslator(client: translationClient)
                .translationUpdates(
                    sourceText: sourceText,
                    targetLanguage: configuration.targetLanguage
                ) {
                try Task.checkCancellation()
                contentView.updateTranslation(update.text, isFinal: update.isFinal)
            }
        } catch {
            pinWindowManager.destroyPin(panel)
            throw error
        }
    }

    private func startLongScreenshot(in screenFrame: CGRect) throws {
        let center = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(screenFrame) }) else {
            throw AppCaptureActionError.screenUnavailable
        }
        try longScreenshotCoordinator.begin(selection: screenFrame, on: screen)
    }

    private func presentTranslatorPanel() {
        NSApp.activate(ignoringOtherApps: true)
        translatorPanel?.makeKeyAndOrderFront(nil)
    }

    private func createTranslatorPanel() {
        guard translatorPanel == nil else {
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Polyglance"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: TranslationView(viewModel: viewModel))
        panel.center()
        translatorPanel = panel
    }

    private func makeSettingsWindow() -> NSWindow {
        let settingsView = SettingsView(
            store: configurationStore,
            shortcutStore: shortcutStore,
            recordingSettingsStore: recordingSettingsStore
        ) { [weak self] configuration, shortcuts, recordingSettings in
            guard let self else {
                return
            }
            try saveSettings(
                configuration,
                shortcuts: shortcuts,
                recordingSettings: recordingSettings
            )
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 780),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Polyglance 设置"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 620, height: 680)
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        return window
    }

    private func saveSettings(
        _ configuration: AppConfiguration,
        shortcuts: GlobalShortcutConfiguration,
        recordingSettings: RecordingSettings
    ) throws {
        let previousShortcuts = shortcutConfiguration
        let previousConfiguration = try configurationStore.load()
        let previousRecordingSettings = recordingSettingsStore.load()
        try shortcuts.validate()
        try hotKeyManager.register(shortcuts)

        do {
            try configurationStore.save(configuration)
            try shortcutStore.save(shortcuts)
            try recordingSettingsStore.save(recordingSettings)
        } catch {
            try? hotKeyManager.register(previousShortcuts)
            try? configurationStore.save(previousConfiguration)
            try? shortcutStore.save(previousShortcuts)
            try? recordingSettingsStore.save(previousRecordingSettings)
            throw error
        }

        shortcutConfiguration = shortcuts
        apply(configuration)
        settingsWindowCoordinator.close()
    }

    private func makeTranslationClient() -> any TranslationClient {
        do {
            return try RustTranslationClient(
                configurationStore: configurationStore
            )
        } catch {
            return UnavailableTranslationClient(error: error)
        }
    }
}

private enum AppCaptureActionError: LocalizedError {
    case screenUnavailable
    case pinCreationFailed

    var errorDescription: String? {
        switch self {
        case .screenUnavailable:
            return "无法识别框选区域所在的显示器"
        case .pinCreationFailed:
            return "无法创建 OCR 翻译贴图"
        }
    }
}

private struct UnavailableTranslationClient: TranslationClient {
    let error: Error

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        throw error
    }
}
