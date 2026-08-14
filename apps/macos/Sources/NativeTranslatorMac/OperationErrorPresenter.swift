import AppKit

enum OperationErrorAction: Equatable {
    case openScreenRecordingSettings
}

enum ScreenRecordingSettings {
    static let destinationURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
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
            action = .openScreenRecordingSettings
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

    static func screenRecording(_ error: Error) -> Self {
        Self(
            title: "无法完成区域录屏",
            message: error.localizedDescription
        )
    }
}

@MainActor
final class OperationErrorPresenter {
    func present(_ presentation: OperationErrorPresentation) {
        if presentation.action == .openScreenRecordingSettings {
            NSWorkspace.shared.open(ScreenRecordingSettings.destinationURL)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
