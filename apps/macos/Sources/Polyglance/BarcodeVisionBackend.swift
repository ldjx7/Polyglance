import CoreGraphics
import Foundation
import Vision

struct VisionBarcodeBackend: BarcodeRecognitionBackend {
    /// An explicit allow-list rather than "everything Vision knows". Scanning
    /// every symbology on a 4K screenshot costs time and invites false
    /// positives, and the list doubles as the supported-format contract the
    /// Windows (ZXing) side mirrors.
    static let preferredSymbologies: [VNBarcodeSymbology] = [
        .qr,
        .aztec,
        .code128,
        .code39,
        .dataMatrix,
        .ean13,
        .pdf417,
    ]

    func recognizeBarcodes(in image: CGImage) async throws -> [BarcodeObservation] {
        do {
            return try await Task.detached(priority: .userInitiated) {
                () async throws -> [BarcodeObservation] in
                let request = VNDetectBarcodesRequest()
                request.symbologies = Self.preferredSymbologies
                let handler = VNImageRequestHandler(
                    cgImage: image,
                    orientation: .up,
                    options: [:]
                )
                try handler.perform([request])

                return request.results?.compactMap { observation in
                    guard let payload = observation.payloadStringValue, !payload.isEmpty else {
                        return nil
                    }
                    return BarcodeObservation(
                        payload: payload,
                        symbology: BarcodeSymbology(
                            observation.symbology,
                            payload: payload
                        ),
                        boundingBox: observation.boundingBox,
                        corners: [
                            observation.topLeft,
                            observation.topRight,
                            observation.bottomRight,
                            observation.bottomLeft,
                        ]
                    )
                } ?? []
            }.value
        } catch let error as BarcodeError {
            throw error
        } catch {
            throw BarcodeError.recognitionFailed(error.localizedDescription)
        }
    }
}

extension BarcodeSymbology {
    init(_ symbology: VNBarcodeSymbology, payload: String) {
        switch symbology {
        case .qr:
            self = .qr
        case .aztec:
            self = .aztec
        case .code128:
            self = .code128
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum:
            self = .code39
        case .dataMatrix:
            self = .dataMatrix
        case .ean13:
            // Vision reports UPC-A as EAN-13 with a leading zero because UPC-A
            // is a strict 12-digit subset of EAN-13.
            self = payload.count == 13 && payload.first == "0" ? .upca : .ean13
        case .pdf417:
            self = .pdf417
        default:
            self = .other
        }
    }
}
