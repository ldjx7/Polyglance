import AppKit
import CoreGraphics
import NativeTranslatorMacKit
import ScreenCaptureKit

@MainActor
final class ScreenshotCoordinator {
    private let pinWindowManager: PinWindowManager
    private let fileSaver: ScreenshotFileSaver
    private let ocrService: OCRService
    private let onOCRTranslate: @MainActor (SelectedScreenshot, String) async throws -> Void
    private let onLongScreenshot: @MainActor (CGRect) async throws -> Void
    private let onScreenRecording: @MainActor (CGRect) async throws -> Void
    private var selectionSession: ScreenSelectionSession?
    private var isCapturing = false

    init(
        pinWindowManager: PinWindowManager,
        ocrService: OCRService = OCRService(),
        onOCRTranslate: @escaping @MainActor (SelectedScreenshot, String) async throws -> Void = { _, _ in },
        onLongScreenshot: @escaping @MainActor (CGRect) async throws -> Void = { _ in },
        onScreenRecording: @escaping @MainActor (CGRect) async throws -> Void = { _ in }
    ) {
        self.pinWindowManager = pinWindowManager
        fileSaver = ScreenshotFileSaver()
        self.ocrService = ocrService
        self.onOCRTranslate = onOCRTranslate
        self.onLongScreenshot = onLongScreenshot
        self.onScreenRecording = onScreenRecording
    }

    init(pinWindowManager: PinWindowManager, fileSaver: ScreenshotFileSaver) {
        self.pinWindowManager = pinWindowManager
        self.fileSaver = fileSaver
        ocrService = OCRService()
        onOCRTranslate = { _, _ in }
        onLongScreenshot = { _ in }
        onScreenRecording = { _ in }
    }

    func captureAndPin(preferredAction: ScreenshotPreferredAction? = nil) async throws {
        guard let action = try await captureSelectionAction(
            preferredAction: preferredAction
        ) else {
            return
        }
        switch action {
        case let .copy(result):
            try ImagePasteboard.write(result.image)
        case let .save(result):
            _ = try fileSaver.save(result.image)
        case let .pin(result):
            pinWindowManager.pin(result.image, sourceFrame: result.screenFrame)
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
        case let .longScreenshot(result):
            try await onLongScreenshot(result.screenFrame)
        case let .screenRecording(result):
            try await onScreenRecording(result.screenFrame)
        }
    }

    /// Owns only the on-screen selection phase. Returning the action before
    /// OCR, translation, long-capture, or recording setup begins prevents an
    /// older post-processing task from releasing a newer selection session.
    private func captureSelectionAction(
        preferredAction: ScreenshotPreferredAction?
    ) async throws -> ScreenshotSelectionAction? {
        guard selectionSession == nil, !isCapturing else {
            return nil
        }
        isCapturing = true
        defer {
            selectionSession = nil
            isCapturing = false
        }
        guard CGPreflightScreenCaptureAccess() else {
            let granted = CGRequestScreenCaptureAccess()
            throw ScreenshotError.permissionRequired(restartRequired: granted)
        }
        guard let screen = screenUnderPointer() else {
            throw ScreenshotError.screenUnavailable
        }

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
            preferredAction: preferredAction
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

        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let captureSize = CaptureGeometry.preferredCapturePixelSize(
            screenPointSize: screen.frame.size,
            backingScaleFactor: screen.backingScaleFactor,
            reportedPixelSize: CGSize(width: display.width, height: display.height)
        )
        configuration.width = Int(captureSize.width)
        configuration.height = Int(captureSize.height)
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.backgroundColor = .black

        do {
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
}

private enum ScreenshotError: LocalizedError {
    case permissionRequired(restartRequired: Bool)
    case screenUnavailable
    case captureFailed(String)
    case ocrSelectionPresentationFailed
    case ocrCopyFailed

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
        }
    }
}
