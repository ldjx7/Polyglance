import XCTest
@testable import Polyglance

@MainActor
final class OperationErrorPresentationTests: XCTestCase {
    func testScreenshotFailureUsesStandaloneAlertCopy() {
        let presentation = OperationErrorPresentation.screenshot(
            TestError(message: "需要屏幕录制权限")
        )

        XCTAssertEqual(presentation.title, "无法使用截图工具")
        XCTAssertEqual(presentation.message, "需要屏幕录制权限")
        XCTAssertNil(presentation.action)
    }

    func testScreenshotPermissionFailureOffersScreenRecordingSettings() {
        let presentation = OperationErrorPresentation.screenshot(
            ScreenshotError.permissionRequired(restartRequired: false)
        )

        XCTAssertEqual(presentation.title, "无法使用截图工具")
        XCTAssertEqual(presentation.action, .openSystemSettings(.screenRecording))
        XCTAssertEqual(
            SystemSettingsDestination.screenRecording.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testAccessibilityPermissionFailureOffersAccessibilitySettings() {
        let presentation = OperationErrorPresentation.accessibilityPermissionRequired()

        XCTAssertEqual(presentation.title, "需要辅助功能权限")
        XCTAssertEqual(presentation.action, .openSystemSettings(.accessibility))
        XCTAssertEqual(
            SystemSettingsDestination.accessibility.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testPermissionAlertDoesNotOpenSettingsWhenUserCancels() {
        var shownButtons: [String] = []
        var openedURLs: [URL] = []
        let presenter = OperationErrorPresenter(
            alertRunner: { _, buttons in
                shownButtons = buttons
                return .alertSecondButtonReturn
            },
            openURL: { openedURLs.append($0) }
        )

        presenter.present(.screenshot(ScreenshotError.permissionRequired(restartRequired: false)))

        XCTAssertEqual(shownButtons, ["打开系统设置", "取消"])
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testPermissionAlertOpensSettingsOnlyAfterUserConfirms() {
        var openedURLs: [URL] = []
        let presenter = OperationErrorPresenter(
            alertRunner: { _, _ in .alertFirstButtonReturn },
            openURL: { openedURLs.append($0) }
        )

        presenter.present(.screenshot(ScreenshotError.permissionRequired(restartRequired: false)))

        XCTAssertEqual(openedURLs, [SystemSettingsDestination.screenRecording.url])
    }

    func testClipboardPinFailureUsesStandaloneAlertCopy() {
        let presentation = OperationErrorPresentation.clipboardPin(
            TestError(message: "剪贴板中没有图片")
        )

        XCTAssertEqual(presentation.title, "无法贴出剪贴板图片")
        XCTAssertEqual(presentation.message, "剪贴板中没有图片")
    }

    func testScreenRecordingFailureUsesStandaloneAlertCopy() {
        let presentation = OperationErrorPresentation.screenRecording(
            TestError(message: "没有捕获到视频画面")
        )

        XCTAssertEqual(presentation.title, "无法完成区域录屏")
        XCTAssertEqual(presentation.message, "没有捕获到视频画面")
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
