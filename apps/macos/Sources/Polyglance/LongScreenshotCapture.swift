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
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            // The cached snapshot may predate a display change, so a miss is
            // retried once against freshly enumerated content.
            invalidateShareableContent()
            let refreshed = try await shareableContent()
            guard let display = refreshed.displays.first(where: {
                $0.displayID == region.displayID
            }) else {
                throw LongScreenshotCaptureError.displayUnavailable
            }
            return try await captureImage(
                display: display,
                content: refreshed,
                region: region,
                excludesCurrentApplication: excludesCurrentApplication
            )
        }
        return try await captureImage(
            display: display,
            content: content,
            region: region,
            excludesCurrentApplication: excludesCurrentApplication
        )
    }

    /// Enumerating shareable content costs tens of milliseconds and is repeated
    /// for every frame of a session. That latency lands between the scroll and
    /// the capture, which widens the distance the page travels per frame and
    /// pushes the stitcher towards its search limit. The window list barely
    /// changes during a capture, so a short-lived cache is enough.
    private static let shareableContentLifetime: TimeInterval = 1.0
    private static var cachedShareableContent: (content: SCShareableContent, capturedAt: Date)?

    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedShareableContent,
           Date().timeIntervalSince(cached.capturedAt) < shareableContentLifetime {
            return cached.content
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            cachedShareableContent = (content, Date())
            return content
        } catch {
            cachedShareableContent = nil
            throw LongScreenshotCaptureError.captureFailed(error.localizedDescription)
        }
    }

    private static func invalidateShareableContent() {
        cachedShareableContent = nil
    }

    private static func captureImage(
        display: SCDisplay,
        content: SCShareableContent,
        region: LongScreenshotCaptureRegion,
        excludesCurrentApplication: Bool
    ) async throws -> CGImage {
        let excludedApplications: [SCRunningApplication]
        if excludesCurrentApplication {
            // Matching on the bundle identifier alone silently excludes nothing
            // when there is no bundle — an unbundled or test run — and the
            // selection border then lands in every frame. The process id always
            // identifies this application.
            let processIdentifier = ProcessInfo.processInfo.processIdentifier
            let bundleIdentifier = Bundle.main.bundleIdentifier
            excludedApplications = content.applications.filter { application in
                application.processID == processIdentifier
                    || (bundleIdentifier != nil
                        && application.bundleIdentifier == bundleIdentifier)
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
            invalidateShareableContent()
            throw LongScreenshotCaptureError.captureFailed(error.localizedDescription)
        }
    }
}
