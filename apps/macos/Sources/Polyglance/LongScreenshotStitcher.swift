import CoreGraphics
import Foundation
import TranslatorCore

enum LongScreenshotLimit: Equatable {
    case outputWidth
    case outputHeight
    case frameCount
}

enum LongScreenshotAppendDisposition: Equatable {
    case initial
    case appended(direction: LongScreenshotDirection, offset: Int)
    case unchanged
}

struct LongScreenshotAppendResult: Equatable {
    let disposition: LongScreenshotAppendDisposition
    let frameCount: Int
    let totalWidth: Int
    let totalHeight: Int
    let limitReached: LongScreenshotLimit?
}

enum LongScreenshotStitchError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidFrame
    case frameDimensionsChanged
    case noReliableVerticalOverlap
    case pixelLimitExceeded
    case workingMemoryLimitExceeded
    case frameLimitExceeded
    case noFrames
    case imageCreationFailed

    init(_ failure: StitchFailure) {
        switch failure {
        case .InvalidConfiguration: self = .invalidConfiguration
        case .InvalidFrame: self = .invalidFrame
        case .FrameDimensionsChanged: self = .frameDimensionsChanged
        case .NoReliableVerticalOverlap: self = .noReliableVerticalOverlap
        case .PixelLimitExceeded: self = .pixelLimitExceeded
        case .WorkingMemoryLimitExceeded: self = .workingMemoryLimitExceeded
        case .FrameLimitExceeded: self = .frameLimitExceeded
        case .NoFrames: self = .noFrames
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "长截图配置无效"
        case .invalidFrame:
            return "采集帧无效"
        case .frameDimensionsChanged:
            return "长截图采集区域尺寸发生变化"
        case .noReliableVerticalOverlap:
            return "相邻帧之间没有可可靠识别的重叠区域"
        case .pixelLimitExceeded:
            return "长截图像素数量超过安全上限"
        case .workingMemoryLimitExceeded:
            return "长截图预计内存占用超过安全上限"
        case .frameLimitExceeded:
            return "长截图采集帧数已达到上限"
        case .noFrames:
            return "尚未采集到可生成长截图的画面"
        case .imageCreationFailed:
            return "无法生成长截图图片"
        }
    }
}

/// Thin forwarding layer over `capture-core`.
///
/// Only CGImage decoding and encoding stay here; overlap detection and frame
/// splicing live in Rust so every platform stitches identically.
struct LongScreenshotStitcher {
    private let stitcher: TranslatorCore.LongScreenshotStitcher

    init(
        configuration: LongScreenshotConfiguration = .default,
        direction: LongScreenshotDirection = .vertical
    ) {
        stitcher = TranslatorCore.LongScreenshotStitcher(
            configuration: configuration.captureValue,
            direction: direction.captureValue
        )
    }

    var frameCount: Int { Int(stitcher.frameCount()) }
    var outputWidth: Int { Int(stitcher.outputWidth()) }
    var outputHeight: Int { Int(stitcher.outputHeight()) }
    var currentFrameOffset: Int { Int(stitcher.currentFrameOffset()) }
    var direction: LongScreenshotDirection { stitcher.direction().stitchValue }

    @discardableResult
    func setDirection(_ direction: LongScreenshotDirection) -> Bool {
        stitcher.setDirection(direction: direction.captureValue)
    }

    func append(_ image: CGImage) throws -> LongScreenshotAppendResult {
        let bytes = try Self.normalizedBytes(from: image)
        do {
            let result = try stitcher.append(
                bytes: bytes,
                width: UInt32(image.width),
                height: UInt32(image.height)
            )
            return LongScreenshotAppendResult(
                disposition: result.disposition.stitchValue,
                frameCount: Int(result.frameCount),
                totalWidth: Int(result.totalWidth),
                totalHeight: Int(result.totalHeight),
                limitReached: result.limitReached.map { $0.stitchValue }
            )
        } catch let failure as StitchFailure {
            throw LongScreenshotStitchError(failure)
        }
    }

    func render() throws -> CGImage {
        let bytes: Data
        do {
            bytes = try stitcher.render()
        } catch let failure as StitchFailure {
            throw LongScreenshotStitchError(failure)
        }
        return try Self.makeImage(
            bytes: bytes,
            width: outputWidth,
            height: outputHeight,
            shouldInterpolate: false
        )
    }

    func renderPreview(
        maximumPixelWidth: Int = 220,
        maximumPixelHeight: Int = 1_600
    ) throws -> CGImage {
        let preview: StitchPreview
        do {
            preview = try stitcher.renderPreview(
                maximumPixelWidth: UInt32(max(0, maximumPixelWidth)),
                maximumPixelHeight: UInt32(max(0, maximumPixelHeight))
            )
        } catch let failure as StitchFailure {
            throw LongScreenshotStitchError(failure)
        }
        return try Self.makeImage(
            bytes: preview.bytes,
            width: Int(preview.width),
            height: Int(preview.height),
            shouldInterpolate: true
        )
    }

    private static func makeImage(
        bytes: Data,
        width: Int,
        height: Int,
        shouldInterpolate: Bool
    ) throws -> CGImage {
        guard width > 0, height > 0, !bytes.isEmpty else {
            throw LongScreenshotStitchError.noFrames
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: shouldInterpolate,
                  intent: .defaultIntent
              ) else {
            throw LongScreenshotStitchError.imageCreationFailed
        }
        return image
    }

    private static func normalizedBytes(from image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0 else {
            throw LongScreenshotStitchError.invalidFrame
        }
        let (pixelCount, pixelOverflow) = image.width.multipliedReportingOverflow(by: image.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, byteCount > 0 else {
            throw LongScreenshotStitchError.invalidFrame
        }

        let alphaInfo = image.alphaInfo
        if image.bitsPerComponent == 8,
           image.bitsPerPixel == 32,
           image.bytesPerRow == image.width * 4,
           alphaInfo == .premultipliedLast || alphaInfo == .last,
           let sourceData = image.dataProvider?.data as Data?,
           sourceData.count >= byteCount {
            return sourceData.prefix(byteCount)
        }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: 8,
                      bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
            return true
        }
        guard didDraw else {
            throw LongScreenshotStitchError.invalidFrame
        }
        return Data(bytes)
    }
}

private extension LongScreenshotConfiguration {
    var captureValue: StitchConfiguration {
        StitchConfiguration(
            captureInterval: captureInterval,
            maximumFrameCount: UInt32(max(0, maximumFrameCount)),
            maximumOutputWidth: UInt32(max(0, maximumOutputWidth)),
            maximumOutputHeight: UInt32(max(0, maximumOutputHeight)),
            maximumPixelCount: UInt64(max(0, maximumPixelCount)),
            maximumWorkingBytes: UInt64(max(0, maximumWorkingBytes)),
            minimumOverlapRows: UInt32(max(0, minimumOverlapRows)),
            maximumScrollFraction: maximumScrollFraction,
            matchThreshold: matchThreshold
        )
    }
}

private extension LongScreenshotDirection {
    var captureValue: StitchDirection {
        switch self {
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
    }
}

private extension StitchDirection {
    var stitchValue: LongScreenshotDirection {
        switch self {
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
    }
}

private extension StitchLimit {
    var stitchValue: LongScreenshotLimit {
        switch self {
        case .outputWidth: .outputWidth
        case .outputHeight: .outputHeight
        case .frameCount: .frameCount
        }
    }
}

private extension StitchDisposition {
    var stitchValue: LongScreenshotAppendDisposition {
        switch self {
        case .initial:
            return .initial
        case .unchanged:
            return .unchanged
        case let .appended(direction, offset):
            return .appended(direction: direction.stitchValue, offset: Int(offset))
        }
    }
}
