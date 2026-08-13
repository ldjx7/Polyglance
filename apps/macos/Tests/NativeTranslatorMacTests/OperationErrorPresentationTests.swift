import XCTest
@testable import NativeTranslatorMac

final class OperationErrorPresentationTests: XCTestCase {
    func testScreenshotFailureUsesStandaloneAlertCopy() {
        let presentation = OperationErrorPresentation.screenshot(
            TestError(message: "需要屏幕录制权限")
        )

        XCTAssertEqual(presentation.title, "无法使用截图工具")
        XCTAssertEqual(presentation.message, "需要屏幕录制权限")
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
