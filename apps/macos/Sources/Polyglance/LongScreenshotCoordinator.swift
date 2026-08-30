import AppKit

enum LongScreenshotOutputAction: Equatable {
    case copy
    case save
    case pin
}

@MainActor
struct LongScreenshotOutputActions {
    typealias Copy = @MainActor (NSImage) throws -> Void
    typealias Save = @MainActor (NSImage) throws -> Void
    typealias Pin = @MainActor (NSImage, CGRect) throws -> Void

    let copy: Copy
    let save: Save
    let pin: Pin

    static let discarding = Self(
        copy: { _ in },
        save: { _ in },
        pin: { _, _ in }
    )

    static func live(pinWindowManager: PinWindowManager) -> Self {
        live(pinWindowManager: pinWindowManager, fileSaver: ScreenshotFileSaver())
    }

    static func live(
        pinWindowManager: PinWindowManager,
        fileSaver: ScreenshotFileSaver
    ) -> Self {
        Self(
            copy: { try ImagePasteboard.write($0) },
            save: { _ = try fileSaver.save($0) },
            pin: { image, sourceFrame in
                pinWindowManager.pin(image, sourceFrame: sourceFrame)
            }
        )
    }
}

enum LongScreenshotCoordinatorError: LocalizedError, Equatable {
    case sessionAlreadyActive
    case invalidSelection
    case noCompletedImage

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive:
            return "已有长截图任务正在进行"
        case .invalidSelection:
            return "长截图选区无效"
        case .noCompletedImage:
            return "长截图尚未完成"
        }
    }
}

@MainActor
final class LongScreenshotCoordinator {
    typealias SchedulerFactory = @MainActor () -> any LongScreenshotScheduling
    typealias PresentError = @MainActor (Error) -> Void

    private let captureSource: any LongScreenshotFrameCapturing
    private let configuration: LongScreenshotConfiguration
    private let schedulerFactory: SchedulerFactory
    private let outputActions: LongScreenshotOutputActions
    private let presentsControlPanel: Bool
    private let presentError: PresentError

    private var session: LongScreenshotSession?
    private var activeRegion: LongScreenshotCaptureRegion?
    private var controlPanel: LongScreenshotControlPanel?
    private var regionOverlayPanel: LongScreenshotRegionOverlayPanel?
    private var previewPanel: LongScreenshotPreviewPanel?
    private(set) var controlView: LongScreenshotControlView?
    private(set) var outputImage: NSImage?

    var onFinished: ((NSImage) -> Void)?
    var onCancelled: (() -> Void)?

    convenience init(
        pinWindowManager: PinWindowManager,
        configuration: LongScreenshotConfiguration = .default
    ) {
        self.init(
            pinWindowManager: pinWindowManager,
            captureSource: ScreenCaptureKitLongScreenshotCapturer(),
            configuration: configuration
        )
    }

    convenience init(
        pinWindowManager: PinWindowManager,
        captureSource: any LongScreenshotFrameCapturing,
        configuration: LongScreenshotConfiguration = .default
    ) {
        self.init(
            captureSource: captureSource,
            configuration: configuration,
            schedulerFactory: { LongScreenshotTaskScheduler() },
            outputActions: .live(pinWindowManager: pinWindowManager),
            presentsControlPanel: true
        )
    }

    init(
        captureSource: any LongScreenshotFrameCapturing,
        configuration: LongScreenshotConfiguration,
        schedulerFactory: @escaping SchedulerFactory,
        outputActions: LongScreenshotOutputActions,
        presentsControlPanel: Bool,
        presentError: @escaping PresentError = LongScreenshotCoordinator.defaultErrorPresenter
    ) {
        self.captureSource = captureSource
        self.configuration = configuration
        self.schedulerFactory = schedulerFactory
        self.outputActions = outputActions
        self.presentsControlPanel = presentsControlPanel
        self.presentError = presentError
    }

    func begin(
        selection: CGRect,
        on screen: NSScreen,
        completion: ((NSImage) -> Void)? = nil
    ) throws {
        guard let region = LongScreenshotCaptureRegion.make(selection: selection, on: screen) else {
            throw LongScreenshotCoordinatorError.invalidSelection
        }
        if let completion {
            onFinished = completion
        }
        try begin(region: region)
    }

    func begin(region: LongScreenshotCaptureRegion) throws {
        guard session == nil else {
            throw LongScreenshotCoordinatorError.sessionAlreadyActive
        }
        outputImage = nil
        activeRegion = region

        let controls = LongScreenshotControlView()
        controlView = controls
        controls.onAction = { [weak self] action in
            self?.handle(action)
        }
        if presentsControlPanel {
            let regionPanel = LongScreenshotRegionOverlayPanel(region: region.globalRect)
            regionOverlayPanel = regionPanel
            regionPanel.overlayView.onRegionChanged = { [weak self] globalRect in
                self?.updateReadyRegion(to: globalRect)
            }
            regionPanel.present()
            let panel = LongScreenshotControlPanel(controls: controls)
            controlPanel = panel
            panel.present(near: region.globalRect)
            let previewPanel = LongScreenshotPreviewPanel()
            self.previewPanel = previewPanel
            previewPanel.update(for: .ready, near: region.globalRect)
        }

        let session = LongScreenshotSession(
            region: region,
            captureSource: captureSource,
            scheduler: schedulerFactory(),
            configuration: configuration
        )
        self.session = session
        session.onStateChanged = { [weak self, weak controls] state in
            controls?.update(for: state)
            self?.regionOverlayPanel?.update(for: state)
            if let region = self?.activeRegion?.globalRect {
                self?.previewPanel?.update(for: state, near: region)
            }
        }
        session.onPreviewChanged = { [weak self] preview in
            guard let self, let region = activeRegion?.globalRect else { return }
            controlView?.setHasCapturedFrame(true)
            previewPanel?.update(preview: preview, near: region)
        }
        session.onRecoverableFrameError = { [weak self] _ in
            self?.regionOverlayPanel?.overlayView.flagSkippedFrame()
        }
        session.onFinished = { [weak self, weak controls] image in
            self?.outputImage = image
            controls?.update(for: .finished)
            self?.regionOverlayPanel?.update(for: .finished)
            self?.onFinished?(image)
        }
        session.onCancelled = { [weak self] in
            self?.tearDown(keepOutput: false)
            self?.onCancelled?()
        }
        session.onFailed = { [weak self] error in
            self?.presentError(error)
            self?.tearDown(keepOutput: false)
        }
        Task { @MainActor [weak self, weak session] in
            guard self?.session === session else { return }
            await session?.start()
        }
    }

    func startCapture() async {
        await session?.start()
    }

    func pauseOrResumeCapture() {
        guard let session else {
            return
        }
        if session.state == .capturing {
            session.pause()
        } else if session.state == .paused {
            session.resume()
        }
    }

    func finishCapture() {
        do {
            _ = try session?.finish()
        } catch {
            presentError(error)
        }
    }

    func cancelCapture() {
        guard let session else {
            return
        }
        if session.state == .finished {
            tearDown(keepOutput: true)
        } else {
            session.cancel()
        }
    }

    func performOutput(_ action: LongScreenshotOutputAction) throws {
        guard let outputImage, let activeRegion else {
            throw LongScreenshotCoordinatorError.noCompletedImage
        }
        switch action {
        case .copy:
            try outputActions.copy(outputImage)
        case .save:
            try outputActions.save(outputImage)
        case .pin:
            try outputActions.pin(outputImage, activeRegion.globalRect)
        }
    }

    private func handle(_ action: LongScreenshotControlAction) {
        switch action {
        case .cancel:
            cancelCapture()
        case .copy:
            performOutputFromControl(.copy)
        case .pin:
            performOutputFromControl(.pin)
        }
    }

    private func performOutputFromControl(_ action: LongScreenshotOutputAction) {
        do {
            if outputImage == nil {
                guard let session else {
                    throw LongScreenshotCoordinatorError.noCompletedImage
                }
                _ = try session.finish()
            }
            try performOutput(action)
            tearDown(keepOutput: true)
        } catch {
            presentError(error)
        }
    }

    private func tearDown(keepOutput: Bool) {
        controlPanel?.orderOut(nil)
        controlPanel = nil
        regionOverlayPanel?.orderOut(nil)
        regionOverlayPanel = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        controlView = nil
        session = nil
        if !keepOutput {
            outputImage = nil
            activeRegion = nil
        }
    }

    private func updateReadyRegion(to globalRect: CGRect) {
        guard let activeRegion,
              let screen = NSScreen.screens.first(where: { screen in
                  guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
                      return false
                  }
                  return CGDirectDisplayID(number.uint32Value) == activeRegion.displayID
              }),
              let updated = LongScreenshotCaptureRegion.make(selection: globalRect, on: screen),
              session?.updateRegion(updated) == true else {
            return
        }
        self.activeRegion = updated
        controlPanel?.present(near: updated.globalRect)
        previewPanel?.update(for: session?.state ?? .ready, near: updated.globalRect)
    }

    private static func defaultErrorPresenter(_ error: Error) {
        OperationErrorPresenter().present(.screenshot(error))
    }
}
