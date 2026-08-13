import AppKit
import Vision
import XCTest
@testable import NativeTranslatorMac

final class OCRServiceTests: XCTestCase {
    func testRecognizesNSImageAndReturnsTrimmedTextInNaturalReadingOrder() async throws {
        let backend = OCRBackendStub(
            response: .success([
                OCRTextObservation(
                    text: "  日本語  ",
                    boundingBox: CGRect(x: 0.08, y: 0.10, width: 0.35, height: 0.10)
                ),
                OCRTextObservation(
                    text: "world",
                    boundingBox: CGRect(x: 0.56, y: 0.79, width: 0.30, height: 0.10)
                ),
                OCRTextObservation(
                    text: " \n\t ",
                    boundingBox: CGRect(x: 0.05, y: 0.95, width: 0.20, height: 0.04)
                ),
                OCRTextObservation(
                    text: "한국어",
                    boundingBox: CGRect(x: 0.08, y: 0.45, width: 0.35, height: 0.10)
                ),
                OCRTextObservation(
                    text: "  你好  ",
                    boundingBox: CGRect(x: 0.08, y: 0.80, width: 0.35, height: 0.10)
                ),
            ])
        )
        let service = OCRService(backend: backend)
        let image = NSImage(cgImage: makeCGImage(width: 12, height: 8), size: NSSize(width: 12, height: 8))

        let text = try await service.recognizeText(in: image)

        XCTAssertEqual(text, "你好\nworld\n한국어\n日本語")
        let receivedImageSize = await backend.receivedImageSize
        XCTAssertEqual(receivedImageSize, CGSize(width: 12, height: 8))
    }

    func testRecognizesCGImageDirectlyAndPreservesMeaningfulInternalWhitespace() async throws {
        let backend = OCRBackendStub(
            response: .success([
                OCRTextObservation(
                    text: "hello   world",
                    boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1)
                ),
            ])
        )
        let service = OCRService(backend: backend)

        let text = try await service.recognizeText(in: makeCGImage(width: 6, height: 4))

        XCTAssertEqual(text, "hello   world")
    }

    func testReportsNoTextWhenBackendReturnsNoObservations() async {
        let service = OCRService(backend: OCRBackendStub(response: .success([])))

        await assertOCRError(.noText) {
            try await service.recognizeText(in: makeCGImage())
        }
    }

    func testReportsNoTextWhenEveryObservationIsWhitespace() async {
        let backend = OCRBackendStub(
            response: .success([
                OCRTextObservation(
                    text: " \n\t ",
                    boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.1)
                ),
            ])
        )
        let service = OCRService(backend: backend)

        await assertOCRError(.noText) {
            try await service.recognizeText(in: makeCGImage())
        }
    }

    func testRejectsNSImageWithoutAValidCGImageBeforeCallingBackend() async {
        let backend = OCRBackendStub(response: .success([]))
        let service = OCRService(backend: backend)

        await assertOCRError(.invalidImage) {
            try await service.recognizeText(in: NSImage(size: .zero))
        }
        let callCount = await backend.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testMapsUnexpectedBackendFailureToExplicitVisionFailure() async {
        let service = OCRService(backend: OCRBackendStub(response: .unexpectedFailure))

        await assertOCRError(.visionFailed("Vision unavailable")) {
            try await service.recognizeText(in: makeCGImage())
        }
    }

    func testPreservesExplicitVisionFailureFromBackend() async {
        let service = OCRService(
            backend: OCRBackendStub(response: .ocrFailure(.visionFailed("request failed")))
        )

        await assertOCRError(.visionFailed("request failed")) {
            try await service.recognizeText(in: makeCGImage())
        }
    }

    func testErrorsHaveActionableLocalizedDescriptions() {
        XCTAssertEqual(OCRError.invalidImage.errorDescription, "无法从图像中读取有效像素")
        XCTAssertEqual(OCRError.noText.errorDescription, "未识别到文字")
        XCTAssertEqual(
            OCRError.visionFailed("model unavailable").errorDescription,
            "文字识别失败：model unavailable"
        )
    }

    func testVisionRequestEnablesAccurateAutomaticChineseEnglishJapaneseAndKoreanRecognition() throws {
        let request = try VisionOCRBackend.configuredRequest()

        XCTAssertEqual(request.revision, VNRecognizeTextRequestRevision3)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertTrue(request.automaticallyDetectsLanguage)
        for language in ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"] {
            XCTAssertTrue(request.recognitionLanguages.contains(language), "Missing \(language)")
        }
    }

    func testVisionBackendCanProcessAnImageWithoutDependingOnRecognizedText() async throws {
        _ = try await VisionOCRBackend().recognizeText(in: makeCGImage(width: 128, height: 128))
    }

    private func assertOCRError(
        _ expectedError: OCRError,
        operation: () async throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expectedError)", file: file, line: line)
        } catch let error as OCRError {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeCGImage(width: Int = 4, height: Int = 4) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}

private actor OCRBackendStub: OCRRecognitionBackend {
    enum Response: Sendable {
        case success([OCRTextObservation])
        case ocrFailure(OCRError)
        case unexpectedFailure
    }

    private let response: Response
    private(set) var callCount = 0
    private(set) var receivedImageSize: CGSize?

    init(response: Response) {
        self.response = response
    }

    func recognizeText(in image: CGImage) async throws -> [OCRTextObservation] {
        callCount += 1
        receivedImageSize = CGSize(width: image.width, height: image.height)

        switch response {
        case let .success(observations):
            return observations
        case let .ocrFailure(error):
            throw error
        case .unexpectedFailure:
            throw OCRBackendStubError.visionUnavailable
        }
    }
}

private enum OCRBackendStubError: LocalizedError {
    case visionUnavailable

    var errorDescription: String? {
        "Vision unavailable"
    }
}
