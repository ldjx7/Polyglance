import CoreImage
import Vision
import XCTest
@testable import Polyglance

final class BarcodeVisionBackendTests: XCTestCase {
    func testVisionDecodesARealQRCode() async throws {
        let payload = "Polyglance-QR-Test"
        let image = try qrCode(payload: payload)

        let observations = try await VisionBarcodeBackend().recognizeBarcodes(in: image)

        let observation = try XCTUnwrap(observations.first { $0.payload == payload })
        XCTAssertEqual(observation.symbology, .qr)
        XCTAssertGreaterThan(observation.boundingBox.width, 0)
        XCTAssertGreaterThan(observation.boundingBox.height, 0)
        XCTAssertGreaterThanOrEqual(observation.boundingBox.minX, 0)
        XCTAssertLessThanOrEqual(observation.boundingBox.maxX, 1)
        XCTAssertEqual(observation.corners?.count, 4)
    }

    func testVisionReturnsNoResultsForABlankImage() async throws {
        let context = CGContext(
            data: nil,
            width: 256,
            height: 256,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        let observations = try await VisionBarcodeBackend().recognizeBarcodes(in: context.makeImage()!)

        XCTAssertTrue(observations.isEmpty)
    }

    func testLeadingZeroEAN13IsReportedAsUPCA() {
        XCTAssertEqual(
            BarcodeSymbology(.ean13, payload: "0123456789012"),
            .upca
        )
        XCTAssertEqual(
            BarcodeSymbology(.ean13, payload: "1234567890123"),
            .ean13
        )
    }

    private func qrCode(payload: String) throws -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
            output,
            from: output.extent
        ))
    }
}
