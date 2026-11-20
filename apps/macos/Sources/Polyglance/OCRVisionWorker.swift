import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum VisionOCRWorker {
    static let argument = "--vision-ocr-worker"
    private static let foregroundQueue = DispatchQueue(label: "io.polyglance.vision-ocr", qos: .userInitiated)
    private static let backgroundQueue = DispatchQueue(label: "io.polyglance.vision-ocr.background", qos: .utility)
    private static let timeout: DispatchTimeInterval = .seconds(120)

    final class RequestControl: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: (any Error)?
        private var process: Process?
        private var discarded = false

        func check() throws {
            try lock.withLock {
                if let failure { throw failure }
                if discarded { throw CancellationError() }
            }
        }

        func run(_ process: Process) throws {
            try lock.withLock {
                if let failure { throw failure }
                if discarded { throw CancellationError() }
                try process.run()
                self.process = process
            }
        }

        func clearProcess() {
            lock.withLock { process = nil }
        }

        func discardAfterFallback() {
            lock.withLock { discarded = true }
        }

        func stop(with failure: any Error) {
            lock.withLock {
                guard self.failure == nil else { return }
                self.failure = failure
                if let process, process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    private enum Response: Codable {
        case recognized([OCRTextObservation])
        case invalidImage
        case failed(message: String, retryable: Bool)
    }

    static func recognize(
        in image: CGImage,
        diagnostics: OCRDiagnostics,
        control: RequestControl = RequestControl()
    ) async throws -> [OCRTextObservation] {
        let timeout = DispatchWorkItem {
            control.stop(with: OCRError.visionFailed("文字识别超时"))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: timeout)
        defer { timeout.cancel() }

        let queue = diagnostics.isBackground ? backgroundQueue : foregroundQueue
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let outcome = Result {
                        try recognize(in: image, diagnostics: diagnostics, control: control)
                    }
                    do {
                        try control.check()
                        continuation.resume(with: outcome)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            control.stop(with: CancellationError())
        }
    }

    private static func recognize(
        in image: CGImage,
        diagnostics: OCRDiagnostics,
        control: RequestControl
    ) throws -> [OCRTextObservation] {
        try control.check()
        diagnostics.record("vision.worker.dequeued", ["background": diagnostics.isBackground])
        let imageData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil) else {
            throw OCRError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw OCRError.invalidImage }

        let data = imageData as Data
        var response = try request(data, diagnostics: diagnostics, control: control)
        if case .failed(_, true) = response {
            diagnostics.record("vision.worker.retry")
            response = try request(data, diagnostics: diagnostics, control: control)
        }

        switch response {
        case let .recognized(observations): return observations
        case .invalidImage: throw OCRError.invalidImage
        case let .failed(message, _): throw OCRError.visionFailed(message)
        }
    }

    private static func request(
        _ data: Data,
        diagnostics: OCRDiagnostics,
        control: RequestControl
    ) throws -> Response {
        let bundle = Bundle(for: AppDelegate.self)
        let executable = bundle.bundleURL.pathExtension == "xctest"
            ? bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("Polyglance")
            : bundle.executableURL
        guard let executable else { throw OCRError.visionFailed("找不到文字识别程序") }

        let input = Pipe()
        let output = Pipe()
        let writer = input.fileHandleForWriting
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw OCRError.visionFailed("无法创建文字识别通道")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, diagnostics.source, diagnostics.id]
        process.standardInput = input
        process.standardOutput = output
        process.qualityOfService = diagnostics.isBackground || diagnostics.source == "vision.prewarm"
            ? .utility : .userInitiated
        try control.run(process)
        defer {
            control.clearProcess()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        diagnostics.record("vision.worker.started", ["workerPID": process.processIdentifier])

        try writer.write(contentsOf: data)
        try writer.close()
        let responseData = try output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        diagnostics.record("vision.worker.exited", ["workerPID": process.processIdentifier, "status": process.terminationStatus])
        guard process.terminationStatus == 0, let responseData else {
            throw OCRError.visionFailed("文字识别进程异常退出")
        }
        return try PropertyListDecoder().decode(Response.self, from: responseData)
    }

    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { return EXIT_FAILURE }
        let diagnostics = OCRDiagnostics(source: arguments[2], id: arguments[3])
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else { return EXIT_FAILURE }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else { return EXIT_FAILURE }

        do {
            let data = try FileHandle.standardInput.readToEnd() ?? Data()
            let response: Response
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                do {
                    response = .recognized(try VisionOCRBackend.performRecognition(in: image, diagnostics: diagnostics))
                } catch {
                    let failure = error as NSError
                    response = .failed(
                        message: failure.localizedDescription,
                        retryable: failure.domain == "TextRecognition.CRImageReaderError" && failure.code == 1
                    )
                }
            } else {
                response = .invalidImage
            }
            try writer.write(contentsOf: PropertyListEncoder().encode(response))
            return EXIT_SUCCESS
        } catch {
            diagnostics.recordError(error, stage: "vision.worker")
            return EXIT_FAILURE
        }
    }
}
