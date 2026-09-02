import AppKit
import CoreGraphics
import XCTest
@testable import Polyglance

@MainActor
final class BarcodeResultWindowTests: XCTestCase {
    private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    private func observation(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 0.2,
        height: CGFloat = 0.2
    ) -> BarcodeObservation {
        BarcodeObservation(
            payload: "payload",
            symbology: .qr,
            boundingBox: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    func testMarkerCenterMapsVisionCoordinatesIntoTopLeftViewSpace() {
        let point = BarcodeResultWindow.markerCenter(
            for: observation(x: 0.25, y: 0.6),
            in: CGSize(width: 1000, height: 800)
        )

        XCTAssertEqual(point.x, 350, accuracy: 0.001)
        XCTAssertEqual(point.y, 240, accuracy: 0.001)
    }

    func testMarkerUsesTheSharedLargerDiameter() {
        XCTAssertEqual(BarcodeResultWindow.markerDiameter, 22)
        XCTAssertEqual(BarcodeResultWindow.markerCoreDiameter, 11)
    }

    func testDoubleClickClosesRecognitionOverlay() throws {
        let window = BarcodeResultWindow(
            observations: [observation(x: 0.2, y: 0.2)],
            image: NSImage(size: screenFrame.size),
            screenFrame: screenFrame
        )
        window.orderFront(nil)
        XCTAssertTrue(window.isVisible)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 300, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1
        ))
        window.sendEvent(event)

        XCTAssertFalse(window.isVisible)
    }

    func testRecognitionOverlayKeepsTheExactSelectedScreenFrame() {
        let selectedFrame = CGRect(x: -900, y: 80, width: 740, height: 520)
        let window = BarcodeResultWindow(
            observations: [observation(x: 0.2, y: 0.2)],
            image: NSImage(size: selectedFrame.size),
            screenFrame: selectedFrame
        )

        XCTAssertEqual(window.frame, selectedFrame)
    }

    func testMultipleResultHeaderUsesQRCodeWording() {
        XCTAssertEqual(
            BarcodeResultWindow.headerTitle(for: [
                observation(x: 0.1, y: 0.1),
                observation(x: 0.6, y: 0.6),
            ]),
            "识别到 2 个二维码"
        )
    }

    func testWindowStoreKeepsSeveralResultCardsAliveIndependently() {
        let store = BarcodeResultWindowStore()
        let first = BarcodeResultWindow(
            observations: [observation(x: 0.1, y: 0.1)],
            image: NSImage(size: screenFrame.size),
            screenFrame: screenFrame
        )
        let second = BarcodeResultWindow(
            observations: [observation(x: 0.6, y: 0.6)],
            image: NSImage(size: screenFrame.size),
            screenFrame: screenFrame
        )

        store.retain(first)
        store.retain(second)
        XCTAssertEqual(store.activeWindowCount, 2)

        store.release(first)
        XCTAssertEqual(store.activeWindowCount, 1)
        XCTAssertTrue(store.contains(second))
    }
}

final class ScreenshotCapturePolicyBarcodeTests: XCTestCase {
    private func screenshot() -> SelectedScreenshot {
        SelectedScreenshot(image: NSImage(), screenFrame: .zero)
    }

    func testDetectBarcodeKeepsTheOverlayUntilTheHandoffLikeAPin() {
        XCTAssertTrue(
            ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .detectBarcode(screenshot()))
        )
        XCTAssertTrue(
            ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .pin(screenshot()))
        )
    }

    func testOtherActionsTearTheOverlayDownImmediately() {
        XCTAssertFalse(ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: nil))
        XCTAssertFalse(
            ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .copy(screenshot()))
        )
        XCTAssertFalse(
            ScreenshotCapturePolicy.keepsOverlayUntilHandoff(for: .ocrTranslate(screenshot()))
        )
    }

    func testBarcodeErrorsHaveActionableChineseDescriptions() {
        XCTAssertEqual(
            ScreenshotError.barcodeDetectionFailed("底层解码错误").errorDescription,
            "条码识别失败：底层解码错误"
        )
        XCTAssertEqual(
            ScreenshotError.barcodeNotFound.errorDescription,
            "选区内未识别到二维码或条码"
        )
        XCTAssertEqual(
            ScreenshotError.barcodeResultNotPresentable.errorDescription,
            "无法显示条码识别结果"
        )
    }
}
