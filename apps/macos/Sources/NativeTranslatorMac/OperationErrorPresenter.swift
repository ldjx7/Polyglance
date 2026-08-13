import AppKit

struct OperationErrorPresentation: Equatable {
    let title: String
    let message: String

    static func screenshot(_ error: Error) -> Self {
        Self(
            title: "无法使用截图工具",
            message: error.localizedDescription
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
