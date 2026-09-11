import AppKit
import CoreGraphics
import PolyglanceKit
import ScreenCaptureKit

enum ScreenshotCapturePolicy {
    enum CaptureBackend: Equatable {
        case screenshotConfiguration
        case streamConfiguration
    }

    // The selection overlay is created only after this base image is captured,
    // so including our existing windows is safe and lets users capture the
    // translator/result panels themselves.
    static let includesCurrentApplicationWindows = true

    static func captureBackend(macOSMajorVersion: Int) -> CaptureBackend {
        macOSMajorVersion >= 26 ? .screenshotConfiguration : .streamConfiguration
    }

    static func makeScreenshotConfiguration(pixelSize: CGSize) -> NSObject? {
        guard let configClass = NSClassFromString("SCScreenshotConfiguration") as? NSObject.Type else {
            return nil
        }
        let configuration = configClass.init()
        configuration.setValue(Int(pixelSize.width), forKey: "width")
        configuration.setValue(Int(pixelSize.height), forKey: "height")
        configuration.setValue(false, forKey: "showsCursor")
        configuration.setValue(false, forKey: "ignoreShadows")
        configuration.setValue(false, forKey: "ignoreClipping")
        configuration.setValue(0, forKey: "dynamicRange")
        return configuration
    }

    static func usesVirtualDesktop(
        screenCount: Int,
        preferredAction: ScreenshotPreferredAction?
    ) -> Bool {
        guard screenCount > 1 else {
            return false
        }
        switch preferredAction {
        case .longScreenshot, .screenRecording:
            // These modes hand the selected rectangle to display-bound capture
            // engines. Standard screenshots, OCR and screenshot translation can
            // consume the composed virtual-desktop bitmap directly.
            return false
        case .screenshotAndCopy, .screenTranslation, .ocrTranslate, .ocrWorkspace, .ocrTranslationCard, .none:
            return true
        }
    }

    /// A pin replaces the selected pixels in place, so the overlay must stay up
    /// until the pin window has drawn its first frame. Tearing it down in the
    /// same run loop turn exposes one frame of the untouched desktop, which
    /// reads as the pin flashing in from the clipboard.
    static func keepsOverlayUntilHandoff(for action: ScreenshotSelectionAction?) -> Bool {
        if case .pin = action {
            return true
        }
        if case .detectBarcode = action {
            return true
        }
        if case .ocrCopy = action {
            return true
        }
        return false
    }
}

@MainActor
final class ScreenshotCoordinator {
    private let pinWindowManager: PinWindowManager
    private let fileSaver: ScreenshotFileSaver
    private let ocrService: OCRService
    private let barcodeService: BarcodeService
    private let onBeginOCRTranslate: @MainActor (SelectedScreenshot) -> Void
    private let onOCRTranslate: @MainActor (SelectedScreenshot, String) async throws -> Void
    private let onOCRTranslationCard: @MainActor (SelectedScreenshot, String) async throws -> Void
    private let onLongScreenshot: @MainActor (CGRect) async throws -> Void
    private let onScreenRecording: @MainActor (CGRect) async throws -> Void
    private let onScreenTranslate: @MainActor (ScreenTranslationSelection) async throws -> Void
    private let configurationStore: AppConfigurationStore
    private var selectionSession: ScreenSelectionSession?
    private let barcodeResultWindows = BarcodeResultWindowStore()
    private var activeOCRWorkspacePanel: OCRWorkspacePanel?
    private var isCapturing = false

    init(
        pinWindowManager: PinWindowManager,
        configurationStore: AppConfigurationStore = AppConfigurationStore(),
        ocrService: OCRService = OCRService(),
        barcodeService: BarcodeService = BarcodeService(),
        onBeginOCRTranslate: @escaping @MainActor (SelectedScreenshot) -> Void = { _ in },
        onOCRTranslate: @escaping @MainActor (SelectedScreenshot, String) async throws -> Void = { _, _ in },
        onOCRTranslationCard: @escaping @MainActor (SelectedScreenshot, String) async throws -> Void = { _, _ in },
        onLongScreenshot: @escaping @MainActor (CGRect) async throws -> Void = { _ in },
        onScreenRecording: @escaping @MainActor (CGRect) async throws -> Void = { _ in },
        onScreenTranslate: @escaping @MainActor (ScreenTranslationSelection) async throws -> Void = { _ in }
    ) {
        self.pinWindowManager = pinWindowManager
        self.configurationStore = configurationStore
        fileSaver = ScreenshotFileSaver()
        self.ocrService = ocrService
        self.barcodeService = barcodeService
        self.onBeginOCRTranslate = onBeginOCRTranslate
        self.onOCRTranslate = onOCRTranslate
        self.onOCRTranslationCard = onOCRTranslationCard
        self.onLongScreenshot = onLongScreenshot
        self.onScreenRecording = onScreenRecording
        self.onScreenTranslate = onScreenTranslate
    }

    init(pinWindowManager: PinWindowManager, fileSaver: ScreenshotFileSaver) {
        self.pinWindowManager = pinWindowManager
        self.fileSaver = fileSaver
        configurationStore = AppConfigurationStore()
        ocrService = OCRService()
        barcodeService = BarcodeService()
        onBeginOCRTranslate = { _ in }
        onOCRTranslate = { _, _ in }
        onOCRTranslationCard = { _, _ in }
        onLongScreenshot = { _ in }
        onScreenRecording = { _ in }
        onScreenTranslate = { _ in }
    }

    func captureAndPin(
        preferredAction: ScreenshotPreferredAction? = nil,
        triggerTime: CFAbsoluteTime? = nil
    ) async throws {
        let startTime = triggerTime ?? CFAbsoluteTimeGetCurrent()
        guard selectionSession == nil, !isCapturing else {
            return
        }
        isCapturing = true
        var keepsOverlayUntilHandoff = false
        defer {
            let session = selectionSession
            if keepsOverlayUntilHandoff {
                DispatchQueue.main.async { session?.dismiss() }
            } else {
                session?.dismiss()
            }
            selectionSession = nil
            isCapturing = false
            Self.prewarm()
        }
        guard let action = try await captureSelectionAction(
            preferredAction: preferredAction,
            startTime: startTime
        ) else {
            return
        }
        keepsOverlayUntilHandoff = ScreenshotCapturePolicy
            .keepsOverlayUntilHandoff(for: action)
        switch action {
        case let .copy(result):
            try ImagePasteboard.write(result.image)
            if (try? configurationStore.load())?.saveCompletedScreenshotsToHistory == true {
                pinWindowManager.archiveStore.record(image: result.image, source: .screenshot)
            }
        case let .save(result):
            let saved = try fileSaver.save(result.image)
            if saved, (try? configurationStore.load())?.saveCompletedScreenshotsToHistory == true {
                pinWindowManager.archiveStore.record(image: result.image, source: .screenshot)
            }
        case let .pin(result):
            pinWindowManager.pin(
                result.image,
                sourceFrame: result.screenFrame,
                preferredDisplaySize: result.screenFrame.size
            )
        case let .ocrCopy(result):
            if let activeContinuous = OCRWorkspacePanel.activeContinuousInstance, activeContinuous.isVisible {
                activeContinuous.startPendingAppend(image: result.image)
                activeContinuous.orderFrontRegardless()
                activeContinuous.makeKey()
                Task {
                    do {
                        let document = try await ocrService.recognizeDocument(in: result.image)
                        await MainActor.run {
                            activeContinuous.finishPendingAppend(image: result.image, document: document)
                        }
                    } catch {
                        await MainActor.run {
                            activeContinuous.cancelPendingAppend(error: error)
                        }
                    }
                }
                break
            }

            let panel = OCRWorkspacePanel(
                image: result.image,
                document: nil,
                configurationStore: configurationStore,
                translateHandler: { [weak self] text in
                    guard let self else { return }
                    Task { @MainActor in
                        do {
                            try await self.onOCRTranslate(result, text)
                        } catch {
                            OperationErrorPresenter().present(.screenshot(error))
                        }
                    }
                }
            )
            activeOCRWorkspacePanel = panel
            panel.center()
            panel.orderFrontRegardless()
            panel.makeKey()

            Task {
                do {
                    let document = try await ocrService.recognizeDocument(in: result.image)
                    await MainActor.run {
                        panel.setDocument(document)
                        let config = try? configurationStore.load()
                        if config?.ocrAutoCopyNextTime == true {
                            let mode = TextFormattingMode(rawValue: config?.ocrDefaultFormatting ?? 0) ?? .smartMerge
                            let lines = document.lines.map { (text: $0.text, boundingBox: $0.boundingBox) }
                            let cleaned = TextFormattingService.format(lines: lines, mode: mode)
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(cleaned, forType: .string)
                            NSSound(named: "Tink")?.play()
                        }
                    }
                } catch {
                    await MainActor.run {
                        panel.setError(error.localizedDescription)
                    }
                }
            }
        case let .ocrCopyAll(result):
            let text = try await ocrService.recognizeText(in: result.image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw ScreenshotError.ocrCopyFailed
            }
        case let .ocrTranslate(result):
            onBeginOCRTranslate(result)
            let text = try await ocrService.recognizeText(in: result.image)
            try await onOCRTranslate(result, text)
        case let .ocrTranslationCard(result):
            let text = try await ocrService.recognizeText(in: result.image)
            try await onOCRTranslationCard(result, text)
        case let .detectBarcode(result):
            let observations: [BarcodeObservation]
            do {
                observations = try await barcodeService.recognizeBarcodes(in: result.image)
            } catch BarcodeError.notFound {
                throw ScreenshotError.barcodeNotFound
            } catch BarcodeError.invalidImage {
                throw ScreenshotError.barcodeDetectionFailed("无法从图像中读取有效像素")
            } catch let BarcodeError.recognitionFailed(message) {
                throw ScreenshotError.barcodeDetectionFailed(message)
            }
            let window = BarcodeResultWindow(
                observations: observations,
                image: result.image,
                screenFrame: result.screenFrame
            )
            barcodeResultWindows.retain(window)
            window.orderFrontRegardless()
            window.makeKey()
            // Force the first frame into the backing store before the deferred
            // teardown removes the overlay covering these pixels.
            window.display()
        case let .longScreenshot(result):
            try await onLongScreenshot(result.screenFrame)
        case let .screenRecording(result):
            try await onScreenRecording(result.screenFrame)
        case let .screenTranslation(result):
            try await onScreenTranslate(result)
        }
    }

    /// Owns only the on-screen selection phase. Returning the action before
    /// OCR, translation, long-capture, or recording setup begins prevents an
    /// older post-processing task from releasing a newer selection session.
    private func captureSelectionAction(
        preferredAction: ScreenshotPreferredAction?,
        startTime: CFAbsoluteTime? = nil
    ) async throws -> ScreenshotSelectionAction? {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ScreenshotError.permissionRequired(restartRequired: false)
        }
        guard let screen = screenUnderPointer() else {
            throw ScreenshotError.screenUnavailable
        }

        if ScreenshotCapturePolicy.usesVirtualDesktop(
            screenCount: NSScreen.screens.count,
            preferredAction: preferredAction
        ) {
            let screens = NSScreen.screens
            let displays = try await Self.fetchDisplays(screens: screens)
            let segments: [VirtualDesktopCapture.Segment] = try await withThrowingTaskGroup(
                of: (Int, VirtualDesktopCapture.Segment).self
            ) { group in
                for (index, candidate) in screens.enumerated() {
                    guard let displayID = candidate.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
                          let display = displays.first(where: {
                              $0.displayID == CGDirectDisplayID(displayID.uint32Value)
                          }) else {
                        throw ScreenshotError.screenUnavailable
                    }
                    let pointSize = candidate.frame.size
                    let scale = candidate.backingScaleFactor
                    let frame = candidate.frame
                    group.addTask {
                        let img = try await Self.captureDisplay(
                            display: display,
                            screenPointSize: pointSize,
                            backingScaleFactor: scale
                        )
                        return (index, VirtualDesktopCapture.Segment(
                            image: img,
                            frame: frame,
                            backingScaleFactor: scale
                        ))
                    }
                }
                var results: [(Int, VirtualDesktopCapture.Segment)] = []
                for try await item in group {
                    results.append(item)
                }
                results.sort(by: { $0.0 < $1.0 })
                return results.map(\.1)
            }
            guard let desktop = VirtualDesktopCapture.compose(segments) else {
                throw ScreenshotError.screenUnavailable
            }
            let detector = VirtualDesktopRegionDetector(
                captureFrame: desktop.frame,
                entries: screens.compactMap { candidate in
                    ScreenshotRegionDetector.capture(for: candidate).map {
                        VirtualDesktopRegionDetector.Entry(frame: candidate.frame, detector: $0)
                    }
                }
            )
            let toolbarItems = (try? configurationStore.load())?.screenshotToolbarItems
                ?? ScreenshotToolbarItemConfig.defaultItems
            let session = ScreenSelectionSession(
                image: desktop.image,
                screen: screen,
                captureFrame: desktop.frame,
                inactiveScreenFrames: [],
                regionProvider: { point in detector.windowRegion(at: point) },
                regionRefiner: { point in detector.refinedElementRegion(at: point) },
                preferredAction: preferredAction,
                toolbarItems: toolbarItems,
                startTime: startTime
            )
            selectionSession = session
            return await withCheckedContinuation { continuation in
                session.present { result in
                    continuation.resume(returning: result)
                }
            }
        }

        let toolbarItems = (try? configurationStore.load())?.screenshotToolbarItems
            ?? ScreenshotToolbarItemConfig.defaultItems
        let image = try await capture(screen: screen)
        let regionDetector = ScreenshotRegionDetector.capture(for: screen)
        let regionProvider: ScreenshotRegionProvider? = regionDetector.map { detector in
            { point in detector.windowRegion(at: point) }
        }
        let regionRefiner: ScreenshotRegionRefiner?
        if let regionDetector {
            regionRefiner = { point in
                regionDetector.refinedElementRegion(at: point)
            }
        } else {
            regionRefiner = nil
        }
        let session = ScreenSelectionSession(
            image: image,
            screen: screen,
            regionProvider: regionProvider,
            regionRefiner: regionRefiner,
            preferredAction: preferredAction,
            toolbarItems: toolbarItems,
            startTime: startTime
        )
        selectionSession = session
        let action = await withCheckedContinuation { continuation in
            session.present { result in
                continuation.resume(returning: result)
            }
        }
        return action
    }

    func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
    }

    var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private static var cachedDisplays: [SCDisplay] = []

    private static func fetchDisplays(screens: [NSScreen]) async throws -> [SCDisplay] {
        if !cachedDisplays.isEmpty {
            let cachedIDs = Set(cachedDisplays.map(\.displayID))
            let requiredIDs = screens.compactMap { s -> CGDirectDisplayID? in
                (s.deviceDescription[.init("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            }
            if !requiredIDs.isEmpty && requiredIDs.allSatisfy({ cachedIDs.contains($0) }) {
                return cachedDisplays
            }
        }
        return try await refreshDisplays()
    }

    @discardableResult
    private static func refreshDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        cachedDisplays = content.displays
        return content.displays
    }

    private func capture(screen: NSScreen) async throws -> CGImage {
        let displays = try await Self.fetchDisplays(screens: [screen])
        guard let displayID = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let display = displays.first(where: {
                  $0.displayID == CGDirectDisplayID(displayID.uint32Value)
              }) else {
            throw ScreenshotError.screenUnavailable
        }
        return try await Self.captureDisplay(
            display: display,
            screenPointSize: screen.frame.size,
            backingScaleFactor: screen.backingScaleFactor
        )
    }

    private static func captureDisplay(
        display: SCDisplay,
        screenPointSize: CGSize,
        backingScaleFactor: CGFloat
    ) async throws -> CGImage {
        let excludedApplications = ScreenshotCapturePolicy.includesCurrentApplicationWindows
            ? []
            : (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let captureSize = CaptureGeometry.preferredCapturePixelSize(
            screenPointSize: screenPointSize,
            backingScaleFactor: backingScaleFactor,
            reportedPixelSize: CGSize(width: display.width, height: display.height)
        )
        do {
            if ScreenshotCapturePolicy.captureBackend(
                macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            ) == .screenshotConfiguration,
               let configuration = ScreenshotCapturePolicy.makeScreenshotConfiguration(pixelSize: captureSize),
               let managerClass = NSClassFromString("SCScreenshotManager") {
                let selector = NSSelectorFromString("captureScreenshotWithFilter:configuration:completionHandler:")
                if managerClass.responds(to: selector) {
                    let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
                        typealias Completion = @convention(block) (AnyObject?, Error?) -> Void
                        let block: Completion = { output, error in
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let output else {
                                continuation.resume(returning: nil)
                                return
                            }
                            let sel = NSSelectorFromString("sdrImage")
                            if output.responds(to: sel), let unmanaged = output.perform(sel) {
                                let img = unmanaged.takeUnretainedValue() as! CGImage
                                continuation.resume(returning: img)
                            } else {
                                continuation.resume(returning: nil)
                            }
                        }
                        typealias Method = @convention(c) (AnyObject, Selector, SCContentFilter, AnyObject, AnyObject) -> Void
                        let imp = managerClass.method(for: selector)
                        let fn = unsafeBitCast(imp, to: Method.self)
                        fn(managerClass, selector, filter, configuration, unsafeBitCast(block, to: AnyObject.self))
                    }
                    if let image {
                        return image
                    }
                }
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(captureSize.width)
            configuration.height = Int(captureSize.height)
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.backgroundColor = .black
            configuration.ignoreShadowsDisplay = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenshotError.captureFailed(error.localizedDescription)
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    static func prewarm() {
        Task.detached(priority: .userInitiated) {
            guard CGPreflightScreenCaptureAccess() else { return }
            _ = try? await refreshDisplays()
        }
    }
}

enum ScreenshotPreferredAction {
    case screenshotAndCopy
    case longScreenshot
    case screenRecording
    case screenTranslation
    case ocrTranslate
    case ocrWorkspace
    case ocrTranslationCard
}

enum ScreenshotError: LocalizedError {
    case permissionRequired(restartRequired: Bool)
    case screenUnavailable
    case captureFailed(String)
    case ocrSelectionPresentationFailed
    case ocrCopyFailed
    case noTextFound
    case barcodeDetectionFailed(String)
    case barcodeNotFound
    case barcodeResultNotPresentable

    var errorDescription: String? {
        switch self {
        case let .permissionRequired(restartRequired):
            return restartRequired
                ? "已请求屏幕录制权限，请授权后重新启动 Polyglance"
                : "截图需要屏幕录制权限，请在系统设置的“隐私与安全性”中授权"
        case .screenUnavailable:
            return "无法识别鼠标所在的显示器"
        case let .captureFailed(message):
            return "截图失败：\(message)"
        case .ocrSelectionPresentationFailed:
            return "无法打开 OCR 文字选择窗口"
        case .ocrCopyFailed:
            return "无法将 OCR 文字写入剪贴板"
        case .noTextFound:
            return "当前截图中没有识别到文字"
        case let .barcodeDetectionFailed(message):
            return "条码识别失败：\(message)"
        case .barcodeNotFound:
            return "选区内未识别到二维码或条码"
        case .barcodeResultNotPresentable:
            return "无法显示条码识别结果"
        }
    }
}
