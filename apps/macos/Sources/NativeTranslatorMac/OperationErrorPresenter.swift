import AppKit

enum SystemSettingsDestination: Equatable {
    case screenRecording
    case accessibility

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
        if case .permissionRequired = error as? ScreenshotError {
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
        Self(
            title: "无法完成区域录屏",
            message: error.localizedDescription
        )
    }
}

@MainActor
final class OperationErrorPresenter {
    typealias AlertRunner = (
        OperationErrorPresentation,
        [String]
    ) -> NSApplication.ModalResponse
    typealias URLOpener = (URL) -> Void

    private let alertRunner: AlertRunner
    private let openURL: URLOpener

    init() {
        alertRunner = Self.runAlert
        openURL = { url in
            _ = NSWorkspace.shared.open(url)
        }
    }

    init(
        alertRunner: @escaping AlertRunner,
        openURL: @escaping URLOpener
    ) {
        self.alertRunner = alertRunner
        self.openURL = openURL
    }

    func present(_ presentation: OperationErrorPresentation) {
        if case let .openSystemSettings(destination) = presentation.action {
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
