import AppKit
import PolyglanceKit
import ScreenCaptureKit

struct ScreenTranslationCapture {
    let fullImage: CGImage
    let screenFrame: CGRect
    func croppedImage(for selection: CGRect) -> NSImage? {
        let localSelection = CGRect(
            x: selection.minX - screenFrame.minX,
            y: selection.minY - screenFrame.minY,
            width: selection.width,
            height: selection.height
        )
        let cropRect = CaptureGeometry.pixelCropRect(
            selection: localSelection,
            viewSize: screenFrame.size,
            imagePixelSize: CGSize(width: fullImage.width, height: fullImage.height)
        )
        guard cropRect.width >= 1, cropRect.height >= 1,
              let cropped = fullImage.cropping(to: cropRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: selection.size)
    }

    func clamped(selection: CGRect) -> CGRect {
        let clamped = selection.standardized.intersection(screenFrame)
        return clamped.isNull ? selection.standardized : clamped
    }
}

struct ScreenTranslationSelection {
    let capture: ScreenTranslationCapture
    let selection: CGRect
}

enum ScreenTranslationRecaptureError: LocalizedError {
    case screenUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenUnavailable:
            return "无法识别截屏翻译所在的显示器"
        case let .captureFailed(message):
            return "重新截取屏幕失败：\(message)"
        }
    }
}

enum ScreenTranslationRecapture {
    @MainActor
    static func captureScreen(withFrame screenFrame: CGRect) async throws -> ScreenTranslationCapture {
        guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame })
                ?? NSScreen.screens.first(where: {
                    $0.frame.contains(CGPoint(x: screenFrame.midX, y: screenFrame.midY))
                }) else {
            throw ScreenTranslationRecaptureError.screenUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let displayID = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: {
                  $0.displayID == CGDirectDisplayID(displayID.uint32Value)
              }) else {
            throw ScreenTranslationRecaptureError.screenUnavailable
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
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
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return ScreenTranslationCapture(fullImage: image, screenFrame: screen.frame)
        } catch {
            throw ScreenTranslationRecaptureError.captureFailed(error.localizedDescription)
        }
    }
}
