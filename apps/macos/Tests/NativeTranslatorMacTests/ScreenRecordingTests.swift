import CoreMedia
import XCTest
@testable import NativeTranslatorMac

final class ScreenRecordingTests: XCTestCase {
    func testSessionStateMachineRunsPixPinStyleReadyCountdownRecordingAndReviewFlow() throws {
        var machine = ScreenRecordingSessionStateMachine()

        XCTAssertTrue(machine.presentReady())
        XCTAssertEqual(machine.state, .ready)
        try machine.beginRecording(after: .threeSeconds)
        XCTAssertEqual(machine.state, .countingDown(remaining: 3))
        XCTAssertFalse(try machine.advanceCountdown())
        XCTAssertEqual(machine.state, .countingDown(remaining: 2))
        XCTAssertFalse(try machine.advanceCountdown())
        XCTAssertTrue(try machine.advanceCountdown())
        XCTAssertEqual(machine.state, .starting)

        try machine.recordingDidStart()
        XCTAssertEqual(machine.state, .recording)
        try machine.pause()
        XCTAssertEqual(machine.state, .paused)
        try machine.resume()
        XCTAssertEqual(machine.state, .recording)
        try machine.beginFinalizing()
        XCTAssertEqual(machine.state, .finalizing)
        try machine.recordingDidFinish()
        XCTAssertEqual(machine.state, .reviewing)

        try machine.restart()
        XCTAssertEqual(machine.state, .ready)
        machine.close()
        XCTAssertEqual(machine.state, .idle)
    }

    func testSessionStateMachineSupportsImmediateStartAndRecoverableFailures() throws {
        var machine = ScreenRecordingSessionStateMachine()
        XCTAssertTrue(machine.presentReady())

        try machine.beginRecording(after: .immediate)
        XCTAssertEqual(machine.state, .starting)
        try machine.recordingDidFail()
        XCTAssertEqual(machine.state, .ready)

        try machine.beginRecording(after: .immediate)
        try machine.recordingDidStart()
        try machine.beginFinalizing()
        try machine.recordingDidFail()
        XCTAssertEqual(machine.state, .ready)
    }

    func testSessionStateMachineCancelsCountdownWithoutClosingSession() throws {
        var machine = ScreenRecordingSessionStateMachine()
        XCTAssertTrue(machine.presentReady())
        try machine.beginRecording(after: .fiveSeconds)

        try machine.cancelCountdown()

        XCTAssertEqual(machine.state, .ready)
    }

    func testSessionStateMachineRejectsInvalidUserTransitions() throws {
        var machine = ScreenRecordingSessionStateMachine()
        XCTAssertThrowsError(try machine.pause())
        XCTAssertTrue(machine.presentReady())
        XCTAssertThrowsError(try machine.resume())
        XCTAssertThrowsError(try machine.recordingDidFinish())
        try machine.beginRecording(after: .threeSeconds)
        XCTAssertThrowsError(try machine.beginFinalizing())
    }

    func testRecordingShortcutMappingConsumesEveryActiveSessionState() {
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .idle), .notHandled)
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .ready), .beginRecording)
        XCTAssertEqual(
            ScreenRecordingShortcutAction.resolve(for: .countingDown(remaining: 2)),
            .cancelCountdown
        )
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .starting), .consume)
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .recording), .stopRecording)
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .paused), .stopRecording)
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .finalizing), .consume)
        XCTAssertEqual(ScreenRecordingShortcutAction.resolve(for: .reviewing), .consume)
    }

    func testReadyRegionGeometryMovesAndResizesWithinScreenBounds() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let original = CGRect(x: 100, y: 100, width: 300, height: 200)

        XCTAssertEqual(
            ScreenRecordingRegionGeometry.edited(
                original,
                target: .move,
                dragStart: CGPoint(x: 200, y: 200),
                current: CGPoint(x: 900, y: 700),
                screenBounds: screen
            ),
            CGRect(x: 500, y: 400, width: 300, height: 200)
        )
        XCTAssertEqual(
            ScreenRecordingRegionGeometry.edited(
                original,
                target: .bottomLeft,
                dragStart: CGPoint(x: 100, y: 100),
                current: CGPoint(x: 250, y: 180),
                screenBounds: screen
            ),
            CGRect(x: 250, y: 180, width: 150, height: 120)
        )
        XCTAssertEqual(
            ScreenRecordingRegionGeometry.edited(
                original,
                target: .topRight,
                dragStart: CGPoint(x: 400, y: 300),
                current: CGPoint(x: 650, y: 500),
                screenBounds: screen
            ),
            CGRect(x: 100, y: 100, width: 550, height: 400)
        )
    }

    func testReadyRegionGeometryHitTestsEightHandlesAndInteriorMove() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

        XCTAssertEqual(ScreenRecordingRegionGeometry.editTarget(at: .zero, in: bounds), .bottomLeft)
        XCTAssertEqual(
            ScreenRecordingRegionGeometry.editTarget(at: CGPoint(x: 150, y: 0), in: bounds),
            .bottom
        )
        XCTAssertEqual(
            ScreenRecordingRegionGeometry.editTarget(at: CGPoint(x: 300, y: 200), in: bounds),
            .topRight
        )
        XCTAssertEqual(
            ScreenRecordingRegionGeometry.editTarget(at: CGPoint(x: 150, y: 100), in: bounds),
            .move
        )
    }

    func testLifecycleGateRejectsDuplicateStartUntilAttemptFinishes() {
        var lifecycle = ScreenRecordingLifecycleGate()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertEqual(lifecycle.state, .starting)
        XCTAssertFalse(lifecycle.beginStart())

        lifecycle.startFailed()
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(lifecycle.beginStart())
    }

    func testLifecycleGateMakesTerminationDuringStartWaitForStartOwner() {
        var lifecycle = ScreenRecordingLifecycleGate()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertEqual(lifecycle.beginTeardown(), .waitForStart)
        XCTAssertEqual(lifecycle.state, .tearingDown)
        XCTAssertFalse(lifecycle.startSucceeded())
        XCTAssertFalse(lifecycle.beginStart())

        lifecycle.teardownFinished()
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testLifecycleGateSeparatesRecordingTeardownFromStartingTeardown() {
        var lifecycle = ScreenRecordingLifecycleGate()

        XCTAssertTrue(lifecycle.beginStart())
        XCTAssertTrue(lifecycle.startSucceeded())
        XCTAssertEqual(lifecycle.state, .recording)
        XCTAssertEqual(lifecycle.beginTeardown(), .stopRecording)
        XCTAssertEqual(lifecycle.state, .tearingDown)
        XCTAssertEqual(lifecycle.beginTeardown(), .none)
    }

    func testTerminationIntentSuppressesReviewAndReadyRecoveryAfterStopCompletes() {
        var intent = ScreenRecordingTerminationIntent()

        XCTAssertEqual(intent.completionAction(didStopSuccessfully: true), .presentReview)
        XCTAssertEqual(intent.completionAction(didStopSuccessfully: false), .restoreReady)

        intent.beginTermination()

        XCTAssertTrue(intent.isTerminating)
        XCTAssertEqual(intent.completionAction(didStopSuccessfully: true), .finishTermination)
        XCTAssertEqual(intent.completionAction(didStopSuccessfully: false), .finishTermination)
    }

    func testUnsavedReviewRequiresExplicitSaveDiscardOrCancelDecision() {
        var artifact = ScreenRecordingReviewArtifactState()
        artifact.beginReview()

        XCTAssertFalse(artifact.isPersisted)
        XCTAssertEqual(artifact.exitAction(), .requestConfirmation)
        XCTAssertEqual(artifact.exitAction(after: .save), .saveThenProceed)
        XCTAssertEqual(artifact.exitAction(after: .discard), .proceed)
        XCTAssertEqual(artifact.exitAction(after: .cancel), .stay)
    }

    func testPersistedReviewCanCloseOrRestartWithoutDiscardConfirmation() {
        var artifact = ScreenRecordingReviewArtifactState()
        artifact.beginReview()
        artifact.markPersisted()

        XCTAssertTrue(artifact.isPersisted)
        XCTAssertEqual(artifact.exitAction(), .proceed)

        artifact.beginReview()
        XCTAssertFalse(artifact.isPersisted)
        XCTAssertEqual(artifact.exitAction(), .requestConfirmation)
    }

    func testActiveRecordingExitDecisionCanSaveDiscardOrStayRecording() {
        XCTAssertEqual(
            ScreenRecordingActiveExitPolicy.action(after: .save),
            .stopSaveAndProceed
        )
        XCTAssertEqual(
            ScreenRecordingActiveExitPolicy.action(after: .discard),
            .discardAndProceed
        )
        XCTAssertEqual(
            ScreenRecordingActiveExitPolicy.action(after: .cancel),
            .stay
        )
    }

    func testStartFailureCleanupCancelsPreparedArtifactsAndRemovesOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ScreenRecordingStartFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("partial.mp4")
        try Data("partial".utf8).write(to: output)
        var didCancelPreparedArtifacts = false

        ScreenRecordingStartFailureCleanup.run(outputURL: output) {
            didCancelPreparedArtifacts = true
        }

        XCTAssertTrue(didCancelPreparedArtifacts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTeardownGateAdmitsOnlyOneEndingPathUntilReset() {
        var gate = ScreenRecordingTeardownGate()

        XCTAssertFalse(gate.isTearingDown)
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isTearingDown)
        XCTAssertFalse(gate.begin())

        gate.reset()
        XCTAssertFalse(gate.isTearingDown)
        XCTAssertTrue(gate.begin())
    }

    func testCaptureRegionConvertsGlobalBottomLeftToDisplayLocalTopLeft() throws {
        let region = try ScreenRecordingGeometry.captureRegion(
            globalRegion: CGRect(x: 120, y: 250, width: 400, height: 200),
            displayFrame: CGRect(x: 100, y: 100, width: 1_000, height: 800),
            scale: 2
        )

        XCTAssertEqual(region.sourceRect, CGRect(x: 20, y: 450, width: 400, height: 200))
        XCTAssertEqual(region.outputSize, CGSize(width: 800, height: 400))
    }

    func testCaptureRegionClipsToDisplayAndProducesEvenPixelDimensions() throws {
        let region = try ScreenRecordingGeometry.captureRegion(
            globalRegion: CGRect(x: -10, y: 10, width: 112.4, height: 57.4),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 1.5
        )

        XCTAssertEqual(region.sourceRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(region.sourceRect.minY, 32.6, accuracy: 0.001)
        XCTAssertEqual(region.sourceRect.width, 100, accuracy: 0.001)
        XCTAssertEqual(region.sourceRect.height, 57.4, accuracy: 0.001)
        XCTAssertEqual(region.outputSize, CGSize(width: 150, height: 86))
    }

    func testCaptureRegionRejectsAnEmptyOrOutsideSelection() {
        XCTAssertThrowsError(try ScreenRecordingGeometry.captureRegion(
            globalRegion: .zero,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2
        ))
        XCTAssertThrowsError(try ScreenRecordingGeometry.captureRegion(
            globalRegion: CGRect(x: 0, y: 0, width: 20, height: 20),
            displayFrame: .zero,
            scale: 2
        )) { error in
            XCTAssertEqual(error as? ScreenRecordingGeometry.Error, .invalidDisplay)
        }
        XCTAssertThrowsError(try ScreenRecordingGeometry.captureRegion(
            globalRegion: CGRect(x: 0, y: 0, width: 20, height: 20),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 0
        )) { error in
            XCTAssertEqual(error as? ScreenRecordingGeometry.Error, .invalidScale)
        }
        XCTAssertThrowsError(try ScreenRecordingGeometry.captureRegion(
            globalRegion: CGRect(x: 200, y: 200, width: 20, height: 20),
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            scale: 2
        ))
    }

    func testTimelineSubtractsAccumulatedPauseDuration() {
        var timeline = ScreenRecordingTimeline()
        timeline.beginPause(at: CMTime(seconds: 5, preferredTimescale: 600))
        timeline.endPause(at: CMTime(seconds: 8, preferredTimescale: 600))
        timeline.beginPause(at: CMTime(seconds: 12, preferredTimescale: 600))
        timeline.endPause(at: CMTime(seconds: 14, preferredTimescale: 600))

        XCTAssertEqual(
            timeline.adjusted(CMTime(seconds: 16, preferredTimescale: 600)).seconds,
            11,
            accuracy: 0.001
        )
    }

    func testTimelineIgnoresDuplicatePauseTransitions() {
        var timeline = ScreenRecordingTimeline()
        timeline.beginPause(at: CMTime(seconds: 3, preferredTimescale: 600))
        timeline.beginPause(at: CMTime(seconds: 4, preferredTimescale: 600))
        timeline.endPause(at: CMTime(seconds: 7, preferredTimescale: 600))
        timeline.endPause(at: CMTime(seconds: 9, preferredTimescale: 600))

        XCTAssertEqual(
            timeline.adjusted(CMTime(seconds: 10, preferredTimescale: 600)).seconds,
            6,
            accuracy: 0.001
        )
    }

    func testRecordingStateMachineAllowsOnlyValidTransitions() throws {
        var machine = ScreenRecordingStateMachine()

        try machine.start()
        XCTAssertEqual(machine.state, .recording)
        try machine.pause()
        XCTAssertEqual(machine.state, .paused)
        try machine.resume()
        XCTAssertEqual(machine.state, .recording)
        try machine.stop()
        XCTAssertEqual(machine.state, .stopping)
        machine.finish()
        XCTAssertEqual(machine.state, .finished)
        XCTAssertThrowsError(try machine.pause())
    }

    func testRecordingStateMachineRejectsInvalidStartResumeAndStopTransitions() throws {
        var machine = ScreenRecordingStateMachine()
        XCTAssertThrowsError(try machine.resume())
        XCTAssertThrowsError(try machine.stop())
        machine.finish()
        XCTAssertEqual(machine.state, .idle)
        try machine.start()
        XCTAssertThrowsError(try machine.start())
        try machine.pause()
        try machine.stop()
        machine.finish()
        XCTAssertEqual(machine.state, .finished)
    }

    func testRecordingOptionsClampFrameRateAndAudioChoice() {
        XCTAssertEqual(ScreenRecordingOptions(frameRate: 120).frameRate, 60)
        XCTAssertEqual(ScreenRecordingOptions(frameRate: 1).frameRate, 5)
        XCTAssertEqual(ScreenRecordingOptions().frameRate, 30)
    }
}
