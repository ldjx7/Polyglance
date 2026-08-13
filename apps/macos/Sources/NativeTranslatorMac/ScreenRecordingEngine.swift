import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

protocol ScreenRecordingEngineDelegate: AnyObject {
    func screenRecordingEngine(_ engine: ScreenRecordingEngine, didFail error: Error)
    func screenRecordingEngineDidReachLimit(_ engine: ScreenRecordingEngine)
}

final class ScreenRecordingEngine: NSObject, @unchecked Sendable {
    weak var delegate: ScreenRecordingEngineDelegate?

    private let outputURL: URL
    private let display: SCDisplay
    private let excludingApplications: [SCRunningApplication]
    private let region: ScreenRecordingRegion
    private let options: ScreenRecordingOptions
    private let sampleQueue = DispatchQueue(
        label: "com.native-translator.screen-recording.samples",
        qos: .userInitiated
    )
    private let microphoneSessionQueue = DispatchQueue(
        label: "com.native-translator.screen-recording.microphone",
        qos: .userInitiated
    )

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var microphoneSession: AVCaptureSession?
    private var gifEncoder: GIFRecordingEncoder?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var stateMachine = ScreenRecordingStateMachine()
    private var timeline = ScreenRecordingTimeline()
    private var sessionStarted = false
    private var didReportFailure = false
    private var didReportLimit = false

    init(
        outputURL: URL,
        display: SCDisplay,
        excludingApplications: [SCRunningApplication],
        region: ScreenRecordingRegion,
        options: ScreenRecordingOptions
    ) {
        self.outputURL = outputURL
        self.display = display
        self.excludingApplications = excludingApplications
        self.region = region
        self.options = options
        super.init()
    }

    func start() async throws {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try configureOutput()
            if options.capturesMicrophone {
                try configureMicrophoneCapture()
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludingApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region.sourceRect
            configuration.width = Int(region.outputSize.width)
            configuration.height = Int(region.outputSize.height)
            configuration.captureResolution = .best
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(options.frameRate)
            )
            configuration.queueDepth = 6
            configuration.showsCursor = options.showsCursor
            configuration.backgroundColor = .black
            configuration.capturesAudio = options.capturesSystemAudio
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            // Retain the stream before output registration so every throwing
            // setup step is handled by the same failed-start cleanup path.
            self.stream = stream
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if options.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }

            try sampleQueue.sync {
                try stateMachine.start()
                if options.format == .mp4 {
                    guard writer?.startWriting() == true else {
                        throw ScreenRecordingEngineError.writerStartFailed(
                            writer?.error?.localizedDescription ?? "未知错误"
                        )
                    }
                }
            }

            do {
                try await stream.startCapture()
            } catch {
                throw ScreenRecordingEngineError.captureStartFailed(error.localizedDescription)
            }
            startMicrophoneSessionIfNeeded()
        } catch {
            await cleanupAfterFailedStart()
            throw error
        }
    }

    func pause() throws {
        try sampleQueue.sync {
            try stateMachine.pause()
            timeline.beginPause(at: hostTime())
        }
    }

    func resume() throws {
        try sampleQueue.sync {
            try stateMachine.resume()
            timeline.endPause(at: hostTime())
        }
    }

    func stop() async throws -> URL {
        try sampleQueue.sync {
            if stateMachine.state == .paused {
                timeline.endPause(at: hostTime())
            }
            try stateMachine.stop()
        }

        var captureStopError: ScreenRecordingEngineError?
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                captureStopError = .captureStopFailed(error.localizedDescription)
            }
            self.stream = nil
        }
        stopMicrophoneSessionIfNeeded()
        if let captureStopError {
            sampleQueue.sync {
                writer?.cancelWriting()
                gifEncoder?.cancel()
            }
            try? FileManager.default.removeItem(at: outputURL)
            throw captureStopError
        }

        return try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [self] in
                guard sessionStarted else {
                    writer?.cancelWriting()
                    gifEncoder?.cancel()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: ScreenRecordingEngineError.noVideoFrames)
                    return
                }
                switch options.format {
                case .mp4:
                    guard let writer else {
                        continuation.resume(throwing: ScreenRecordingEngineError.writerUnavailable)
                        return
                    }
                    videoInput?.markAsFinished()
                    systemAudioInput?.markAsFinished()
                    microphoneInput?.markAsFinished()
                    writer.finishWriting { [self] in
                        sampleQueue.async { [self] in
                            if writer.status == .completed {
                                stateMachine.finish()
                                continuation.resume(returning: outputURL)
                            } else {
                                try? FileManager.default.removeItem(at: outputURL)
                                continuation.resume(throwing: ScreenRecordingEngineError.writerFinishFailed(
                                    writer.error?.localizedDescription ?? "未知错误"
                                ))
                            }
                        }
                    }
                case .gif:
                    do {
                        try gifEncoder?.finish()
                        stateMachine.finish()
                        continuation.resume(returning: outputURL)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func cancel() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        stopMicrophoneSessionIfNeeded()
        cancelPreparedArtifactsAndRemoveOutput()
    }

    private func cleanupAfterFailedStart() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        stopMicrophoneSessionIfNeeded()
        cancelPreparedArtifactsAndRemoveOutput()
    }

    private func cancelPreparedArtifactsAndRemoveOutput() {
        ScreenRecordingStartFailureCleanup.run(outputURL: outputURL) { [self] in
            sampleQueue.sync {
                writer?.cancelWriting()
                gifEncoder?.cancel()
                writer = nil
                videoInput = nil
                systemAudioInput = nil
                microphoneInput = nil
                microphoneSession = nil
                gifEncoder = nil
            }
        }
    }

    private func configureOutput() throws {
        switch options.format {
        case .mp4:
            try configureWriter()
        case .gif:
            guard let limits = options.gifLimits else {
                throw ScreenRecordingEngineError.gifConfigurationUnavailable
            }
            gifEncoder = try GIFRecordingEncoder(outputURL: outputURL, limits: limits)
        }
    }

    private func configureWriter() throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw ScreenRecordingEngineError.writerCreationFailed(error.localizedDescription)
        }

        let width = Int(region.outputSize.width)
        let height = Int(region.outputSize.height)
        let bitrate = options.videoBitrate(for: region.outputSize)
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoMaxKeyFrameIntervalKey: options.frameRate * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingEngineError.writerInputUnavailable("视频")
        }
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if options.capturesSystemAudio {
            let input = Self.makeAudioInput(channels: 2, bitrate: 192_000)
            guard writer.canAdd(input) else {
                throw ScreenRecordingEngineError.writerInputUnavailable("系统声音")
            }
            writer.add(input)
            systemAudioInput = input
        }

        var microphoneInput: AVAssetWriterInput?
        if options.capturesMicrophone {
            let input = Self.makeAudioInput(channels: 1, bitrate: 96_000)
            guard writer.canAdd(input) else {
                throw ScreenRecordingEngineError.writerInputUnavailable("麦克风")
            }
            writer.add(input)
            microphoneInput = input
        }

        self.writer = writer
        self.videoInput = videoInput
        self.systemAudioInput = systemAudioInput
        self.microphoneInput = microphoneInput
    }

    private static func makeAudioInput(channels: Int, bitrate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
        )
        input.expectsMediaDataInRealTime = true
        return input
    }

    private func configureMicrophoneCapture() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw ScreenRecordingEngineError.microphonePermissionRequired
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw ScreenRecordingEngineError.microphoneUnavailable
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(deviceInput) else {
                throw ScreenRecordingEngineError.microphoneUnavailable
            }
            session.addInput(deviceInput)
        } catch let error as ScreenRecordingEngineError {
            throw error
        } catch {
            throw ScreenRecordingEngineError.microphoneConfigurationFailed(error.localizedDescription)
        }
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw ScreenRecordingEngineError.microphoneUnavailable
        }
        session.addOutput(output)
        microphoneSession = session
    }

    private func startMicrophoneSessionIfNeeded() {
        guard let microphoneSession else {
            return
        }
        microphoneSessionQueue.async {
            microphoneSession.startRunning()
        }
    }

    private func stopMicrophoneSessionIfNeeded() {
        guard let microphoneSession else {
            return
        }
        microphoneSessionQueue.sync {
            if microphoneSession.isRunning {
                microphoneSession.stopRunning()
            }
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard stateMachine.state == .recording,
              let input,
              input.isReadyForMoreMediaData,
              writer?.status == .writing else {
            return
        }
        guard let adjustedBuffer = adjustedSampleBuffer(sampleBuffer) else {
            return
        }
        if !input.append(adjustedBuffer) {
            reportFailure(ScreenRecordingEngineError.appendFailed(
                writer?.error?.localizedDescription ?? "未知错误"
            ))
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard stateMachine.state == .recording,
              CMSampleBufferDataIsReady(sampleBuffer),
              isCompleteScreenFrame(sampleBuffer) else {
            return
        }
        if options.format == .gif {
            appendGIFFrame(sampleBuffer)
            return
        }
        if !sessionStarted {
            let firstTime = timeline.adjusted(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            writer?.startSession(atSourceTime: firstTime)
            sessionStarted = true
        }
        append(sampleBuffer, to: videoInput)
    }

    private func appendGIFFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let gifEncoder else {
            return
        }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
            reportFailure(ScreenRecordingEngineError.gifFrameConversionFailed)
            return
        }
        let presentationTime = timeline.adjusted(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
        do {
            if try gifEncoder.append(cgImage, at: presentationTime) {
                sessionStarted = true
            }
        } catch GIFRecordingError.durationLimitExceeded,
                GIFRecordingError.frameLimitExceeded {
            reportLimitReached()
        } catch {
            reportFailure(error)
        }
    }

    private func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusValue = attachments.first?[.status] as? NSNumber,
        let status = SCFrameStatus(rawValue: statusValue.intValue) else {
            return false
        }
        return status == .complete
    }

    private func adjustedSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var entryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else {
            return nil
        }
        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: entryCount
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: entryCount,
            arrayToFill: &timing,
            entriesNeededOut: &entryCount
        ) == noErr else {
            return nil
        }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = timeline.adjusted(
                    timing[index].presentationTimeStamp
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timeline.adjusted(
                    timing[index].decodeTimeStamp
                )
            }
        }
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timing.count,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        ) == noErr else {
            return nil
        }
        return output
    }

    private func reportFailure(_ error: Error) {
        guard !didReportFailure else {
            return
        }
        didReportFailure = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.screenRecordingEngine(self, didFail: error)
        }
    }

    private func reportLimitReached() {
        guard !didReportLimit else {
            return
        }
        didReportLimit = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.screenRecordingEngineDidReachLimit(self)
        }
    }

    private func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}

extension ScreenRecordingEngine: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        switch outputType {
        case .screen:
            appendVideo(sampleBuffer)
        case .audio:
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput)
        case .microphone:
            // macOS 14 uses AVCaptureSession for microphone input. The native
            // ScreenCaptureKit microphone output is available from macOS 15.
            break
        @unknown default:
            break
        }
    }
}

extension ScreenRecordingEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { [weak self] in
            self?.reportFailure(ScreenRecordingEngineError.captureStopped(error.localizedDescription))
        }
    }
}

extension ScreenRecordingEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sessionStarted else { return }
        append(sampleBuffer, to: microphoneInput)
    }
}

enum ScreenRecordingEngineError: LocalizedError {
    case writerCreationFailed(String)
    case writerStartFailed(String)
    case writerFinishFailed(String)
    case writerInputUnavailable(String)
    case writerUnavailable
    case noVideoFrames
    case captureStartFailed(String)
    case captureStopFailed(String)
    case captureStopped(String)
    case appendFailed(String)
    case microphonePermissionRequired
    case microphoneUnavailable
    case microphoneConfigurationFailed(String)
    case gifConfigurationUnavailable
    case gifFrameConversionFailed

    var errorDescription: String? {
        switch self {
        case let .writerCreationFailed(message):
            return "无法创建录屏文件：\(message)"
        case let .writerStartFailed(message):
            return "无法开始写入录屏：\(message)"
        case let .writerFinishFailed(message):
            return "无法完成录屏文件：\(message)"
        case let .writerInputUnavailable(kind):
            return "当前系统不支持写入\(kind)轨道"
        case .writerUnavailable:
            return "录屏写入器不可用"
        case .noVideoFrames:
            return "没有捕获到可用的视频画面"
        case let .captureStartFailed(message):
            return "无法开始屏幕捕获：\(message)"
        case let .captureStopFailed(message):
            return "停止屏幕捕获时出错：\(message)"
        case let .captureStopped(message):
            return "屏幕捕获意外停止：\(message)"
        case let .appendFailed(message):
            return "写入录屏数据失败：\(message)"
        case .microphonePermissionRequired:
            return "录制麦克风需要在系统设置中授权麦克风权限"
        case .microphoneUnavailable:
            return "没有可用的麦克风"
        case let .microphoneConfigurationFailed(message):
            return "无法配置麦克风：\(message)"
        case .gifConfigurationUnavailable:
            return "无法读取 GIF 录制限制"
        case .gifFrameConversionFailed:
            return "无法将屏幕画面转换为 GIF 帧"
        }
    }
}
