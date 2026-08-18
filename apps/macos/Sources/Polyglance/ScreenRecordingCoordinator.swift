import AppKit
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers

typealias ScreenRecordingReviewDiscardConfirmation = @MainActor (
    NSWindow?
) async -> ScreenRecordingReviewDiscardDecision

@MainActor
private enum ScreenRecordingReviewDiscardAlert {
    static func present(attachedTo window: NSWindow?) async -> ScreenRecordingReviewDiscardDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "录屏尚未保存"
        alert.informativeText = "保存后再继续，或确认丢弃这次录屏。取消会保留当前录屏状态。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "丢弃")
        alert.addButton(withTitle: "取消")
        alert.buttons[2].keyEquivalent = "\u{1b}"

        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }
}

@MainActor
final class ScreenRecordingCoordinator: NSObject {
    private let errorPresenter: OperationErrorPresenter
    private let settingsStore: RecordingSettingsStore
    private let fileManager: FileManager
    private let reviewArtifactStore: RecordingReviewArtifactStore
    private let fileInstaller: RecordingFileInstaller
    private let confirmReviewDiscard: ScreenRecordingReviewDiscardConfirmation

    private var engine: ScreenRecordingEngine?
    private var overlaySession: ScreenRecordingOverlaySession?
    private var reviewSession: ScreenRecordingReviewSession?
    private var sessionState = ScreenRecordingSessionStateMachine()
    private var engineLifecycle = ScreenRecordingLifecycleGate()
    private var terminationIntent = ScreenRecordingTerminationIntent()
    private var reviewArtifactState = ScreenRecordingReviewArtifactState()
    private var isResolvingReviewExit = false
    private var countdownTask: Task<Void, Never>?
    private var pendingStartFailure: Error?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentRegion: CGRect?
    private var currentScreen: NSScreen?
    private var currentSettings: RecordingSettings?
    private var temporaryOutputURL: URL?

    init(
        errorPresenter: OperationErrorPresenter,
        settingsStore: RecordingSettingsStore = RecordingSettingsStore(),
        fileManager: FileManager = .default,
        confirmReviewDiscard: ScreenRecordingReviewDiscardConfirmation? = nil
    ) {
        self.errorPresenter = errorPresenter
        self.settingsStore = settingsStore
        self.fileManager = fileManager
        reviewArtifactStore = RecordingReviewArtifactStore(fileManager: fileManager)
        fileInstaller = RecordingFileInstaller(fileManager: fileManager)
        self.confirmReviewDiscard = confirmReviewDiscard ?? { window in
            await ScreenRecordingReviewDiscardAlert.present(attachedTo: window)
        }
        super.init()
    }

    var isRecording: Bool {
        sessionState.state != .idle
    }

    var state: ScreenRecordingSessionState {
        sessionState.state
    }

    /// Returns true whenever an existing recording session consumed the shortcut.
    /// The application can enter region selection only when this returns false.
    func handleRecordingShortcut() -> Bool {
        switch ScreenRecordingShortcutAction.resolve(for: sessionState.state) {
        case .notHandled:
            return false
        case .beginRecording:
            beginRecording()
        case .cancelCountdown:
            cancelCountdown()
        case .stopRecording:
            Task { @MainActor [weak self] in
                await self?.stopAndReview()
            }
        case .consume:
            break
        }
        return true
    }

    /// Enters the editable blue-frame ready state. No capture engine or save
    /// panel is created until the user explicitly presses Start.
    func start(region: CGRect) async throws {
        guard sessionState.presentReady() else {
            throw ScreenRecordingCoordinatorError.alreadyRecording
        }
        guard CGPreflightScreenCaptureAccess() else {
            sessionState.close()
            throw ScreenRecordingCoordinatorError.permissionRequired(restartRequired: false)
        }
        guard let screen = screen(containing: region) else {
            sessionState.close()
            throw ScreenRecordingCoordinatorError.screenUnavailable
        }

        var settings = settingsStore.load()
        settings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
            settings.frameRate,
            for: settings.format
        )
        currentRegion = region.standardized.intersection(screen.frame.standardized)
        currentScreen = screen
        currentSettings = settings

        let overlay = ScreenRecordingOverlaySession(
            region: currentRegion ?? region,
            screen: screen,
            settings: settings
        )
        overlay.onRegionChanged = { [weak self] region in
            self?.currentRegion = region
        }
        overlay.onSettingsChanged = { [weak self] settings in
            guard let self else { return }
            var settings = settings
            settings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
                settings.frameRate,
                for: settings.format
            )
            currentSettings = settings
            overlay.update(settings: settings)
            do {
                try settingsStore.save(settings)
            } catch {
                errorPresenter.present(.screenRecording(error))
            }
        }
        overlay.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .start:
                beginRecording()
            case .pauseOrResume:
                togglePause()
            case .stop:
                Task { @MainActor [weak self] in
                    await self?.stopAndReview()
                }
            case .close:
                Task { @MainActor [weak self] in
                    await self?.requestCloseFromOverlay()
                }
            }
        }
        overlaySession = overlay
        overlay.present()
        overlay.update(state: .ready)
    }

    func prepareForApplicationTermination() async -> Bool {
        if sessionState.state == .recording || sessionState.state == .paused {
            guard let decision = await requestDiscardDecision(
                attachedTo: overlaySession?.toolbarPanel
            ) else {
                return false
            }
            switch ScreenRecordingActiveExitPolicy.action(after: decision) {
            case .stay:
                return false
            case .discardAndProceed:
                break
            case .stopSaveAndProceed:
                await stopAndReview()
                guard sessionState.state == .reviewing,
                      saveFromReview(quick: false) else {
                    return false
                }
            }
        }
        if sessionState.state == .reviewing,
           !(await resolveReviewExit()) {
            return false
        }
        terminationIntent.beginTermination()
        countdownTask?.cancel()
        countdownTask = nil

        switch engineLifecycle.beginTeardown() {
        case .none:
            if engineLifecycle.state == .tearingDown {
                await waitUntilIdle()
            }
            await cancelAndClose()
        case .waitForStart:
            await waitUntilIdle()
            await cancelAndClose()
        case .stopRecording:
            overlaySession?.update(state: .finalizing)
            if let engine {
                do {
                    _ = try await engine.stop()
                } catch {
                    await engine.cancel()
                }
            }
            engineLifecycle.teardownFinished()
            self.engine = nil
            await cancelAndClose()
            resumeIdleWaiters()
        }
        return true
    }

    private func beginRecording() {
        guard let settings = currentSettings else { return }
        do {
            try sessionState.beginRecording(after: settings.countdownDelay)
        } catch {
            return
        }
        overlaySession?.update(state: sessionState.state)
        if sessionState.state == .starting {
            Task { @MainActor [weak self] in
                await self?.startEngine()
            }
            return
        }
        startCountdown()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                do {
                    let shouldStart = try sessionState.advanceCountdown()
                    overlaySession?.update(state: sessionState.state)
                    if shouldStart {
                        countdownTask = nil
                        await startEngine()
                        return
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        guard case .countingDown = sessionState.state else { return }
        do {
            try sessionState.cancelCountdown()
            overlaySession?.update(state: .ready)
        } catch {
            return
        }
    }

    private func startEngine() async {
        guard sessionState.state == .starting,
              let screen = currentScreen,
              let region = currentRegion,
              let settings = currentSettings else {
            return
        }
        guard engineLifecycle.beginStart() else { return }
        pendingStartFailure = nil

        do {
            if settings.capturesMicrophone {
                guard await requestMicrophonePermission() else {
                    throw ScreenRecordingCoordinatorError.microphonePermissionRequired
                }
                guard sessionState.state == .starting else {
                    finishEngineStartLifecycle()
                    return
                }
            }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard sessionState.state == .starting else {
                finishEngineStartLifecycle()
                return
            }
            guard let displayID = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: {
                      $0.displayID == CGDirectDisplayID(displayID.uint32Value)
                  }) else {
                throw ScreenRecordingCoordinatorError.screenUnavailable
            }
            let scale = max(
                screen.backingScaleFactor,
                CGFloat(display.width) / max(1, screen.frame.width)
            )
            let nativeRegion = try ScreenRecordingGeometry.captureRegion(
                globalRegion: region,
                displayFrame: screen.frame,
                scale: scale
            )
            let options = ScreenRecordingOptions(settings: settings)
            let captureRegion = ScreenRecordingRegion(
                sourceRect: nativeRegion.sourceRect,
                outputSize: options.encodingSize(for: nativeRegion.outputSize)
            )
            let outputURL = makeTemporaryOutputURL(format: settings.format)
            temporaryOutputURL = outputURL
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let engine = ScreenRecordingEngine(
                outputURL: outputURL,
                display: display,
                excludingApplications: ownApplications,
                region: captureRegion,
                options: options
            )
            engine.delegate = self
            self.engine = engine
            try await engine.start()

            guard sessionState.state == .starting, engineLifecycle.startSucceeded() else {
                await engine.cancel()
                self.engine = nil
                removeTemporaryOutput()
                finishEngineStartLifecycle()
                if let pendingStartFailure {
                    throw pendingStartFailure
                }
                return
            }
            try sessionState.recordingDidStart()
            overlaySession?.update(state: .recording)
        } catch {
            let terminationWasWaiting = engineLifecycle.state == .tearingDown
                || terminationIntent.isTerminating
            if let engine {
                await engine.cancel()
            }
            self.engine = nil
            finishEngineStartLifecycle()
            removeTemporaryOutput()
            if !terminationWasWaiting,
               (sessionState.state == .starting
                    || sessionState.state == .recording
                    || sessionState.state == .paused
                    || sessionState.state == .finalizing) {
                try? sessionState.recordingDidFail()
                overlaySession?.restoreReady()
            }
            pendingStartFailure = nil
            resumeIdleWaiters()
            if !terminationWasWaiting {
                errorPresenter.present(.screenRecording(error))
            }
        }
    }

    private func togglePause() {
        guard let engine else { return }
        do {
            switch sessionState.state {
            case .recording:
                try engine.pause()
                try sessionState.pause()
            case .paused:
                try engine.resume()
                try sessionState.resume()
            default:
                return
            }
            overlaySession?.update(state: sessionState.state)
        } catch {
            errorPresenter.present(.screenRecording(error))
        }
    }

    private func stopAndReview() async {
        guard let engine,
              sessionState.state == .recording || sessionState.state == .paused else {
            return
        }
        guard engineLifecycle.beginTeardown() == .stopRecording else { return }
        do {
            try sessionState.beginFinalizing()
            overlaySession?.update(state: .finalizing)
            let outputURL = try await engine.stop()
            engineLifecycle.teardownFinished()
            self.engine = nil
            switch terminationIntent.completionAction(didStopSuccessfully: true) {
            case .presentReview:
                try sessionState.recordingDidFinish()
                overlaySession?.hideForReview()
                presentReview(outputURL: outputURL)
            case .finishTermination:
                break
            case .restoreReady:
                assertionFailure("A successful stop cannot request ready recovery")
            }
            resumeIdleWaiters()
        } catch {
            await engine.cancel()
            engineLifecycle.teardownFinished()
            self.engine = nil
            removeTemporaryOutput()
            switch terminationIntent.completionAction(didStopSuccessfully: false) {
            case .restoreReady:
                try? sessionState.recordingDidFail()
                overlaySession?.restoreReady()
            case .finishTermination:
                break
            case .presentReview:
                assertionFailure("A failed stop cannot request review")
            }
            resumeIdleWaiters()
            if !terminationIntent.isTerminating {
                errorPresenter.present(.screenRecording(error))
            }
        }
    }

    private func presentReview(outputURL: URL) {
        guard let settings = currentSettings else { return }
        let review = ScreenRecordingReviewSession(outputURL: outputURL, format: settings.format)
        review.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .playPause:
                break
            case .save:
                _ = saveFromReview(quick: false)
            case .quickSave:
                _ = saveFromReview(quick: true)
            case .copy:
                copyReviewFile()
            case .restart:
                Task { @MainActor [weak self] in
                    await self?.exitReview(to: .restart)
                }
            case .close:
                Task { @MainActor [weak self] in
                    await self?.exitReview(to: .close)
                }
            }
        }
        reviewSession = review
        reviewArtifactState.beginReview()
        review.present()
    }

    @discardableResult
    private func saveFromReview(quick: Bool) -> Bool {
        guard sessionState.state == .reviewing,
              let source = temporaryOutputURL,
              let settings = currentSettings else {
            return false
        }
        do {
            let destination: URL
            let action: RecordingReviewSaveAction = quick ? .quickSave : .save
            switch RecordingReviewDestinationPolicy.mode(
                for: action,
                asksForSaveLocation: settings.asksForSaveLocation
            ) {
            case .defaultDirectory:
                destination = try RecordingDestinationPolicy.availableURL(
                    directory: settingsStore.resolvedSaveDirectory(),
                    suggestedFilename: RecordingDestinationPolicy.suggestedFilename(format: settings.format)
                )
            case .prompt:
                guard let selected = chooseReviewDestination(format: settings.format) else {
                    return false
                }
                destination = selected
            }
            try copyRecording(from: source, to: destination)
            reviewArtifactState.markPersisted()
            if RecordingReviewDestinationPolicy.revealsInFinder(after: action) {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
            return true
        } catch {
            // The review window and temporary source stay alive, so Save can be retried.
            errorPresenter.present(.screenRecording(error))
            return false
        }
    }

    private func copyReviewFile() {
        guard sessionState.state == .reviewing,
              let outputURL = temporaryOutputURL,
              let settings = currentSettings else {
            return
        }
        do {
            let persistentURL = try reviewArtifactStore.persistForClipboard(
                sourceURL: outputURL,
                directory: settingsStore.resolvedSaveDirectory(),
                format: settings.format
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.writeObjects([persistentURL as NSURL]) else {
                throw ScreenRecordingCoordinatorError.copyFailed
            }
            reviewArtifactState.markPersisted()
        } catch {
            errorPresenter.present(.screenRecording(error))
        }
    }

    private enum ReviewExitDestination {
        case restart
        case close
    }

    private func requestCloseFromOverlay() async {
        switch sessionState.state {
        case .ready, .countingDown:
            await cancelAndClose()
        case .recording, .paused:
            guard let decision = await requestDiscardDecision(
                attachedTo: overlaySession?.toolbarPanel
            ) else {
                return
            }
            switch ScreenRecordingActiveExitPolicy.action(after: decision) {
            case .stay:
                return
            case .discardAndProceed:
                await cancelAndClose()
            case .stopSaveAndProceed:
                await stopAndReview()
                guard sessionState.state == .reviewing,
                      saveFromReview(quick: false) else {
                    return
                }
                await cancelAndClose()
            }
        case .idle:
            return
        case .starting, .finalizing, .reviewing:
            return
        }
    }

    private func exitReview(to destination: ReviewExitDestination) async {
        guard sessionState.state == .reviewing,
              await resolveReviewExit() else {
            return
        }
        switch destination {
        case .restart:
            restartFromReview()
        case .close:
            await cancelAndClose()
        }
    }

    private func resolveReviewExit() async -> Bool {
        switch reviewArtifactState.exitAction() {
        case .proceed:
            return true
        case .requestConfirmation:
            break
        case .saveThenProceed, .stay:
            assertionFailure("A review exit needs a confirmation decision first")
            return false
        }
        guard let decision = await requestDiscardDecision(
            attachedTo: reviewSession?.panel
        ) else {
            return false
        }
        guard sessionState.state == .reviewing else { return false }
        switch reviewArtifactState.exitAction(after: decision) {
        case .saveThenProceed:
            return saveFromReview(quick: false)
        case .proceed:
            return true
        case .stay:
            return false
        case .requestConfirmation:
            assertionFailure("A supplied decision cannot request another confirmation")
            return false
        }
    }

    private func requestDiscardDecision(
        attachedTo window: NSWindow?
    ) async -> ScreenRecordingReviewDiscardDecision? {
        guard !isResolvingReviewExit else { return nil }
        isResolvingReviewExit = true
        defer { isResolvingReviewExit = false }
        return await confirmReviewDiscard(window)
    }

    private func restartFromReview() {
        guard sessionState.state == .reviewing else { return }
        reviewSession?.close()
        reviewSession = nil
        removeTemporaryOutput()
        do {
            try sessionState.restart()
            overlaySession?.restoreReady()
        } catch {
            errorPresenter.present(.screenRecording(error))
        }
    }

    private func cancelAndClose() async {
        countdownTask?.cancel()
        countdownTask = nil
        if let engine {
            if engineLifecycle.state == .recording {
                _ = engineLifecycle.beginTeardown()
            }
            await engine.cancel()
            self.engine = nil
            if engineLifecycle.state == .tearingDown {
                engineLifecycle.teardownFinished()
            } else if engineLifecycle.state == .starting {
                engineLifecycle.startFailed()
            }
        }
        reviewSession?.close()
        overlaySession?.close()
        reviewSession = nil
        overlaySession = nil
        currentRegion = nil
        currentScreen = nil
        currentSettings = nil
        removeTemporaryOutput()
        reviewArtifactState = ScreenRecordingReviewArtifactState()
        sessionState.close()
        pendingStartFailure = nil
        resumeIdleWaiters()
    }

    private func chooseReviewDestination(format: ScreenRecordingFormat) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = settingsStore.resolvedSaveDirectory()
        panel.nameFieldStringValue = RecordingDestinationPolicy.suggestedFilename(format: format)
        panel.message = "保存录屏 \(format.displayName)"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func copyRecording(from source: URL, to destination: URL) throws {
        try fileInstaller.install(source: source, at: destination)
    }

    private func makeTemporaryOutputURL(format: ScreenRecordingFormat) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("PolyglanceRecording-\(UUID().uuidString)")
            .appendingPathExtension(format.fileExtension)
    }

    private func removeTemporaryOutput() {
        guard let temporaryOutputURL else { return }
        try? fileManager.removeItem(at: temporaryOutputURL)
        self.temporaryOutputURL = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func screen(containing region: CGRect) -> NSScreen? {
        let center = CGPoint(x: region.midX, y: region.midY)
        if let directMatch = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return directMatch
        }
        return NSScreen.screens.max { left, right in
            left.frame.intersection(region).area < right.frame.intersection(region).area
        }
    }

    private func waitUntilIdle() async {
        guard engineLifecycle.state != .idle else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func finishEngineStartLifecycle() {
        switch engineLifecycle.state {
        case .idle:
            break
        case .starting:
            engineLifecycle.startFailed()
        case .recording:
            _ = engineLifecycle.beginTeardown()
            engineLifecycle.teardownFinished()
        case .tearingDown:
            engineLifecycle.teardownFinished()
        }
        resumeIdleWaiters()
    }

    private func resumeIdleWaiters() {
        guard engineLifecycle.state == .idle else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

}

extension ScreenRecordingCoordinator: ScreenRecordingEngineDelegate {
    nonisolated func screenRecordingEngine(_ engine: ScreenRecordingEngine, didFail error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.engine === engine else { return }
            switch engineLifecycle.beginTeardown() {
            case .none:
                return
            case .waitForStart:
                pendingStartFailure = error
            case .stopRecording:
                overlaySession?.update(state: .finalizing)
                await engine.cancel()
                engineLifecycle.teardownFinished()
                self.engine = nil
                removeTemporaryOutput()
                if !terminationIntent.isTerminating {
                    try? sessionState.recordingDidFail()
                    overlaySession?.restoreReady()
                }
                resumeIdleWaiters()
                if !terminationIntent.isTerminating {
                    errorPresenter.present(.screenRecording(error))
                }
            }
        }
    }

    nonisolated func screenRecordingEngineDidReachLimit(_ engine: ScreenRecordingEngine) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.engine === engine,
                  sessionState.state == .recording else {
                return
            }
            await stopAndReview()
        }
    }
}

private enum ScreenRecordingCoordinatorError: LocalizedError {
    case alreadyRecording
    case permissionRequired(restartRequired: Bool)
    case microphonePermissionRequired
    case screenUnavailable
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "已有录屏任务正在运行"
        case let .permissionRequired(restartRequired):
            return restartRequired
                ? "已请求屏幕录制权限，请授权后重新启动 Polyglance"
                : "录屏需要在系统设置的“隐私与安全性”中授权屏幕录制权限"
        case .microphonePermissionRequired:
            return "请在系统设置的“隐私与安全性”中授权麦克风权限"
        case .screenUnavailable:
            return "无法识别框选区域所在的显示器"
        case .copyFailed:
            return "无法将录屏文件复制到剪贴板"
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
