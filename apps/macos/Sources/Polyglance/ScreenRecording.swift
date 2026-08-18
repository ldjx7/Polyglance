import CoreGraphics
import CoreMedia
import Foundation

enum ScreenRecordingSessionState: Equatable {
    case idle
    case ready
    case countingDown(remaining: Int)
    case starting
    case recording
    case paused
    case finalizing
    case reviewing
}

struct ScreenRecordingSessionStateMachine {
    enum Error: Swift.Error, Equatable {
        case invalidTransition(from: ScreenRecordingSessionState, operation: String)
    }

    private(set) var state: ScreenRecordingSessionState = .idle

    @discardableResult
    mutating func presentReady() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .ready
        return true
    }

    mutating func beginRecording(after delay: ScreenRecordingDelay) throws {
        try require(.ready, operation: "beginRecording")
        state = delay == .immediate
            ? .starting
            : .countingDown(remaining: delay.rawValue)
    }

    @discardableResult
    mutating func advanceCountdown() throws -> Bool {
        guard case let .countingDown(remaining) = state else {
            throw Error.invalidTransition(from: state, operation: "advanceCountdown")
        }
        if remaining <= 1 {
            state = .starting
            return true
        }
        state = .countingDown(remaining: remaining - 1)
        return false
    }

    mutating func cancelCountdown() throws {
        guard case .countingDown = state else {
            throw Error.invalidTransition(from: state, operation: "cancelCountdown")
        }
        state = .ready
    }

    mutating func recordingDidStart() throws {
        try require(.starting, operation: "recordingDidStart")
        state = .recording
    }

    mutating func pause() throws {
        try require(.recording, operation: "pause")
        state = .paused
    }

    mutating func resume() throws {
        try require(.paused, operation: "resume")
        state = .recording
    }

    mutating func beginFinalizing() throws {
        guard state == .recording || state == .paused else {
            throw Error.invalidTransition(from: state, operation: "beginFinalizing")
        }
        state = .finalizing
    }

    mutating func recordingDidFinish() throws {
        try require(.finalizing, operation: "recordingDidFinish")
        state = .reviewing
    }

    mutating func recordingDidFail() throws {
        guard state == .starting
                || state == .recording
                || state == .paused
                || state == .finalizing else {
            throw Error.invalidTransition(from: state, operation: "recordingDidFail")
        }
        state = .ready
    }

    mutating func restart() throws {
        try require(.reviewing, operation: "restart")
        state = .ready
    }

    mutating func close() {
        state = .idle
    }

    private func require(_ expected: ScreenRecordingSessionState, operation: String) throws {
        guard state == expected else {
            throw Error.invalidTransition(from: state, operation: operation)
        }
    }
}

enum ScreenRecordingShortcutAction: Equatable {
    case notHandled
    case beginRecording
    case cancelCountdown
    case stopRecording
    case consume

    static func resolve(for state: ScreenRecordingSessionState) -> Self {
        switch state {
        case .idle:
            return .notHandled
        case .ready:
            return .beginRecording
        case .countingDown:
            return .cancelCountdown
        case .recording, .paused:
            return .stopRecording
        case .starting, .finalizing, .reviewing:
            return .consume
        }
    }
}

enum ScreenRecordingRegionEditTarget: Equatable {
    case move
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

enum ScreenRecordingRegionGeometry {
    static func editTarget(
        at point: CGPoint,
        in bounds: CGRect,
        handleThickness: CGFloat = 8
    ) -> ScreenRecordingRegionEditTarget {
        let nearLeft = point.x <= bounds.minX + handleThickness
        let nearRight = point.x >= bounds.maxX - handleThickness
        let nearBottom = point.y <= bounds.minY + handleThickness
        let nearTop = point.y >= bounds.maxY - handleThickness
        switch (nearLeft, nearRight, nearBottom, nearTop) {
        case (true, _, true, _): return .bottomLeft
        case (true, _, _, true): return .topLeft
        case (_, true, true, _): return .bottomRight
        case (_, true, _, true): return .topRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .bottom
        case (_, _, _, true): return .top
        default: return .move
        }
    }

    static func edited(
        _ original: CGRect,
        target: ScreenRecordingRegionEditTarget,
        dragStart: CGPoint,
        current: CGPoint,
        screenBounds: CGRect,
        minimumSide: CGFloat = 24
    ) -> CGRect {
        let original = original.standardized
        let screen = screenBounds.standardized
        let delta = CGPoint(x: current.x - dragStart.x, y: current.y - dragStart.y)
        if target == .move {
            let x = min(max(original.minX + delta.x, screen.minX), screen.maxX - original.width)
            let y = min(max(original.minY + delta.y, screen.minY), screen.maxY - original.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: original.size)
        }

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch target {
        case .left, .topLeft, .bottomLeft:
            minX = min(max(original.minX + delta.x, screen.minX), maxX - minimumSide)
        default:
            break
        }
        switch target {
        case .right, .topRight, .bottomRight:
            maxX = max(min(original.maxX + delta.x, screen.maxX), minX + minimumSide)
        default:
            break
        }
        switch target {
        case .bottom, .bottomLeft, .bottomRight:
            minY = min(max(original.minY + delta.y, screen.minY), maxY - minimumSide)
        default:
            break
        }
        switch target {
        case .top, .topLeft, .topRight:
            maxY = max(min(original.maxY + delta.y, screen.maxY), minY + minimumSide)
        default:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum ScreenRecordingCoordinatorLifecycle: Equatable {
    case idle
    case starting
    case recording
    case tearingDown
}

struct ScreenRecordingLifecycleGate: Equatable {
    enum TeardownAction: Equatable {
        case none
        case waitForStart
        case stopRecording
    }

    private(set) var state: ScreenRecordingCoordinatorLifecycle = .idle

    mutating func beginStart() -> Bool {
        guard state == .idle else {
            return false
        }
        state = .starting
        return true
    }

    /// Returns `false` when teardown was requested while the engine was starting.
    @discardableResult
    mutating func startSucceeded() -> Bool {
        guard state == .starting else {
            return false
        }
        state = .recording
        return true
    }

    mutating func startFailed() {
        guard state == .starting else {
            return
        }
        state = .idle
    }

    mutating func beginTeardown() -> TeardownAction {
        switch state {
        case .idle, .tearingDown:
            return .none
        case .starting:
            state = .tearingDown
            return .waitForStart
        case .recording:
            state = .tearingDown
            return .stopRecording
        }
    }

    mutating func teardownFinished() {
        guard state == .tearingDown else {
            return
        }
        state = .idle
    }
}

enum ScreenRecordingAsyncCompletionAction: Equatable {
    case presentReview
    case restoreReady
    case finishTermination
}

/// Records application-termination intent independently from the engine
/// lifecycle. An async stop owner may finish after termination has started; in
/// that case it must only release the lifecycle waiter and leave final cleanup
/// to the termination path.
struct ScreenRecordingTerminationIntent: Equatable {
    private(set) var isTerminating = false

    mutating func beginTermination() {
        isTerminating = true
    }

    func completionAction(didStopSuccessfully: Bool) -> ScreenRecordingAsyncCompletionAction {
        guard !isTerminating else { return .finishTermination }
        return didStopSuccessfully ? .presentReview : .restoreReady
    }
}

enum ScreenRecordingReviewDiscardDecision: Equatable {
    case save
    case discard
    case cancel
}

enum ScreenRecordingActiveExitAction: Equatable {
    case stopSaveAndProceed
    case discardAndProceed
    case stay
}

enum ScreenRecordingActiveExitPolicy {
    static func action(
        after decision: ScreenRecordingReviewDiscardDecision
    ) -> ScreenRecordingActiveExitAction {
        switch decision {
        case .save:
            return .stopSaveAndProceed
        case .discard:
            return .discardAndProceed
        case .cancel:
            return .stay
        }
    }
}

enum ScreenRecordingReviewExitAction: Equatable {
    case requestConfirmation
    case saveThenProceed
    case proceed
    case stay
}

/// Tracks whether the current review artifact has a durable copy outside the
/// temporary recording directory. Every newly generated review starts unsafe;
/// Save, Quick Save, or a successful clipboard copy marks it persisted.
struct ScreenRecordingReviewArtifactState: Equatable {
    private(set) var isPersisted = false

    mutating func beginReview() {
        isPersisted = false
    }

    mutating func markPersisted() {
        isPersisted = true
    }

    func exitAction(
        after decision: ScreenRecordingReviewDiscardDecision? = nil
    ) -> ScreenRecordingReviewExitAction {
        guard !isPersisted else { return .proceed }
        switch decision {
        case nil:
            return .requestConfirmation
        case .save:
            return .saveThenProceed
        case .discard:
            return .proceed
        case .cancel:
            return .stay
        }
    }
}

enum ScreenRecordingStartFailureCleanup {
    static func run(
        outputURL: URL,
        fileManager: FileManager = .default,
        cancelPreparedArtifacts: () -> Void
    ) {
        cancelPreparedArtifacts()
        try? fileManager.removeItem(at: outputURL)
    }
}

struct ScreenRecordingTeardownGate: Equatable {
    private(set) var isTearingDown = false

    mutating func begin() -> Bool {
        guard !isTearingDown else {
            return false
        }
        isTearingDown = true
        return true
    }

    mutating func reset() {
        isTearingDown = false
    }
}

struct ScreenRecordingRegion: Equatable {
    let sourceRect: CGRect
    let outputSize: CGSize
}

enum ScreenRecordingGeometry {
    enum Error: Swift.Error, Equatable {
        case invalidDisplay
        case invalidScale
        case emptySelection
    }

    static func captureRegion(
        globalRegion: CGRect,
        displayFrame: CGRect,
        scale: CGFloat
    ) throws -> ScreenRecordingRegion {
        let display = displayFrame.standardized
        let selection = globalRegion.standardized
        guard !display.isNull, !display.isEmpty else {
            throw Error.invalidDisplay
        }
        guard scale.isFinite, scale > 0 else {
            throw Error.invalidScale
        }

        let clipped = selection.intersection(display)
        guard !clipped.isNull, !clipped.isEmpty,
              clipped.width.isFinite, clipped.height.isFinite else {
            throw Error.emptySelection
        }

        // ScreenCaptureKit sourceRect uses display-local coordinates whose origin
        // is at the top-left, while AppKit screen coordinates start at bottom-left.
        let sourceRect = CGRect(
            x: clipped.minX - display.minX,
            y: display.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
        let pixelWidth = evenPixelDimension(clipped.width * scale)
        let pixelHeight = evenPixelDimension(clipped.height * scale)
        guard pixelWidth >= 2, pixelHeight >= 2 else {
            throw Error.emptySelection
        }
        return ScreenRecordingRegion(
            sourceRect: sourceRect,
            outputSize: CGSize(width: pixelWidth, height: pixelHeight)
        )
    }

    private static func evenPixelDimension(_ value: CGFloat) -> CGFloat {
        let rounded = max(0, Int(value.rounded()))
        return CGFloat(rounded - rounded % 2)
    }
}

struct ScreenRecordingTimeline {
    private var pauseStartedAt: CMTime?
    private var accumulatedPauseDuration = CMTime.zero

    mutating func beginPause(at time: CMTime) {
        guard pauseStartedAt == nil, time.isValid, time.isNumeric else {
            return
        }
        pauseStartedAt = time
    }

    mutating func endPause(at time: CMTime) {
        guard let pauseStartedAt, time.isValid, time.isNumeric else {
            return
        }
        let duration = CMTimeSubtract(time, pauseStartedAt)
        if duration > .zero {
            accumulatedPauseDuration = CMTimeAdd(accumulatedPauseDuration, duration)
        }
        self.pauseStartedAt = nil
    }

    func adjusted(_ time: CMTime) -> CMTime {
        CMTimeSubtract(time, accumulatedPauseDuration)
    }
}

enum ScreenRecordingState: Equatable {
    case idle
    case recording
    case paused
    case stopping
    case finished
}

struct ScreenRecordingStateMachine {
    enum Error: Swift.Error, Equatable {
        case invalidTransition(from: ScreenRecordingState, to: ScreenRecordingState)
    }

    private(set) var state: ScreenRecordingState = .idle

    mutating func start() throws {
        try transition(from: .idle, to: .recording)
    }

    mutating func pause() throws {
        try transition(from: .recording, to: .paused)
    }

    mutating func resume() throws {
        try transition(from: .paused, to: .recording)
    }

    mutating func stop() throws {
        guard state == .recording || state == .paused else {
            throw Error.invalidTransition(from: state, to: .stopping)
        }
        state = .stopping
    }

    mutating func finish() {
        guard state == .stopping else {
            return
        }
        state = .finished
    }

    private mutating func transition(
        from expectedState: ScreenRecordingState,
        to newState: ScreenRecordingState
    ) throws {
        guard state == expectedState else {
            throw Error.invalidTransition(from: state, to: newState)
        }
        state = newState
    }
}

struct ScreenRecordingOptions: Equatable {
    let format: ScreenRecordingFormat
    let quality: ScreenRecordingQuality
    let frameRate: Int
    let capturesSystemAudio: Bool
    let capturesMicrophone: Bool
    let showsCursor: Bool

    init(
        format: ScreenRecordingFormat = .mp4,
        quality: ScreenRecordingQuality = .standard,
        frameRate: Int? = nil,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = true
    ) {
        self.format = format
        self.quality = quality
        let preferredFrameRate = frameRate ?? quality.profile(for: format).frameRate
        let maximumFrameRate = format == .gif ? 20 : 60
        self.frameRate = min(maximumFrameRate, max(5, preferredFrameRate))
        self.capturesSystemAudio = format.supportsAudio && capturesSystemAudio
        self.capturesMicrophone = format.supportsAudio && capturesMicrophone
        self.showsCursor = showsCursor
    }

    init(settings: RecordingSettings) {
        self.init(
            format: settings.format,
            quality: settings.quality,
            frameRate: settings.frameRate,
            capturesSystemAudio: settings.capturesSystemAudio,
            capturesMicrophone: settings.capturesMicrophone,
            showsCursor: settings.showsCursor
        )
    }

    var maximumDuration: TimeInterval? {
        quality.profile(for: format).maximumDuration
    }

    func encodingSize(for sourceSize: CGSize) -> CGSize {
        quality.profile(for: format).outputSize(for: sourceSize)
    }

    func videoBitrate(for outputSize: CGSize) -> Int {
        quality.profile(for: format).videoBitrate(
            for: outputSize,
            frameRate: frameRate
        )
    }

    var gifLimits: GIFRecordingLimits? {
        guard format == .gif else {
            return nil
        }
        let profile = quality.profile(for: format)
        return GIFRecordingLimits(
            frameRate: frameRate,
            maxDimension: profile.maxDimension,
            maxDuration: profile.maximumDuration ?? 60,
            maxFrames: profile.maximumFrameCount ?? frameRate * 60,
            maxDecodedFrameBytes: 32 * 1_024 * 1_024,
            maxTemporaryBytes: 1_024 * 1_024 * 1_024
        )
    }
}
