import AppKit

enum LongScreenshotSessionState: Equatable {
    case ready
    case capturing
    case paused
    case finished
    case cancelled
    case failed
}

@MainActor
protocol LongScreenshotScheduling: AnyObject {
    func schedule(
        every interval: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    )
    func pause()
    func resume()
    func invalidate()
}

@MainActor
final class LongScreenshotTaskScheduler: LongScreenshotScheduling {
    private var task: Task<Void, Never>?
    private var isPaused = false

    func schedule(
        every interval: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) {
        invalidate()
        isPaused = false
        let nanoseconds = UInt64(max(0.01, interval) * 1_000_000_000)
        task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled, self?.isPaused == false else {
                    continue
                }
                await operation()
            }
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func invalidate() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
final class LongScreenshotSession {
    private(set) var region: LongScreenshotCaptureRegion

    private let captureSource: any LongScreenshotFrameCapturing
    private let scheduler: any LongScreenshotScheduling
    private let configuration: LongScreenshotConfiguration
    private var stitcher: LongScreenshotStitcher
    private var isCaptureInFlight = false
    private var completedImage: NSImage?
    private var didNotifyCancellation = false
    private var recoverableFrameErrorCount = 0

    private(set) var state: LongScreenshotSessionState = .ready {
        didSet {
            guard oldValue != state else {
                return
            }
            onStateChanged?(state)
        }
    }
    private(set) var direction: LongScreenshotDirection

    var onStateChanged: ((LongScreenshotSessionState) -> Void)?
    var onDirectionChanged: ((LongScreenshotDirection) -> Void)?
    var onPreviewChanged: ((LongScreenshotPreview) -> Void)?
    var onFinished: ((NSImage) -> Void)?
    var onCancelled: (() -> Void)?
    var onFailed: ((Error) -> Void)?
    var onRecoverableFrameError: ((Error) -> Void)?

    init(
        region: LongScreenshotCaptureRegion,
        captureSource: any LongScreenshotFrameCapturing,
        scheduler: any LongScreenshotScheduling,
        configuration: LongScreenshotConfiguration = .default,
        direction: LongScreenshotDirection = .vertical
    ) {
        self.region = region
        self.captureSource = captureSource
        self.scheduler = scheduler
        self.configuration = configuration
        self.direction = direction
        stitcher = LongScreenshotStitcher(configuration: configuration, direction: direction)
    }

    func start() async {
        guard state == .ready else {
            return
        }
        state = .capturing
        await captureNextFrame()
        guard state == .capturing else {
            return
        }
        scheduler.schedule(every: configuration.captureInterval) { [weak self] in
            await self?.captureNextFrame()
        }
    }

    @discardableResult
    func updateRegion(_ region: LongScreenshotCaptureRegion) -> Bool {
        guard state == .ready else { return false }
        self.region = region
        return true
    }

    @discardableResult
    func setDirection(_ direction: LongScreenshotDirection) -> Bool {
        guard state == .capturing || state == .paused,
              stitcher.setDirection(direction) else {
            return false
        }
        self.direction = direction
        onDirectionChanged?(direction)
        return true
    }

    func pause() {
        guard state == .capturing else {
            return
        }
        scheduler.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else {
            return
        }
        scheduler.resume()
        state = .capturing
    }

    @discardableResult
    func finish() throws -> NSImage {
        if let completedImage {
            return completedImage
        }
        guard state == .capturing || state == .paused else {
            throw LongScreenshotStitchError.noFrames
        }
        return try complete()
    }

    func cancel() {
        guard state != .cancelled, state != .finished, state != .failed else {
            return
        }
        scheduler.invalidate()
        state = .cancelled
        guard !didNotifyCancellation else {
            return
        }
        didNotifyCancellation = true
        onCancelled?()
    }

    private func captureNextFrame() async {
        guard state == .capturing, !isCaptureInFlight else {
            return
        }
        isCaptureInFlight = true
        defer { isCaptureInFlight = false }

        do {
            let frame = try await captureSource.capture(region: region)
            guard state == .capturing || state == .paused else {
                return
            }
            let result = try stitcher.append(frame)
            publishPreview(viewportPixelHeight: frame.height)
            if result.limitReached != nil {
                _ = try complete()
            }
        } catch let error as LongScreenshotStitchError
            where error == .noReliableVerticalOverlap {
            recoverableFrameErrorCount += 1
            onRecoverableFrameError?(error)
            if stitcher.frameCount + recoverableFrameErrorCount
                >= configuration.maximumFrameCount {
                do {
                    _ = try complete()
                } catch {
                    fail(error)
                }
            }
        } catch {
            guard state != .cancelled else {
                return
            }
            fail(error)
        }
    }

    private func publishPreview(viewportPixelHeight: Int) {
        guard let previewImage = try? stitcher.renderPreview() else { return }
        let representation = NSBitmapImageRep(cgImage: previewImage)
        let image = NSImage(size: CGSize(width: previewImage.width, height: previewImage.height))
        image.addRepresentation(representation)
        onPreviewChanged?(LongScreenshotPreview(
            image: image,
            direction: direction,
            frameCount: stitcher.frameCount,
            totalPixelWidth: stitcher.outputWidth,
            totalPixelHeight: stitcher.outputHeight,
            viewportPixelWidth: region.pixelWidth,
            viewportPixelHeight: viewportPixelHeight,
            viewportPixelOffset: stitcher.currentFrameOffset
        ))
    }

    private func complete() throws -> NSImage {
        if let completedImage {
            return completedImage
        }
        let cgImage = try stitcher.render()
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: CGSize(width: cgImage.width, height: cgImage.height))
        image.addRepresentation(representation)
        scheduler.invalidate()
        completedImage = image
        state = .finished
        onFinished?(image)
        return image
    }

    private func fail(_ error: Error) {
        scheduler.invalidate()
        state = .failed
        onFailed?(error)
    }
}
