import CoreGraphics
import XCTest
@testable import Polyglance

final class BarcodeContentTests: XCTestCase {
    func testWebLinksBecomeOpenableURLs() {
        for payload in ["https://example.com", "http://example.com/path?q=1"] {
            let content = BarcodeContent(payload: payload)

            guard case .url = content else {
                return XCTFail("\(payload) should classify as a URL")
            }
            XCTAssertTrue(content.isOpenable)
        }
    }

    func testOTPSchemesAreRecognisedSeparately() {
        let content = BarcodeContent(payload: "otpauth://totp/Example:me?secret=ABC123")

        guard case .otp = content else {
            return XCTFail("otpauth should classify as OTP")
        }
        // A key is not a web page, so it must never be offered as one.
        XCTAssertFalse(content.isOpenable)
    }

    func testNonWebSchemesGetNoOpenAction() {
        for payload in ["file:///etc/passwd", "smb://server/share", "myapp://deep/link"] {
            let content = BarcodeContent(payload: payload)

            guard case .text = content else {
                return XCTFail("\(payload) should fall back to text")
            }
            XCTAssertFalse(content.isOpenable)
        }
    }

    func testWiFiPayloadIsUnescaped() {
        // The escaped punctuation is what makes a naive split-on-semicolon wrong.
        let content = BarcodeContent(
            payload: #"WIFI:T:WPA;S:café\,office;P:pa\;ss\:word;;"#
        )

        guard case let .wifi(ssid, password, security) = content else {
            return XCTFail("a WIFI payload should classify as WiFi")
        }
        XCTAssertEqual(ssid, "café,office")
        XCTAssertEqual(password, "pa;ss:word")
        XCTAssertEqual(security, "WPA")
        XCTAssertEqual(content.copiedText, "pa;ss:word")
    }

    func testWiFiWithoutAnSSIDFallsBackToText() {
        let content = BarcodeContent(payload: "WIFI:T:WPA;P:secret;;")

        guard case .text = content else {
            return XCTFail("a WiFi payload with no SSID is not usable as WiFi")
        }
    }

    func testWiFiPrefixIsCaseInsensitiveOnBothPlatforms() {
        let content = BarcodeContent(payload: "wifi:t:WPA;s:Polyglance;p:secret;;")

        guard case let .wifi(ssid, password, _) = content else {
            return XCTFail("lowercase wifi prefix should classify as WiFi")
        }
        XCTAssertEqual(ssid, "Polyglance")
        XCTAssertEqual(password, "secret")
    }

    func testStructuredPayloadsIgnoreOuterWhitespaceButPlainTextKeepsIt() {
        guard case let .url(url) = BarcodeContent(payload: "  https://example.com/path  \n") else {
            return XCTFail("trimmed web payload should classify as URL")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/path")

        guard case let .text(text) = BarcodeContent(payload: "  plain text  ") else {
            return XCTFail("plain text should remain plain text")
        }
        XCTAssertEqual(text, "  plain text  ")
    }

    func testUnknownWiFiEscapesArePreservedVerbatim() {
        let content = BarcodeContent(payload: #"WIFI:S:network;P:pass\qword;;"#)

        guard case let .wifi(_, password, _) = content else {
            return XCTFail("WiFi payload should parse")
        }
        XCTAssertEqual(password, #"pass\qword"#)
    }

    func testPlainTextStaysPlainText() {
        let content = BarcodeContent(payload: "只是一段文字")

        guard case .text("只是一段文字") = content else {
            return XCTFail("bare text should stay text")
        }
        XCTAssertFalse(content.isOpenable)
        XCTAssertFalse(content.isTranslatable)
    }

    func testBinaryLikeTextCannotBeSentToTranslation() {
        let content = BarcodeContent(payload: "\u{0000}\u{0001}\u{FFFD}")

        guard case .text = content else {
            return XCTFail("binary-like payloads should still be displayed as text")
        }
        XCTAssertFalse(content.isTranslatable)
    }
}

final class BarcodeServiceTests: XCTestCase {
    func testResultsAreOrderedTopToBottomThenLeftToRight() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .success([
            Self.observation("bottom-left", x: 0.1, y: 0.1),
            Self.observation("top-right", x: 0.7, y: 0.7),
            Self.observation("top-left", x: 0.1, y: 0.7),
        ])))

        let results = try await service.recognizeBarcodes(in: Self.image())

        XCTAssertEqual(results.map(\.payload), ["top-left", "top-right", "bottom-left"])
    }

    func testOrderingIsStableForBoxesAtTheSameSpot() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .success([
            Self.observation("first", x: 0.2, y: 0.2),
            Self.observation("second", x: 0.2, y: 0.2),
        ])))

        let results = try await service.recognizeBarcodes(in: Self.image())

        XCTAssertEqual(results.map(\.payload), ["first", "second"])
    }

    func testTheSamePayloadAppearsOnlyOnce() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .success([
            Self.observation("same", x: 0.1, y: 0.7),
            Self.observation("same", x: 0.7, y: 0.1),
            Self.observation("other", x: 0.4, y: 0.4),
        ])))

        let results = try await service.recognizeBarcodes(in: Self.image())

        XCTAssertEqual(results.map(\.payload), ["same", "other"])
    }

    func testAnEmptySelectionReportsNotFound() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .success([])))

        do {
            _ = try await service.recognizeBarcodes(in: Self.image())
            XCTFail("an empty result set should not be treated as success")
        } catch let error as BarcodeError {
            XCTAssertEqual(error, BarcodeError.notFound)
        }
    }

    func testBackendFailuresAreWrapped() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .failure(.boom)))

        do {
            _ = try await service.recognizeBarcodes(in: Self.image())
            XCTFail("a backend failure should surface as an error")
        } catch let error as BarcodeError {
            guard case .recognitionFailed = error else {
                return XCTFail("expected a wrapped failure, got \(error)")
            }
        }
    }

    func testBoxesOutsideNormalizedSpaceAreClamped() async throws {
        let service = BarcodeService(backend: BarcodeBackendStub(result: .success([
            BarcodeObservation(
                payload: "edge",
                symbology: .qr,
                boundingBox: CGRect(x: -0.1, y: 0.9, width: 0.3, height: 0.3)
            ),
        ])))

        let results = try await service.recognizeBarcodes(in: Self.image())

        let box = try XCTUnwrap(results.single?.boundingBox)
        XCTAssertEqual(box.minX, 0, accuracy: 0.000_001)
        XCTAssertEqual(box.minY, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(box.width, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(box.height, 0.1, accuracy: 0.000_001)
    }

    private static func observation(
        _ payload: String,
        x: CGFloat,
        y: CGFloat
    ) -> BarcodeObservation {
        BarcodeObservation(
            payload: payload,
            symbology: .qr,
            boundingBox: CGRect(x: x, y: y, width: 0.2, height: 0.2)
        )
    }

    private static func image() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}

private struct BarcodeBackendStub: BarcodeRecognitionBackend {
    enum Failure: Error {
        case boom
    }

    let result: Result<[BarcodeObservation], Failure>

    func recognizeBarcodes(in image: CGImage) async throws -> [BarcodeObservation] {
        try result.get()
    }
}
