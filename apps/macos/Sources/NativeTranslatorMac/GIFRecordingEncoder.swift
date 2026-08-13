import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFRecordingLimits: Equatable, Sendable {
    let frameRate: Int
    let maxDimension: Int
    let maxDuration: TimeInterval
    let maxFrames: Int
    let maxDecodedFrameBytes: Int
    let maxTemporaryBytes: Int

    init(
        frameRate: Int,
        maxDimension: Int,
        maxDuration: TimeInterval,
        maxFrames: Int,
        maxDecodedFrameBytes: Int,
        maxTemporaryBytes: Int
    ) {
        self.frameRate = min(20, max(1, frameRate))
        self.maxDimension = max(1, maxDimension)
        self.maxDuration = max(0.1, maxDuration)
        self.maxFrames = max(1, maxFrames)
        self.maxDecodedFrameBytes = max(4, maxDecodedFrameBytes)
        self.maxTemporaryBytes = max(1_024, maxTemporaryBytes)
    }
}

enum GIFRecordingError: LocalizedError, Equatable {
    case invalidTimestamp
    case frameTooLarge
    case durationLimitExceeded
    case frameLimitExceeded
    case temporaryStorageLimitExceeded
    case temporaryDirectoryCreationFailed(String)
    case frameWriteFailed
    case frameReadFailed
    case noFrames
    case destinationCreationFailed
    case finalizeFailed

    var errorDescription: String? {
        switch self {
        case .invalidTimestamp:
            return "GIF 录制收到无效的画面时间戳"
        case .frameTooLarge:
            return "GIF 画面尺寸超过当前质量档允许的上限"
        case .durationLimitExceeded:
            return "GIF 已达到当前质量档的最长录制时间"
        case .frameLimitExceeded:
            return "GIF 已达到当前质量档的最大帧数"
        case .temporaryStorageLimitExceeded:
            return "GIF 临时帧超过 1 GB 安全上限，请缩小区域或降低质量"
        case let .temporaryDirectoryCreationFailed(message):
            return "无法创建 GIF 临时目录：\(message)"
        case .frameWriteFailed:
            return "无法写入 GIF 临时画面"
        case .frameReadFailed:
            return "无法读取 GIF 临时画面"
        case .noFrames:
            return "没有捕获到可用于 GIF 的画面"
        case .destinationCreationFailed:
            return "无法创建 GIF 文件"
        case .finalizeFailed:
            return "无法完成 GIF 文件"
        }
    }
}

/// Incremental, bounded-memory GIF encoder.
///
/// ImageIO requires the final image count when a destination is created. To
/// avoid retaining every decoded frame in RAM, accepted frames are written as
/// temporary PNG files. `finish()` streams those files one at a time into the
/// final GIF and then removes the temporary directory.
final class GIFRecordingEncoder {
    private let outputURL: URL
    private let limits: GIFRecordingLimits
    private let fileManager: FileManager
    private let frameDirectory: URL
    private var frameURLs: [URL] = []
    private var frameTimes: [CMTime] = []
    private var firstFrameTime: CMTime?
    private var lastFrameTime: CMTime?
    private var temporaryBytes = 0
    private var didFinish = false

    init(
        outputURL: URL,
        limits: GIFRecordingLimits,
        fileManager: FileManager = .default
    ) throws {
        self.outputURL = outputURL
        self.limits = limits
        self.fileManager = fileManager
        self.frameDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "com.native-translator.gif-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: frameDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw GIFRecordingError.temporaryDirectoryCreationFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func append(_ image: CGImage, at presentationTime: CMTime) throws -> Bool {
        guard presentationTime.isValid,
              presentationTime.isNumeric,
              presentationTime.seconds.isFinite else {
            throw GIFRecordingError.invalidTimestamp
        }
        guard max(image.width, image.height) <= limits.maxDimension else {
            throw GIFRecordingError.frameTooLarge
        }
        let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (decodedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow,
              !byteOverflow,
              decodedBytes <= limits.maxDecodedFrameBytes else {
            throw GIFRecordingError.frameTooLarge
        }

        let firstTime = firstFrameTime ?? presentationTime
        let elapsed = CMTimeSubtract(presentationTime, firstTime).seconds
        guard elapsed.isFinite, elapsed >= 0 else {
            throw GIFRecordingError.invalidTimestamp
        }
        guard elapsed <= limits.maxDuration + 0.001 else {
            throw GIFRecordingError.durationLimitExceeded
        }
        if let lastFrameTime {
            let interval = CMTimeSubtract(presentationTime, lastFrameTime).seconds
            guard interval.isFinite, interval >= 0 else {
                throw GIFRecordingError.invalidTimestamp
            }
            if interval + 0.000_1 < 1 / Double(limits.frameRate) {
                return false
            }
        }
        guard frameURLs.count < limits.maxFrames else {
            throw GIFRecordingError.frameLimitExceeded
        }

        let frameURL = frameDirectory.appendingPathComponent(
            String(format: "%06d.png", frameURLs.count),
            isDirectory: false
        )
        guard let destination = CGImageDestinationCreateWithURL(
            frameURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw GIFRecordingError.frameWriteFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let size = try? fileManager.attributesOfItem(atPath: frameURL.path)[.size] as? NSNumber else {
            try? fileManager.removeItem(at: frameURL)
            throw GIFRecordingError.frameWriteFailed
        }
        let frameBytes = size.intValue
        guard temporaryBytes <= limits.maxTemporaryBytes - frameBytes else {
            try? fileManager.removeItem(at: frameURL)
            throw GIFRecordingError.temporaryStorageLimitExceeded
        }

        temporaryBytes += frameBytes
        frameURLs.append(frameURL)
        frameTimes.append(presentationTime)
        firstFrameTime = firstTime
        lastFrameTime = presentationTime
        return true
    }

    func finish() throws {
        guard !didFinish else {
            return
        }
        guard !frameURLs.isEmpty else {
            throw GIFRecordingError.noFrames
        }
        try? fileManager.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameURLs.count,
            nil
        ) else {
            throw GIFRecordingError.destinationCreationFailed
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ],
        ] as CFDictionary)
        for (index, frameURL) in frameURLs.enumerated() {
            guard let source = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                try? fileManager.removeItem(at: outputURL)
                throw GIFRecordingError.frameReadFailed
            }
            let delay = frameDelay(at: index)
            let frameProperties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? fileManager.removeItem(at: outputURL)
            throw GIFRecordingError.finalizeFailed
        }
        didFinish = true
        cleanupTemporaryFrames()
    }

    func cancel() {
        try? fileManager.removeItem(at: outputURL)
        cleanupTemporaryFrames()
    }

    deinit {
        cleanupTemporaryFrames()
    }

    private func cleanupTemporaryFrames() {
        try? fileManager.removeItem(at: frameDirectory)
        frameURLs.removeAll(keepingCapacity: false)
        frameTimes.removeAll(keepingCapacity: false)
        temporaryBytes = 0
    }

    private func frameDelay(at index: Int) -> Double {
        let nominalDelay = 1 / Double(limits.frameRate)
        guard frameTimes.indices.contains(index),
              frameTimes.indices.contains(index + 1) else {
            return nominalDelay
        }
        let interval = CMTimeSubtract(frameTimes[index + 1], frameTimes[index]).seconds
        guard interval.isFinite, interval > 0 else {
            return nominalDelay
        }
        return interval
    }
}
