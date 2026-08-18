import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
protocol LongScreenshotFrameCapturing: AnyObject {
    func capture(region: LongScreenshotCaptureRegion) async throws -> CGImage
}

enum LongScreenshotCaptureError: LocalizedError, Equatable {
    case permissionRequired
    case displayUnavailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "长截图需要屏幕录制权限，请在系统设置的“隐私与安全性”中授权"
        case .displayUnavailable:
            return "长截图所选显示器已不可用"
        case let .captureFailed(message):
            return "长截图采集失败：\(message)"
        }
    }
}

@MainActor
final class ScreenCaptureKitLongScreenshotCapturer: LongScreenshotFrameCapturing {
    typealias PermissionCheck = @MainActor () -> Bool
    typealias CaptureOperation = @MainActor (
        _ region: LongScreenshotCaptureRegion,
        _ excludesCurrentApplication: Bool
    ) async throws -> CGImage

    private let excludesCurrentApplication: Bool
    private let permissionCheck: PermissionCheck
    private let captureOperation: CaptureOperation

    init(excludesCurrentApplication: Bool = true) {
        self.excludesCurrentApplication = excludesCurrentApplication
        permissionCheck = { CGPreflightScreenCaptureAccess() }
        captureOperation = Self.captureUsingScreenCaptureKit
    }

    init(
        excludesCurrentApplication: Bool = true,
        permissionCheck: @escaping PermissionCheck,
        captureOperation: @escaping CaptureOperation
    ) {
        self.excludesCurrentApplication = excludesCurrentApplication
        self.permissionCheck = permissionCheck
        self.captureOperation = captureOperation
    }

    func capture(region: LongScreenshotCaptureRegion) async throws -> CGImage {
        guard permissionCheck() else {
            throw LongScreenshotCaptureError.permissionRequired
        }
        return try await captureOperation(region, excludesCurrentApplication)
    }

    private static func captureUsingScreenCaptureKit(
        region: LongScreenshotCaptureRegion,
        excludesCurrentApplication: Bool
    ) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw LongScreenshotCaptureError.captureFailed(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw LongScreenshotCaptureError.displayUnavailable
        }

        let excludedApplications: [SCRunningApplication]
        if excludesCurrentApplication, let bundleIdentifier = Bundle.main.bundleIdentifier {
            excludedApplications = content.applications.filter {
                $0.bundleIdentifier == bundleIdentifier
            }
        } else {
            excludedApplications = []
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = region.pixelWidth
        configuration.height = region.pixelHeight
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.backgroundColor = .black

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw LongScreenshotCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
