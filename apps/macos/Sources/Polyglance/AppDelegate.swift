import AppKit
import PolyglanceKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 150])
        AppDelegate.shared = self
    }

    let configurationStore = AppConfigurationStore()
    let shortcutStore = GlobalShortcutConfigurationStore()
    let recordingSettingsStore = RecordingSettingsStore()
    let launchAtLoginManager = LaunchAtLoginManager()

    private lazy var translationClient: any TranslationClient = makeTranslationClient()
    private(set) lazy var viewModel = TranslatorViewModel(client: translationClient)
    private let selectedTextReader = SelectedTextReader()
    private let hotKeyManager = GlobalHotKeyManager()
    private let pinWindowManager = PinWindowManager()
    private let operationErrorPresenter = OperationErrorPresenter()
    private var appUpdater: AppUpdater { AppUpdater.shared }
    private var shortcutConfiguration = GlobalShortcutConfiguration.default
    private var translatorPanel: NSPanel?
    private var selectionCaptureTask: Task<Void, Never>?
    private var panelEscapeMonitor: Any?
    private var localPanelEscapeMonitor: Any?
    private lazy var settingsWindowLifecycleDelegate = SettingsWindowLifecycleDelegate { [weak self] in
        guard let self else { return }
        if self.pinHistoryWindowCoordinator.window?.isVisible != true {
            NSApp.setActivationPolicy(SettingsApplicationPresentation.backgroundActivationPolicy)
        }
    }
    private lazy var settingsWindowCoordinator = AuxiliaryWindowCoordinator<NSWindow>(
        makeWindow: { [unowned self] in makeSettingsWindow() },
        present: { [unowned self] window in
            SettingsWindowPlacement.center(window, on: settingsPresentationScreen())
            window.makeKeyAndOrderFront(nil)
        },
        close: { $0.close() }
    )
    private lazy var pinHistoryViewModel = PinHistoryViewModel(
        archiveStore: pinWindowManager.archiveStore,
        onPinItem: { [weak self] image in
            self?.pinWindowManager.pin(
                image,
                sourceFrame: nil,
                preferredDisplaySize: nil,
                source: .legacy,
                recordInArchive: false
            )
        }
    )
    private lazy var pinHistoryWindowLifecycleDelegate = SettingsWindowLifecycleDelegate { [weak self] in
        guard let self else { return }
        if self.settingsWindowCoordinator.window?.isVisible != true {
            NSApp.setActivationPolicy(SettingsApplicationPresentation.backgroundActivationPolicy)
        }
    }
    private lazy var pinHistoryWindowCoordinator = AuxiliaryWindowCoordinator<NSWindow>(
        makeWindow: { [unowned self] in makePinHistoryWindow() },
        present: { [unowned self] window in
            Task { await pinHistoryViewModel.reload() }
            SettingsWindowPlacement.center(window, on: settingsPresentationScreen())
            window.makeKeyAndOrderFront(nil)
        },
        close: { $0.close() }
    )
    private lazy var screenshotCoordinator = ScreenshotCoordinator(
        pinWindowManager: pinWindowManager,
        onBeginOCRTranslate: { [weak self] screenshot in
            guard let self else { return }
            self.showTranslator(with: "", near: screenshot.screenFrame, isOcrPending: true)
        },
        onOCRTranslate: { [weak self] _, text in
            guard let self else { return }
            self.completeOCRTranslate(with: text)
        },
        onOCRTranslationCard: { [weak self] screenshot, text in
            guard let self else { return }
            try await self.translateOCRScreenshot(screenshot, sourceText: text)
        },
        onLongScreenshot: { [weak self] screenFrame in
            guard let self else { return }
            try startLongScreenshot(in: screenFrame)
        },
        onScreenRecording: { [weak self] screenFrame in
            guard let self else { return }
            try await screenRecordingCoordinator.start(region: screenFrame)
        },
        onScreenTranslate: { [weak self] selection in
            guard let self else { return }
            screenTranslationCoordinator.begin(
                with: selection.capture,
                selection: selection.selection
            )
        }
    )
    private lazy var screenTranslationCoordinator = ScreenTranslationCoordinator(
        translationClient: translationClient,
        configurationStore: configurationStore,
        errorPresenter: operationErrorPresenter,
        pinWindowManager: pinWindowManager,
        onReselect: { [weak self] in
            self?.captureScreenTranslation()
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
            true // Archive writes may still be queued even when recording is idle.
        },
        prepare: { [unowned self] in
            guard await screenRecordingCoordinator.prepareForApplicationTermination() else { return false }
            await pinWindowManager.prepareForTermination()
            return true
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(showArchiveWriteFailure), name: PinArchiveStore.writeFailedNotification, object: nil)
        NSApp.mainMenu = PolyglanceApplicationMenu.make(settingsTarget: self)
        createTranslatorPanel()
        pinHistoryViewModel.onPinContent = { [weak self] image, id, text in
            self?.pinWindowManager.pinHistoryItem(image, id: id, text: text)
        }
        Task { await pinWindowManager.restoreSessionWindows() }
        if let configuration = try? configurationStore.load() {
            apply(configuration)
        }
        ScreenshotCoordinator.prewarm()
        hotKeyManager.onTranslateSelection = { [weak self] in
            self?.showTranslator(capturingSelection: true, translateImmediately: true)
        }
        hotKeyManager.onTranslateAndReplace = { [weak self] in
            self?.translateSelectionAndReplace()
        }
        hotKeyManager.onCaptureSelection = { [weak self] in
            self?.showTranslator(capturingSelection: true, translateImmediately: false)
        }
        hotKeyManager.onScreenshotAndPin = { [weak self] in
            self?.captureScreenshotAndPin()
        }
        hotKeyManager.onScreenshotAndCopy = { [weak self] in
            self?.captureScreenshotAndCopy()
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
        hotKeyManager.onScreenTranslation = { [weak self] in
            self?.captureScreenTranslation()
        }
        hotKeyManager.onOpenTranslator = { [weak self] in
            self?.showTranslator()
        }
        hotKeyManager.onOcrTranslate = { [weak self] in
            self?.captureOCRTranslate()
        }
        hotKeyManager.onOcrWorkspace = { [weak self] in
            self?.captureOCRWorkspace()
        }
        hotKeyManager.onOcrTranslationCard = { [weak self] in
            self?.captureOCRTranslationCard()
        }
        do {
            shortcutConfiguration = shortcutStore.load()
            try hotKeyManager.register(shortcutConfiguration)
        } catch {
            showTranslator(capturingSelection: false, translateImmediately: false)
            viewModel.presentError(error.localizedDescription)
        }
    }

    @objc private func showArchiveWriteFailure() {
        let alert = NSAlert()
        alert.messageText = "未能保存到贴图历史"
        alert.informativeText = "截图或贴图仍可使用。请检查历史目录的可用空间、写入权限或文件占用情况后重试。"
        alert.alertStyle = .warning
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationTerminationCoordinator.requestTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func apply(_ configuration: AppConfiguration) {
        viewModel.defaultTargetLanguage = configuration.targetLanguage
        viewModel.secondTargetLanguage = configuration.secondTargetLanguage
        if viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.targetLanguage = configuration.targetLanguage
        } else {
            viewModel.updateAutoTargetLanguage(for: viewModel.sourceText)
        }
        let effective = configuration.enabledProviders.isEmpty ? ["free-ai"] : configuration.enabledProviders
        viewModel.enabledProviders = effective
        viewModel.primaryProvider = effective.first ?? "free-ai"
        viewModel.providerModes = configuration.providerDisplayModes
        viewModel.providerOrder = configuration.providerOrder
        var customNames: [String: String] = [:]
        for c in configuration.customAIConfigs {
            customNames[c.id] = c.name
        }
        viewModel.customAIDisplayNames = customNames
    }

    func showSettings() {
        NSApp.setActivationPolicy(SettingsApplicationPresentation.visibleActivationPolicy)
        NSApp.activate(ignoringOtherApps: true)
        if let window = settingsWindowCoordinator.window, !window.isVisible {
            settingsWindowCoordinator.discard()
        }
        settingsWindowCoordinator.show()
    }

    @objc func showSettingsFromApplicationMenu() {
        showSettings()
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

    func captureScreenTranslation() {
        let style = (try? configurationStore.load())?.screenshotTranslationStyle ?? "bob"
        if style == "youdao" {
            captureScreenshot(preferredAction: .screenTranslation)
        } else {
            captureScreenshot(preferredAction: .ocrTranslate)
        }
    }

    func captureScreenshotAndCopy() {
        captureScreenshot(preferredAction: .screenshotAndCopy)
    }

    func captureScreenRecordingRegion() {
        if screenRecordingCoordinator.handleRecordingShortcut() {
            return
        }
        captureScreenshot(preferredAction: .screenRecording)
    }

    func captureOCRTranslate() {
        captureScreenshot(preferredAction: .ocrTranslate)
    }

    func captureOCRWorkspace() {
        captureScreenshot(preferredAction: .ocrWorkspace)
    }

    func captureOCRTranslationCard() {
        captureScreenshot(preferredAction: .ocrTranslationCard)
    }

    private func captureScreenshot(preferredAction: ScreenshotPreferredAction?) {
        let triggerTime = CFAbsoluteTimeGetCurrent()
        Task { [weak self] in
            guard let self else {
                return
            }
            do {
                try await screenshotCoordinator.captureAndPin(
                    preferredAction: preferredAction,
                    triggerTime: triggerTime
                )
            } catch {
                if case .permissionRequired = error as? ScreenshotError {
                    return
                }
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

    func showPinHistory() {
        NSApp.setActivationPolicy(SettingsApplicationPresentation.visibleActivationPolicy)
        NSApp.activate(ignoringOtherApps: true)
        if let window = pinHistoryWindowCoordinator.window, !window.isVisible {
            pinHistoryWindowCoordinator.discard()
        }
        pinHistoryWindowCoordinator.show()
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
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                TextReplacementService.lastTargetApplication = app
            }
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
            return
        case .noSelection:
            if !Task.isCancelled {
                viewModel.presentError("没有检测到选中文字。请先选中文字，或复制后粘贴到输入框。")
                presentTranslatorPanel()
            }
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let mouseFrame = CGRect(x: mouseLocation.x, y: mouseLocation.y, width: 1, height: 1)
        showTranslator(with: selectedText, near: mouseFrame, shouldTranslate: translateImmediately, takeFocus: false)
    }

    func translateSelectionAndReplace() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            TextReplacementService.lastTargetApplication = app
        }
        Task { [weak self] in
            guard let self else { return }
            let result = await selectedTextReader.read()
            guard !Task.isCancelled else { return }
            let selectedText: String
            switch result {
            case let .text(text):
                selectedText = text
            case .permissionRequired, .noSelection:
                return
            }

            let configuration = (try? configurationStore.load()) ?? AppConfiguration()
            let targetLang = determineTargetLanguage(
                for: selectedText,
                primary: configuration.targetLanguage,
                secondary: configuration.secondTargetLanguage
            )

            let request = AppTranslationRequest(
                text: selectedText,
                sourceLanguage: nil,
                targetLanguage: targetLang,
                provider: configuration.provider.rawValue
            )

            do {
                let translationResult = try await translationClient.translate(request)
                guard !Task.isCancelled, !translationResult.text.isEmpty else { return }
                TextReplacementService.replaceSelection(with: translationResult.text)
            } catch {
            }
        }
    }

    private func determineTargetLanguage(for text: String, primary: String, secondary: String) -> String {
        let hasChinese = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let primaryIsChinese = primary.lowercased().starts(with: "zh")
        if primaryIsChinese {
            return hasChinese ? (secondary.isEmpty ? "en" : secondary) : primary
        } else {
            return hasChinese ? primary : (secondary.isEmpty ? "zh-CN" : secondary)
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

    func showTranslator(
        with text: String = "",
        near targetFrame: CGRect? = nil,
        isOcrPending: Bool = false,
        shouldTranslate: Bool = true,
        takeFocus: Bool = true
    ) {
        createTranslatorPanel()
        guard let panel = translatorPanel else { return }
        if let cfg = try? configurationStore.load() {
            apply(cfg)
        }
        if isOcrPending {
            viewModel.startOcrLoading()
        } else {
            viewModel.finishOcrLoading()
            viewModel.applyCapturedText(text)
        }
        if !panel.isVisible {
            if let targetFrame {
                placeTranslatorPanel(panel, near: targetFrame)
            } else {
                panel.center()
            }
        }
        if takeFocus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if shouldTranslate && !isOcrPending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.startTranslation()
        }
    }

    func completeOCRTranslate(with text: String) {
        viewModel.finishOcrLoading()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            viewModel.presentError("未识别到文字")
        } else {
            viewModel.applyCapturedText(trimmed)
            viewModel.startTranslation()
        }
    }

    private func placeTranslatorPanel(_ panel: NSPanel, near targetFrame: CGRect) {
        let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(targetFrame) })
            ?? NSScreen.main
        guard let screen else {
            panel.center()
            return
        }

        let visible = screen.visibleFrame
        let panelSize = panel.frame.size

        if targetFrame.width <= 2 && targetFrame.height <= 2 {
            var x = targetFrame.minX - 30
            var y = targetFrame.minY - panelSize.height - 12
            if y < visible.minY {
                y = targetFrame.maxY + 12
            }
            x = max(visible.minX + 10, min(x, visible.maxX - panelSize.width - 10))
            y = max(visible.minY + 10, min(y, visible.maxY - panelSize.height - 10))
            panel.setFrameOrigin(CGPoint(x: x, y: y))
            return
        }

        var x = targetFrame.maxX + 12
        var y = targetFrame.maxY - panelSize.height

        if x + panelSize.width > visible.maxX {
            x = targetFrame.minX - panelSize.width - 12
        }

        if x < visible.minX {
            x = targetFrame.midX - panelSize.width / 2
            y = targetFrame.minY - panelSize.height - 12
            if y < visible.minY {
                y = targetFrame.maxY + 12
            }
        }

        x = max(visible.minX + 10, min(x, visible.maxX - panelSize.width - 10))
        y = max(visible.minY + 10, min(y, visible.maxY - panelSize.height - 10))

        panel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func createTranslatorPanel() {
        guard translatorPanel == nil else {
            return
        }

        let panel = FloatingTranslatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 380, height: 340)
        panel.title = "Polyglance"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.titlebarSeparatorStyle = .none
        panel.hideTrafficLights()
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setFrameAutosaveName("PolyglanceTranslatorPanel")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: TranslationView(viewModel: viewModel))
        panel.center()
        translatorPanel = panel
        setupPanelEscapeMonitors()
    }

    private func setupPanelEscapeMonitors() {
        if panelEscapeMonitor == nil {
            panelEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let panel = self.translatorPanel, panel.isVisible else { return }
                if event.keyCode == 53 {
                    panel.orderOut(nil)
                }
            }
        }
        if localPanelEscapeMonitor == nil {
            localPanelEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let panel = self.translatorPanel, panel.isVisible else { return event }
                if event.keyCode == 53 {
                    panel.orderOut(nil)
                    return nil
                }
                return event
            }
        }
    }

    private func makeSettingsWindow() -> NSWindow {
        let settingsView = SettingsView(
            store: configurationStore,
            shortcutStore: shortcutStore,
            recordingSettingsStore: recordingSettingsStore,
            launchAtLoginManager: launchAtLoginManager
        ) { [weak self] configuration, shortcuts, recordingSettings, launchAtLoginEnabled in
            guard let self else {
                return
            }
            try saveSettings(
                configuration,
                shortcuts: shortcuts,
                recordingSettings: recordingSettings,
                launchAtLoginEnabled: launchAtLoginEnabled
            )
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Polyglance 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = settingsWindowLifecycleDelegate
        window.contentViewController = NSHostingController(rootView: settingsView)
        window.center()
        return window
    }

    private func makePinHistoryWindow() -> NSWindow {
        let historyView = PinHistoryView(viewModel: pinHistoryViewModel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "贴图历史"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = pinHistoryWindowLifecycleDelegate
        window.contentViewController = NSHostingController(rootView: historyView)
        window.center()
        return window
    }

    private func settingsPresentationScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    private func saveSettings(
        _ configuration: AppConfiguration,
        shortcuts: GlobalShortcutConfiguration,
        recordingSettings: RecordingSettings,
        launchAtLoginEnabled: Bool
    ) throws {
        let previousShortcuts = shortcutConfiguration
        let previousConfiguration = try configurationStore.load()
        let previousRecordingSettings = recordingSettingsStore.load()
        let previousLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        try shortcuts.validate()
        try hotKeyManager.register(shortcuts)

        var launchAtLoginWasApplied = false
        do {
            try launchAtLoginManager.setEnabled(launchAtLoginEnabled)
            launchAtLoginWasApplied = true
            try configurationStore.save(configuration)
            try shortcutStore.save(shortcuts)
            try recordingSettingsStore.save(recordingSettings)
        } catch {
            try? hotKeyManager.register(previousShortcuts)
            try? configurationStore.save(previousConfiguration)
            try? shortcutStore.save(previousShortcuts)
            try? recordingSettingsStore.save(previousRecordingSettings)
            if launchAtLoginWasApplied {
                try? launchAtLoginManager.setEnabled(previousLaunchAtLoginEnabled)
            }
            throw error
        }

        shortcutConfiguration = shortcuts
        apply(configuration)
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

private final class FloatingTranslatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        hideTrafficLights()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        hideTrafficLights()
    }

    func hideTrafficLights() {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach {
            let btn = standardWindowButton($0)
            btn?.isHidden = true
            btn?.removeFromSuperview()
        }
    }
}
