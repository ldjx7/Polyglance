import CoreGraphics
import Foundation

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

struct LongScreenshotStitcher {
    private struct PixelFrame {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        var byteCount: Int { bytes.count }
    }

    private struct OffsetScore {
        let offset: Int
        let score: Double
    }

    private let configuration: LongScreenshotConfiguration
    private var outputBytes: [UInt8] = []
    private var previousFrame: PixelFrame?
    private var didExtendOutput = false
    private var outputAxisOrigin = 0
    private var outputAxisEnd = 0
    private var previousFrameAxisOrigin = 0

    private(set) var frameCount = 0
    private(set) var outputWidth = 0
    private(set) var outputHeight = 0
    private(set) var currentFrameOffset = 0
    private(set) var direction: LongScreenshotDirection

    init(
        configuration: LongScreenshotConfiguration = .default,
        direction: LongScreenshotDirection = .vertical
    ) {
        self.configuration = configuration
        self.direction = direction
    }

    @discardableResult
    mutating func setDirection(_ direction: LongScreenshotDirection) -> Bool {
        guard !didExtendOutput else { return false }
        self.direction = direction
        outputAxisOrigin = 0
        outputAxisEnd = direction == .vertical ? outputHeight : outputWidth
        previousFrameAxisOrigin = 0
        currentFrameOffset = 0
        return true
    }

    mutating func append(_ image: CGImage) throws -> LongScreenshotAppendResult {
        try validateConfiguration()
        let frame = try Self.normalizedFrame(from: image)
        guard frame.width > 0, frame.height > 0 else {
            throw LongScreenshotStitchError.invalidFrame
        }
        if let previousFrame,
           frame.width != previousFrame.width || frame.height != previousFrame.height {
            throw LongScreenshotStitchError.frameDimensionsChanged
        }

        try validatePixelCount(
            width: max(outputWidth, frame.width),
            height: max(outputHeight, frame.height)
        )
        try validateWorkingMemory(
            outputByteCount: max(outputBytes.count, frame.byteCount),
            frameByteCount: frame.byteCount
        )

        if previousFrame == nil {
            frameCount = 1
            let acceptedWidth = min(frame.width, configuration.maximumOutputWidth)
            let acceptedHeight = min(frame.height, configuration.maximumOutputHeight)
            try validatePixelCount(width: acceptedWidth, height: acceptedHeight)
            outputBytes = Self.croppedBytes(
                from: frame,
                width: acceptedWidth,
                height: acceptedHeight
            )
            outputWidth = acceptedWidth
            outputHeight = acceptedHeight
            outputAxisOrigin = 0
            outputAxisEnd = direction == .vertical ? acceptedHeight : acceptedWidth
            previousFrameAxisOrigin = 0
            currentFrameOffset = 0
            previousFrame = frame
            return result(
                disposition: .initial,
                widthLimitReached: acceptedWidth < frame.width
                    || acceptedWidth == configuration.maximumOutputWidth,
                heightLimitReached: acceptedHeight < frame.height
                    || acceptedHeight == configuration.maximumOutputHeight
            )
        }

        let offset = try estimatedOffset(previous: previousFrame!, current: frame)
        previousFrame = frame
        if offset == 0 {
            return result(
                disposition: .unchanged,
                widthLimitReached: false,
                heightLimitReached: false
            )
        }
        return try extendOutput(with: frame, signedOffset: offset)
    }

    private mutating func extendOutput(
        with frame: PixelFrame,
        signedOffset: Int
    ) throws -> LongScreenshotAppendResult {
        let frameLength = direction == .vertical ? frame.height : frame.width
        let currentOrigin = previousFrameAxisOrigin + signedOffset
        let currentEnd = currentOrigin + frameLength
        let requestedBefore = max(0, outputAxisOrigin - currentOrigin)
        let requestedAfter = max(0, currentEnd - outputAxisEnd)
        previousFrameAxisOrigin = currentOrigin

        guard requestedBefore > 0 || requestedAfter > 0 else {
            currentFrameOffset = currentOrigin - outputAxisOrigin
            return result(
                disposition: .unchanged,
                widthLimitReached: false,
                heightLimitReached: false
            )
        }
        guard frameCount < configuration.maximumFrameCount else {
            throw LongScreenshotStitchError.frameLimitExceeded
        }
        frameCount += 1

        switch direction {
        case .vertical:
            let remainingRows = configuration.maximumOutputHeight - outputHeight
            let rowsBefore = min(requestedBefore, max(0, remainingRows))
            let rowsAfter = min(requestedAfter, max(0, remainingRows - rowsBefore))
            let proposedHeight = outputHeight + rowsBefore + rowsAfter
            try validatePixelCount(width: outputWidth, height: proposedHeight)
            try validateWorkingMemory(
                outputByteCount: proposedHeight * outputWidth * 4,
                frameByteCount: frame.byteCount
            )
            if rowsBefore > 0 {
                prependRows(
                    from: frame,
                    firstRow: requestedBefore - rowsBefore,
                    count: rowsBefore
                )
                outputAxisOrigin -= rowsBefore
            }
            if rowsAfter > 0 {
                appendRows(
                    from: frame,
                    firstRow: frame.height - requestedAfter,
                    count: rowsAfter
                )
                outputAxisEnd += rowsAfter
            }
            outputHeight = proposedHeight
            didExtendOutput = didExtendOutput || rowsBefore > 0 || rowsAfter > 0
            currentFrameOffset = currentOrigin - outputAxisOrigin
            return result(
                disposition: .appended(direction: .vertical, offset: signedOffset),
                widthLimitReached: false,
                heightLimitReached: rowsBefore < requestedBefore
                    || rowsAfter < requestedAfter
                    || outputHeight == configuration.maximumOutputHeight
            )
        case .horizontal:
            let remainingColumns = configuration.maximumOutputWidth - outputWidth
            let columnsBefore = min(requestedBefore, max(0, remainingColumns))
            let columnsAfter = min(requestedAfter, max(0, remainingColumns - columnsBefore))
            let proposedWidth = outputWidth + columnsBefore + columnsAfter
            try validatePixelCount(width: proposedWidth, height: outputHeight)
            try validateWorkingMemory(
                outputByteCount: proposedWidth * outputHeight * 4,
                frameByteCount: frame.byteCount
            )
            if columnsBefore > 0 {
                prependColumns(
                    from: frame,
                    firstColumn: requestedBefore - columnsBefore,
                    count: columnsBefore
                )
                outputAxisOrigin -= columnsBefore
            }
            if columnsAfter > 0 {
                appendColumns(
                    from: frame,
                    firstColumn: frame.width - requestedAfter,
                    count: columnsAfter
                )
                outputAxisEnd += columnsAfter
            }
            outputWidth = proposedWidth
            didExtendOutput = didExtendOutput || columnsBefore > 0 || columnsAfter > 0
            currentFrameOffset = currentOrigin - outputAxisOrigin
            return result(
                disposition: .appended(direction: .horizontal, offset: signedOffset),
                widthLimitReached: columnsBefore < requestedBefore
                    || columnsAfter < requestedAfter
                    || outputWidth == configuration.maximumOutputWidth,
                heightLimitReached: false
            )
        }
    }

    func render() throws -> CGImage {
        guard outputWidth > 0, outputHeight > 0, !outputBytes.isEmpty else {
            throw LongScreenshotStitchError.noFrames
        }
        guard let provider = CGDataProvider(data: Data(outputBytes) as CFData),
              let image = CGImage(
                  width: outputWidth,
                  height: outputHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: outputWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw LongScreenshotStitchError.imageCreationFailed
        }
        return image
    }

    func renderPreview(
        maximumPixelWidth: Int = 220,
        maximumPixelHeight: Int = 1_600
    ) throws -> CGImage {
        guard outputWidth > 0, outputHeight > 0, !outputBytes.isEmpty else {
            throw LongScreenshotStitchError.noFrames
        }
        guard maximumPixelWidth > 0, maximumPixelHeight > 0 else {
            throw LongScreenshotStitchError.invalidConfiguration
        }
        let scale = min(
            1,
            Double(maximumPixelWidth) / Double(outputWidth),
            Double(maximumPixelHeight) / Double(outputHeight)
        )
        let previewWidth = max(1, Int((Double(outputWidth) * scale).rounded()))
        let previewHeight = max(1, Int((Double(outputHeight) * scale).rounded()))
        var previewBytes = [UInt8](repeating: 0, count: previewWidth * previewHeight * 4)
        for targetY in 0 ..< previewHeight {
            let sourceY = min(
                outputHeight - 1,
                Int(Double(targetY) * Double(outputHeight) / Double(previewHeight))
            )
            for targetX in 0 ..< previewWidth {
                let sourceX = min(
                    outputWidth - 1,
                    Int(Double(targetX) * Double(outputWidth) / Double(previewWidth))
                )
                let sourceIndex = (sourceY * outputWidth + sourceX) * 4
                let targetIndex = (targetY * previewWidth + targetX) * 4
                previewBytes[targetIndex ..< targetIndex + 4] = outputBytes[sourceIndex ..< sourceIndex + 4]
            }
        }
        guard let provider = CGDataProvider(data: Data(previewBytes) as CFData),
              let image = CGImage(
                  width: previewWidth,
                  height: previewHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: previewWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw LongScreenshotStitchError.imageCreationFailed
        }
        return image
    }

    private func result(
        disposition: LongScreenshotAppendDisposition,
        widthLimitReached: Bool,
        heightLimitReached: Bool
    ) -> LongScreenshotAppendResult {
        let limit: LongScreenshotLimit?
        if widthLimitReached {
            limit = .outputWidth
        } else if heightLimitReached {
            limit = .outputHeight
        } else if frameCount >= configuration.maximumFrameCount,
                  disposition != .unchanged {
            limit = .frameCount
        } else {
            limit = nil
        }
        return LongScreenshotAppendResult(
            disposition: disposition,
            frameCount: frameCount,
            totalWidth: outputWidth,
            totalHeight: outputHeight,
            limitReached: limit
        )
    }

    private func validateConfiguration() throws {
        guard configuration.captureInterval > 0,
              configuration.maximumFrameCount > 0,
              configuration.maximumOutputWidth > 0,
              configuration.maximumOutputHeight > 0,
              configuration.maximumPixelCount > 0,
              configuration.maximumWorkingBytes > 0,
              configuration.minimumOverlapRows > 0,
              configuration.maximumScrollFraction > 0,
              configuration.maximumScrollFraction < 1,
              configuration.matchThreshold >= 0,
              configuration.matchThreshold < 1 else {
            throw LongScreenshotStitchError.invalidConfiguration
        }
    }

    private func validatePixelCount(width: Int, height: Int) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= configuration.maximumPixelCount else {
            throw LongScreenshotStitchError.pixelLimitExceeded
        }
    }

    private func validateWorkingMemory(outputByteCount: Int, frameByteCount: Int) throws {
        let (twoFrames, frameOverflow) = frameByteCount.multipliedReportingOverflow(by: 2)
        let (estimatedBytes, totalOverflow) = outputByteCount.addingReportingOverflow(twoFrames)
        guard !frameOverflow,
              !totalOverflow,
              estimatedBytes <= configuration.maximumWorkingBytes else {
            throw LongScreenshotStitchError.workingMemoryLimitExceeded
        }
    }

    private func estimatedOffset(
        previous: PixelFrame,
        current: PixelFrame
    ) throws -> Int {
        let unchangedScore = Self.mismatchScore(
            previous: previous,
            current: current,
            direction: direction,
            offset: 0
        )
        if unchangedScore <= configuration.matchThreshold {
            return 0
        }

        let length = direction == .vertical ? previous.height : previous.width
        let fractionLimit = Int((Double(length) * configuration.maximumScrollFraction).rounded(.down))
        let overlapLimit = length - configuration.minimumOverlapRows
        let maximumOffset = min(fractionLimit, overlapLimit)
        guard maximumOffset >= 1 else {
            throw LongScreenshotStitchError.noReliableVerticalOverlap
        }

        var best: OffsetScore?
        for distance in 1 ... maximumOffset {
            for offset in [distance, -distance] {
                let score = Self.mismatchScore(
                    previous: previous,
                    current: current,
                    direction: direction,
                    offset: offset
                )
                if let currentBest = best {
                    if score < currentBest.score - 0.000_001
                        || abs(score - currentBest.score) <= 0.000_001
                            && abs(offset) < abs(currentBest.offset) {
                        best = OffsetScore(offset: offset, score: score)
                    }
                } else {
                    best = OffsetScore(offset: offset, score: score)
                }
            }
        }
        guard let best, best.score <= configuration.matchThreshold else {
            throw LongScreenshotStitchError.noReliableVerticalOverlap
        }
        return best.offset
    }

    private static func mismatchScore(
        previous: PixelFrame,
        current: PixelFrame,
        direction: LongScreenshotDirection,
        offset: Int
    ) -> Double {
        if direction == .vertical {
            return globalMismatchScore(
                previous: previous,
                current: current,
                direction: direction,
                offset: offset
            )
        }
        let distance = abs(offset)
        let overlapWidth = previous.width - (direction == .horizontal ? distance : 0)
        let overlapHeight = previous.height - (direction == .vertical ? distance : 0)
        guard overlapWidth > 0, overlapHeight > 0 else { return 1 }
        let horizontalInset = previous.width >= 20 ? previous.width / 20 : 0
        let verticalInset = previous.height >= 20 ? previous.height / 20 : 0
        let sampledWidth = max(1, overlapWidth - horizontalInset * 2)
        let sampledHeight = max(1, overlapHeight - verticalInset * 2)
        let columnStride = max(1, sampledWidth / 96)
        let rowStride = max(1, sampledHeight / 96)
        var sliceScores: [Double] = []
        switch direction {
        case .vertical:
            var row = verticalInset
            let maximumRow = verticalInset + sampledHeight
            while row < maximumRow {
                var difference = 0
                var channelCount = 0
                let previousRow = row + max(offset, 0)
                let currentRow = row + max(-offset, 0)
                var column = horizontalInset
                let maximumColumn = horizontalInset + sampledWidth
                while column < maximumColumn {
                    let previousIndex = (previousRow * previous.width + column) * 4
                    let currentIndex = (currentRow * current.width + column) * 4
                    difference += Self.rgbDifference(
                        previous.bytes,
                        previousIndex,
                        current.bytes,
                        currentIndex
                    )
                    channelCount += 3
                    column += columnStride
                }
                sliceScores.append(Double(difference) / Double(max(1, channelCount) * 255))
                row += rowStride
            }
        case .horizontal:
            var column = horizontalInset
            let maximumColumn = horizontalInset + sampledWidth
            while column < maximumColumn {
                var difference = 0
                var channelCount = 0
                let previousColumn = column + max(offset, 0)
                let currentColumn = column + max(-offset, 0)
                var row = verticalInset
                let maximumRow = verticalInset + sampledHeight
                while row < maximumRow {
                    let previousIndex = (row * previous.width + previousColumn) * 4
                    let currentIndex = (row * current.width + currentColumn) * 4
                    difference += Self.rgbDifference(
                        previous.bytes,
                        previousIndex,
                        current.bytes,
                        currentIndex
                    )
                    channelCount += 3
                    row += rowStride
                }
                sliceScores.append(Double(difference) / Double(max(1, channelCount) * 255))
                column += columnStride
            }
        }
        return Self.robustMean(sliceScores)
    }

    private static func globalMismatchScore(
        previous: PixelFrame,
        current: PixelFrame,
        direction: LongScreenshotDirection,
        offset: Int
    ) -> Double {
        let distance = abs(offset)
        let overlapWidth = previous.width - (direction == .horizontal ? distance : 0)
        let overlapHeight = previous.height - (direction == .vertical ? distance : 0)
        guard overlapWidth > 0, overlapHeight > 0 else { return 1 }
        let horizontalInset = previous.width >= 20 ? previous.width / 20 : 0
        let verticalInset = previous.height >= 20 ? previous.height / 20 : 0
        let sampledWidth = max(1, overlapWidth - horizontalInset * 2)
        let sampledHeight = max(1, overlapHeight - verticalInset * 2)
        let columnStride = max(1, sampledWidth / 96)
        let rowStride = max(1, sampledHeight / 96)
        var difference = 0
        var channelCount = 0
        var row = verticalInset
        let maximumRow = verticalInset + sampledHeight
        while row < maximumRow {
            let previousRow = row + (direction == .vertical ? max(offset, 0) : 0)
            let currentRow = row + (direction == .vertical ? max(-offset, 0) : 0)
            var column = horizontalInset
            let maximumColumn = horizontalInset + sampledWidth
            while column < maximumColumn {
                let previousColumn = column + (direction == .horizontal ? max(offset, 0) : 0)
                let currentColumn = column + (direction == .horizontal ? max(-offset, 0) : 0)
                let previousIndex = (previousRow * previous.width + previousColumn) * 4
                let currentIndex = (currentRow * current.width + currentColumn) * 4
                difference += rgbDifference(
                    previous.bytes,
                    previousIndex,
                    current.bytes,
                    currentIndex
                )
                channelCount += 3
                column += columnStride
            }
            row += rowStride
        }
        guard channelCount > 0 else { return 1 }
        return Double(difference) / Double(channelCount * 255)
    }

    private static func rgbDifference(
        _ previous: [UInt8],
        _ previousIndex: Int,
        _ current: [UInt8],
        _ currentIndex: Int
    ) -> Int {
        abs(Int(previous[previousIndex]) - Int(current[currentIndex]))
            + abs(Int(previous[previousIndex + 1]) - Int(current[currentIndex + 1]))
            + abs(Int(previous[previousIndex + 2]) - Int(current[currentIndex + 2]))
    }

    private static func robustMean(_ scores: [Double]) -> Double {
        guard !scores.isEmpty else { return 1 }
        let sorted = scores.sorted()
        let retainedCount = max(1, Int(ceil(Double(sorted.count) * 0.65)))
        return sorted.prefix(retainedCount).reduce(0, +) / Double(retainedCount)
    }

    private mutating func appendColumns(
        from frame: PixelFrame,
        firstColumn: Int,
        count: Int
    ) {
        let oldWidth = outputWidth
        let newWidth = oldWidth + count
        var combined = [UInt8]()
        combined.reserveCapacity(newWidth * outputHeight * 4)
        for row in 0 ..< outputHeight {
            let existingStart = row * oldWidth * 4
            combined.append(contentsOf: outputBytes[existingStart ..< existingStart + oldWidth * 4])
            let newStart = (row * frame.width + firstColumn) * 4
            combined.append(contentsOf: frame.bytes[newStart ..< newStart + count * 4])
        }
        outputBytes = combined
    }

    private mutating func prependColumns(
        from frame: PixelFrame,
        firstColumn: Int,
        count: Int
    ) {
        let oldWidth = outputWidth
        let newWidth = oldWidth + count
        var combined = [UInt8]()
        combined.reserveCapacity(newWidth * outputHeight * 4)
        for row in 0 ..< outputHeight {
            let newStart = (row * frame.width + firstColumn) * 4
            combined.append(contentsOf: frame.bytes[newStart ..< newStart + count * 4])
            let existingStart = row * oldWidth * 4
            combined.append(contentsOf: outputBytes[existingStart ..< existingStart + oldWidth * 4])
        }
        outputBytes = combined
    }

    private mutating func appendRows(
        from frame: PixelFrame,
        firstRow: Int,
        count: Int
    ) {
        for row in firstRow ..< firstRow + count {
            let start = row * frame.width * 4
            outputBytes.append(contentsOf: frame.bytes[start ..< start + outputWidth * 4])
        }
    }

    private mutating func prependRows(
        from frame: PixelFrame,
        firstRow: Int,
        count: Int
    ) {
        var prefix = [UInt8]()
        prefix.reserveCapacity(count * outputWidth * 4)
        for row in firstRow ..< firstRow + count {
            let start = row * frame.width * 4
            prefix.append(contentsOf: frame.bytes[start ..< start + outputWidth * 4])
        }
        prefix.append(contentsOf: outputBytes)
        outputBytes = prefix
    }

    private static func croppedBytes(
        from frame: PixelFrame,
        width: Int,
        height: Int
    ) -> [UInt8] {
        if width == frame.width, height == frame.height {
            return frame.bytes
        }
        var cropped = [UInt8]()
        cropped.reserveCapacity(width * height * 4)
        for row in 0 ..< height {
            let start = row * frame.width * 4
            cropped.append(contentsOf: frame.bytes[start ..< start + width * 4])
        }
        return cropped
    }

    private static func normalizedFrame(from image: CGImage) throws -> PixelFrame {
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
            return PixelFrame(
                width: image.width,
                height: image.height,
                bytes: Array(sourceData.prefix(byteCount))
            )
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
        return PixelFrame(width: image.width, height: image.height, bytes: bytes)
    }
}
