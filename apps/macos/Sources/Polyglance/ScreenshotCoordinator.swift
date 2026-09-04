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

    @available(macOS 26.0, *)
    static func makeScreenshotConfiguration(pixelSize: CGSize) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false
        configuration.ignoreShadows = false
        configuration.ignoreClipping = false
        configuration.dynamicRange = .sdr
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
        case .screenTranslation, .none:
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
        return false
    }
}

@MainActor
final class ScreenshotCoordinator {
    private let pinWindowManager: PinWindowManager
    private let fileSaver: ScreenshotFileSaver
    private let ocrService: OCRService
    private let barcodeService: BarcodeService
    private let onOCRTranslate: @MainActor (SelectedScreenshot, String) async throws -> Void
    private let onLongScreenshot: @MainActor (CGRect) async throws -> Void
    private let onScreenRecording: @MainActor (CGRect) async throws -> Void
    private let onScreenTranslate: @MainActor (ScreenTranslationSelection) async throws -> Void
    private let configurationStore: AppConfigurationStore
    private var selectionSession: ScreenSelectionSession?
    private let barcodeResultWindows = BarcodeResultWindowStore()
    private var isCapturing = false

    init(
        pinWindowManager: PinWindowManager,
        configurationStore: AppConfigurationStore = AppConfigurationStore(),
        ocrService: OCRService = OCRService(),
        barcodeService: BarcodeService = BarcodeService(),
        onOCRTranslate: @escaping @MainActor (SelectedScreenshot, String) async throws -> Void = { _, _ in },
        onLongScreenshot: @escaping @MainActor (CGRect) async throws -> Void = { _ in },
        onScreenRecording: @escaping @MainActor (CGRect) async throws -> Void = { _ in },
        onScreenTranslate: @escaping @MainActor (ScreenTranslationSelection) async throws -> Void = { _ in }
    ) {
        self.pinWindowManager = pinWindowManager
        self.configurationStore = configurationStore
        fileSaver = ScreenshotFileSaver()
        self.ocrService = ocrService
        self.barcodeService = barcodeService
        self.onOCRTranslate = onOCRTranslate
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
        onOCRTranslate = { _, _ in }
        onLongScreenshot = { _ in }
        onScreenRecording = { _ in }
        onScreenTranslate = { _ in }
    }

    func captureAndPin(preferredAction: ScreenshotPreferredAction? = nil) async throws {
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
        }
        guard let action = try await captureSelectionAction(preferredAction: preferredAction) else {
            return
        }
        keepsOverlayUntilHandoff = ScreenshotCapturePolicy
            .keepsOverlayUntilHandoff(for: action)
        switch action {
        case let .copy(result):
            try ImagePasteboard.write(result.image)
        case let .save(result):
            _ = try fileSaver.save(result.image)
        case let .pin(result):
            pinWindowManager.pin(
                result.image,
                sourceFrame: result.screenFrame,
                preferredDisplaySize: result.screenFrame.size
            )
        case let .ocrCopy(result):
            let document = try await ocrService.recognizeDocument(in: result.image)
            guard pinWindowManager.pinOCRSelection(
                image: result.image,
                document: document,
                sourceFrame: result.screenFrame,
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
            ) != nil else {
                throw ScreenshotError.ocrSelectionPresentationFailed
            }
        case let .ocrCopyAll(result):
            let text = try await ocrService.recognizeText(in: result.image)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw ScreenshotError.ocrCopyFailed
            }
        case let .ocrTranslate(result):
            let text = try await ocrService.recognizeText(in: result.image)
            try await onOCRTranslate(result, text)
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
        preferredAction: ScreenshotPreferredAction?
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
            var segments: [VirtualDesktopCapture.Segment] = []
            for candidate in screens {
                segments.append(VirtualDesktopCapture.Segment(
                    image: try await capture(screen: candidate),
                    frame: candidate.frame,
                    backingScaleFactor: candidate.backingScaleFactor
                ))
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
                toolbarItems: toolbarItems
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
            toolbarItems: toolbarItems
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

    private func capture(screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let displayID = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: {
                  $0.displayID == CGDirectDisplayID(displayID.uint32Value)
              }) else {
            throw ScreenshotError.screenUnavailable
        }

        let excludedApplications = ScreenshotCapturePolicy.includesCurrentApplicationWindows
            ? []
            : content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let captureSize = CaptureGeometry.preferredCapturePixelSize(
            screenPointSize: screen.frame.size,
            backingScaleFactor: screen.backingScaleFactor,
            reportedPixelSize: CGSize(width: display.width, height: display.height)
        )
        do {
            if ScreenshotCapturePolicy.captureBackend(
                macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            ) == .screenshotConfiguration,
               #available(macOS 26.0, *) {
                let configuration = ScreenshotCapturePolicy.makeScreenshotConfiguration(
                    pixelSize: captureSize
                )
                let output = try await SCScreenshotManager.captureScreenshot(
                    contentFilter: filter,
                    configuration: configuration
                )
                guard let image = output.sdrImage else {
                    throw ScreenshotError.captureFailed("截图没有返回 SDR 图像")
                }
                return image
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
}

enum ScreenshotPreferredAction {
    case longScreenshot
    case screenRecording
    case screenTranslation
}

enum ScreenshotError: LocalizedError {
    case permissionRequired(restartRequired: Bool)
    case screenUnavailable
    case captureFailed(String)
    case ocrSelectionPresentationFailed
    case ocrCopyFailed
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
        case let .barcodeDetectionFailed(message):
            return "条码识别失败：\(message)"
        case .barcodeNotFound:
            return "选区内未识别到二维码或条码"
        case .barcodeResultNotPresentable:
            return "无法显示条码识别结果"
        }
    }
}
