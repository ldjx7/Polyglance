import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class LongScreenshotCaptureTests: XCTestCase {
    func testInjectedCaptureOperationReceivesTheRegionWithoutScreenPermission() async throws {
        let image = makeCaptureTestImage()
        let region = makeCaptureTestRegion()
        var receivedRegion: LongScreenshotCaptureRegion?
        var receivedExclusionFlag: Bool?
        let capturer = ScreenCaptureKitLongScreenshotCapturer(
            excludesCurrentApplication: false,
            permissionCheck: { true },
            captureOperation: { requestedRegion, excludesCurrentApplication in
                receivedRegion = requestedRegion
                receivedExclusionFlag = excludesCurrentApplication
                return image
            }
        )

        let result = try await capturer.capture(region: region)

        XCTAssertTrue(result === image)
        XCTAssertEqual(receivedRegion, region)
        XCTAssertEqual(receivedExclusionFlag, false)
    }

    func testPermissionFailureDoesNotInvokeInjectedCaptureOperation() async {
        var didInvokeCapture = false
        let capturer = ScreenCaptureKitLongScreenshotCapturer(
            permissionCheck: { false },
            captureOperation: { _, _ in
                didInvokeCapture = true
                return makeCaptureTestImage()
            }
        )

        do {
            _ = try await capturer.capture(region: makeCaptureTestRegion())
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(error as? LongScreenshotCaptureError, .permissionRequired)
        }
        XCTAssertFalse(didInvokeCapture)
    }

    func testCaptureErrorsHaveActionableLocalizedDescriptions() {
        XCTAssertEqual(
            LongScreenshotCaptureError.permissionRequired.localizedDescription,
            "长截图需要屏幕录制权限，请在系统设置的“隐私与安全性”中授权"
        )
        XCTAssertEqual(
            LongScreenshotCaptureError.displayUnavailable.localizedDescription,
            "长截图所选显示器已不可用"
        )
        XCTAssertEqual(
            LongScreenshotCaptureError.captureFailed("offline").localizedDescription,
            "长截图采集失败：offline"
        )
    }
}

private func makeCaptureTestRegion() -> LongScreenshotCaptureRegion {
    LongScreenshotCaptureRegion(
        displayID: 5,
        sourceRect: CGRect(x: 10, y: 20, width: 4, height: 3),
        globalRect: CGRect(x: 110, y: 220, width: 4, height: 3),
        pixelWidth: 4,
        pixelHeight: 3
    )
}

private func makeCaptureTestImage() -> CGImage {
    let data = Data(repeating: 140, count: 4 * 3 * 4)
    return CGImage(
        width: 4,
        height: 3,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: data as CFData)!,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}
