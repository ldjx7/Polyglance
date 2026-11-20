import CoreGraphics
import CoreText
import Foundation
import TranslatorCore

enum ResilientOCR {
    private typealias Recognition = Result<[OCRTextObservation], any Error>

    private enum Event: Sendable {
        case startFallback
        case vision(Recognition)
        case fallback(Recognition)
    }

    private final class FallbackQueue: @unchecked Sendable {
        private let queue = DispatchQueue(label: "io.polyglance.offline-ocr", qos: .userInitiated)
        private let lock = NSLock()
        private var isStopping = false

        func submit(_ work: DispatchWorkItem) -> Bool {
            lock.withLock {
                guard !isStopping else { return false }
                queue.async {
                    guard !self.lock.withLock({ self.isStopping }) else {
                        work.cancel()
                        return
                    }
                    work.perform()
                }
                return true
            }
        }

        func stop() async {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    isStopping = true
                    queue.async { continuation.resume() }
                }
            }
        }
    }

    private static let fallbackQueue = FallbackQueue()
    private static let modelDirectory = Bundle.main.resourceURL?.appendingPathComponent("OCRModels")
    private static let runtime = Bundle.main.privateFrameworksURL?.appendingPathComponent("libonnxruntime.dylib")
    private static let fallbackAvailable = modelDirectory.map {
        FileManager.default.fileExists(atPath: $0.path)
    } == true && runtime.map { FileManager.default.fileExists(atPath: $0.path) } == true
    private static let engine = Result {
        guard let modelDirectory, let runtime else { throw OCRError.visionFailed("备用识别模型不可用") }
        return try OfflineOcrEngine(libraryPath: runtime.path, modelDirectory: modelDirectory.path)
    }

    static func prewarm() {
        guard fallbackAvailable else { return }
        _ = fallbackQueue.submit(DispatchWorkItem(qos: .utility) {
            let diagnostics = OCRDiagnostics(source: "ppocr.prewarm")
            do {
                _ = try engine.get()
                diagnostics.record("ppocr.ready")
            } catch {
                diagnostics.recordError(error, stage: "ppocr.prewarm")
            }
        })
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard let image = makeWarmupImage() else { return }
            let diagnostics = OCRDiagnostics(source: "vision.prewarm")
            do {
                _ = try await VisionOCRWorker.recognize(in: image, diagnostics: diagnostics)
            } catch {
                diagnostics.recordError(error, stage: "vision.prewarm")
            }
        }
    }

    static func prepareForTermination() async {
        await fallbackQueue.stop()
    }

    static func recognize(in image: CGImage, diagnostics: OCRDiagnostics) async throws -> [OCRTextObservation] {
        guard fallbackAvailable, !diagnostics.isBackground else {
            return try await VisionOCRWorker.recognize(in: image, diagnostics: diagnostics)
        }
        try Task.checkCancellation()

        let (events, send) = AsyncStream<Event>.makeStream()
        let control = VisionOCRWorker.RequestControl()
        let visionTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try await VisionOCRWorker.recognize(in: image, diagnostics: diagnostics, control: control)
                send.yield(.vision(.success(result)))
            } catch {
                send.yield(.vision(.failure(error)))
            }
        }
        let timer = Task.detached {
            do {
                try await Task.sleep(for: .seconds(1))
                send.yield(.startFallback)
            } catch is CancellationError {
                return
            }
        }
        var fallback: DispatchWorkItem?
        var visionResult: Recognition?
        var fallbackFinished = false
        var keepVisionRunning = false
        defer {
            send.finish()
            timer.cancel()
            fallback?.cancel()
            if keepVisionRunning {
                control.discardAfterFallback()
            } else {
                visionTask.cancel()
            }
        }

        func startFallback() {
            guard fallback == nil else { return }
            diagnostics.record("ppocr.scheduled")
            let work = DispatchWorkItem {
                send.yield(.fallback(Result {
                    try recognizeOffline(in: image, diagnostics: diagnostics)
                }))
            }
            fallback = work
            if !fallbackQueue.submit(work) {
                send.yield(.fallback(.failure(CancellationError())))
            }
        }

        for await event in events {
            try Task.checkCancellation()
            switch event {
            case .startFallback:
                startFallback()
            case let .vision(result):
                if let observations = usableResult(result) {
                    return observations
                }
                if fallbackFinished {
                    return try result.get()
                }
                visionResult = result
                startFallback()
            case let .fallback(result):
                if let observations = usableResult(result) {
                    keepVisionRunning = visionResult == nil
                    diagnostics.record("ppocr.selected", ["observations": observations.count])
                    return observations
                }
                if case let .failure(error) = result {
                    diagnostics.recordError(error, stage: "ppocr")
                }
                if let visionResult {
                    return try visionResult.get()
                }
                fallbackFinished = true
            }
        }
        throw CancellationError()
    }

    private static func usableResult(_ result: Recognition) -> [OCRTextObservation]? {
        guard let observations = try? result.get(),
              observations.contains(where: {
                  !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && OCRService.isUsableNormalizedBox($0.boundingBox)
              }) else { return nil }
        return observations
    }

    private static func recognizeOffline(in image: CGImage, diagnostics: OCRDiagnostics) throws -> [OCRTextObservation] {
        diagnostics.record("ppocr.perform.begin")
        let scale = min(1, 2560 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var pixels = Data(count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(bounds)
            context.interpolationQuality = .medium
            context.draw(image, in: bounds)
            return true
        }
        guard rendered else { throw OCRError.invalidImage }

        let lines = try engine.get().recognize(rgba: pixels, width: UInt32(width), height: UInt32(height))
        diagnostics.record("ppocr.perform.end", ["observations": lines.count])
        return lines.map { line in
            let box = CGRect(
                x: line.left, y: 1 - line.top - line.height,
                width: line.width, height: line.height
            )
            return OCRTextObservation(
                text: line.text,
                boundingBox: box,
                fragments: VisionOCRBackend.selectableFragments(observationBox: box, cleanedText: line.text)
            )
        }
    }

    private static func makeWarmupImage() -> CGImage? {
        let width = 320
        let height = 64
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: "Polyglance 文字認識 한글", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 12, y: 20)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }
}
