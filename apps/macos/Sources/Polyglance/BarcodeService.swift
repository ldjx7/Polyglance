import AppKit
import CoreGraphics

protocol BarcodeRecognitionBackend: Sendable {
    func recognizeBarcodes(in image: CGImage) async throws -> [BarcodeObservation]
}

enum BarcodeError: LocalizedError, Equatable, Sendable {
    case invalidImage
    case notFound
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无法从图像中读取有效像素"
        case .notFound:
            return "未识别到条码"
        case let .recognitionFailed(message):
            return "条码识别失败：\(message)"
        }
    }
}

struct BarcodeService: Sendable {
    private let backend: any BarcodeRecognitionBackend

    init(backend: any BarcodeRecognitionBackend = VisionBarcodeBackend()) {
        self.backend = backend
    }

    func recognizeBarcodes(in image: NSImage) async throws -> [BarcodeObservation] {
        guard image.size.width.isFinite,
              image.size.height.isFinite,
              image.size.width > 0,
              image.size.height > 0 else {
            throw BarcodeError.invalidImage
        }

        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), cgImage.width > 0, cgImage.height > 0 else {
            throw BarcodeError.invalidImage
        }
        return try await recognizeBarcodes(in: cgImage)
    }

    func recognizeBarcodes(in image: CGImage) async throws -> [BarcodeObservation] {
        guard image.width > 0, image.height > 0 else {
            throw BarcodeError.invalidImage
        }

        let observations: [BarcodeObservation]
        do {
            observations = try await backend.recognizeBarcodes(in: image)
        } catch let error as BarcodeError {
            throw error
        } catch {
            throw BarcodeError.recognitionFailed(error.localizedDescription)
        }

        let prepared = Self.prepared(observations)
        guard !prepared.isEmpty else {
            throw BarcodeError.notFound
        }
        return prepared
    }

    /// Drops empty payloads and unusable boxes, removes exact duplicates, and
    /// sorts in reading order.
    ///
    /// The result is what the result card renders, so the ordering must be
    /// stable across runs of the same image. Swift's sort is not documented as
    /// stable, so boxes that tie on both axes break the tie by their original
    /// detection order rather than by luck.
    static func prepared(_ observations: [BarcodeObservation]) -> [BarcodeObservation] {
        var seenPayloads = Set<String>()
        let unitBox = CGRect(x: 0, y: 0, width: 1, height: 1)
        let usable: [(Int, BarcodeObservation)] = observations.enumerated().compactMap { index, observation in
            let payload = observation.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            let box = observation.boundingBox.standardized.intersection(unitBox)
            guard !payload.isEmpty,
                  isUsableNormalizedBox(box),
                  seenPayloads.insert(payload).inserted else {
                return nil
            }
            let corners = observation.corners?.map { point in
                CGPoint(
                    x: min(max(point.x, 0), 1),
                    y: min(max(point.y, 0), 1)
                )
            }
            return (
                index,
                BarcodeObservation(
                    payload: observation.payload,
                    symbology: observation.symbology,
                    boundingBox: box,
                    corners: corners
                )
            )
        }

        return usable
            .sorted { left, right in
                let leftBox = left.1.boundingBox
                let rightBox = right.1.boundingBox
                // Lower-left origin: "above" means a larger midY.
                if leftBox.midY != rightBox.midY {
                    return leftBox.midY > rightBox.midY
                }
                if leftBox.minX != rightBox.minX {
                    return leftBox.minX < rightBox.minX
                }
                return left.0 < right.0
            }
            .map { $0.1 }
    }

    private static func isUsableNormalizedBox(_ box: CGRect) -> Bool {
        let box = box.standardized
        return box.origin.x.isFinite
            && box.origin.y.isFinite
            && box.width.isFinite
            && box.height.isFinite
            && box.width > 0
            && box.height > 0
    }
}
