import AppKit
import ApplicationServices
import AVFoundation

enum SystemSettingsDestination: Equatable {
    case screenRecording
    case accessibility
    case microphone

    var url: URL {
        switch self {
        case .screenRecording:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            )!
        case .accessibility:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )!
        case .microphone:
            URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )!
        }
    }
}

@MainActor
final class PermissionRequestCoordinator {
    static let shared = PermissionRequestCoordinator()
    private let defaults: UserDefaults
    private let request: (SystemSettingsDestination) -> Void
    private var isRequesting = false

    init(defaults: UserDefaults = .standard,
         request: @escaping (SystemSettingsDestination) -> Void = { destination in
             switch destination {
             case .screenRecording:
                 _ = CGRequestScreenCaptureAccess()
             case .accessibility:
                 let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                 _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
             case .microphone:
                 MicrophonePermission.requestAccess { _ in }
             }
         }) {
        self.defaults = defaults
        self.request = request
    }

    func hasRequested(_ destination: SystemSettingsDestination) -> Bool {
        let key: String
        switch destination {
        case .screenRecording:
            key = "permissionRequest.screenRecording"
        case .accessibility:
            key = "permissionRequest.accessibility"
        case .microphone:
            key = "permissionRequest.microphone"
        }
        return defaults.bool(forKey: key)
    }

    // Record before requesting: the system may show its prompt asynchronously.
    func requestIfNeeded(_ destination: SystemSettingsDestination) -> Bool {
        guard !isRequesting else { return true }
        let key: String
        switch destination {
        case .screenRecording:
            key = "permissionRequest.screenRecording"
        case .accessibility:
            key = "permissionRequest.accessibility"
        case .microphone:
            key = "permissionRequest.microphone"
        }
        guard !defaults.bool(forKey: key) else { return false }
        defaults.set(true, forKey: key)
        isRequesting = true
        defer { isRequesting = false }
        PerfLogger.log("[Permissions] Native request: \(destination), pid=\(ProcessInfo.processInfo.processIdentifier)")
        request(destination)
        return true
    }

    func openFromSettings(_ destination: SystemSettingsDestination) {
        if !requestIfNeeded(destination) {
            NSWorkspace.shared.open(destination.url)
        }
    }
}

enum OperationErrorAction: Equatable {
    case openSystemSettings(SystemSettingsDestination)
}

struct OperationErrorPresentation: Equatable {
    let title: String
    let message: String
    let action: OperationErrorAction?

    init(title: String, message: String, action: OperationErrorAction? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }

    static func screenshot(_ error: Error) -> Self {
        let action: OperationErrorAction?
        if isScreenPermissionError(error) {
            action = .openSystemSettings(.screenRecording)
        } else {
            action = nil
        }
        return Self(
            title: "无法使用截图工具",
            message: error.localizedDescription,
            action: action
        )
    }

    private static func isScreenPermissionError(_ error: Error) -> Bool {
        if case .permissionRequired = error as? ScreenshotError { return true }
        if case .permissionRequired = error as? ScreenRecordingCoordinatorError { return true }
        if case .permissionRequired = error as? LongScreenshotCaptureError { return true }
        return false
    }

    private static func isMicrophonePermissionError(_ error: Error) -> Bool {
        if case .microphonePermissionRequired = error as? ScreenRecordingCoordinatorError { return true }
        if case .microphonePermissionRequired = error as? ScreenRecordingEngineError { return true }
        return false
    }

    static func clipboardPin(_ error: Error) -> Self {
        Self(
            title: "无法贴出剪贴板图片",
            message: error.localizedDescription
        )
    }

    static func accessibilityPermissionRequired() -> Self {
        Self(
            title: "需要辅助功能权限",
            message: "读取其他应用中选中的文字需要辅助功能权限。",
            action: .openSystemSettings(.accessibility)
        )
    }

    static func screenRecording(_ error: Error) -> Self {
        let action: OperationErrorAction?
        if isScreenPermissionError(error) {
            action = .openSystemSettings(.screenRecording)
        } else if isMicrophonePermissionError(error) {
            action = .openSystemSettings(.microphone)
        } else {
            action = nil
        }
        return Self(
            title: "无法完成区域录屏",
            message: error.localizedDescription,
            action: action
        )
    }

    static func screenTranslation(_ error: Error) -> Self {
        Self(
            title: "无法完成截屏翻译",
            message: error.localizedDescription,
            action: isScreenPermissionError(error) ? .openSystemSettings(.screenRecording) : nil
        )
    }
}

@MainActor
final class OperationErrorPresenter {
    // Native APIs and runModal can process nested main-loop events.
    private static var isPresenting = false
    typealias AlertRunner = (
        OperationErrorPresentation,
        [String]
    ) -> NSApplication.ModalResponse
    typealias URLOpener = (URL) -> Void

    private let alertRunner: AlertRunner
    private let openURL: URLOpener
    private let requestIfNeeded: (SystemSettingsDestination) -> Bool

    init() {
        requestIfNeeded = { PermissionRequestCoordinator.shared.requestIfNeeded($0) }
        alertRunner = Self.runAlert
        openURL = { url in
            _ = NSWorkspace.shared.open(url)
        }
    }

    init(
        alertRunner: @escaping AlertRunner,
        openURL: @escaping URLOpener,
        requestIfNeeded: @escaping (SystemSettingsDestination) -> Bool = { _ in false }
    ) {
        self.requestIfNeeded = requestIfNeeded
        self.alertRunner = alertRunner
        self.openURL = openURL
    }

    func present(_ presentation: OperationErrorPresentation) {
        guard !Self.isPresenting else { return }
        Self.isPresenting = true
        defer { Self.isPresenting = false }
        if case let .openSystemSettings(destination) = presentation.action {
            guard !requestIfNeeded(destination) else { return }
            PerfLogger.log("[Permissions] Custom prompt: \(destination)")
            let response = alertRunner(
                presentation,
                ["打开系统设置", "取消"]
            )
            if response == .alertFirstButtonReturn {
                openURL(destination.url)
            }
            return
        }

        _ = alertRunner(presentation, ["知道了"])
    }

    private static func runAlert(
        presentation: OperationErrorPresentation,
        buttonTitles: [String]
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        for title in buttonTitles {
            alert.addButton(withTitle: title)
        }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
