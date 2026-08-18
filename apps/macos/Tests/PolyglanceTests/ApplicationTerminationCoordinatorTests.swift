import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testTerminationCanProceedImmediatelyWhenThereIsNoActiveRecording() {
        var didPrepare = false
        var didReply = false
        let coordinator = ApplicationTerminationCoordinator(
            hasPendingWork: { false },
            prepare: {
                didPrepare = true
                return true
            }
        )

        let result = coordinator.requestTermination { _ in didReply = true }

        XCTAssertEqual(result, .terminateNow)
        XCTAssertFalse(didPrepare)
        XCTAssertFalse(didReply)
    }

    func testTerminationWaitsForActiveRecordingPreparationBeforeReplying() async {
        var hasPendingWork = true
        var didPrepare = false
        let replied = expectation(description: "termination reply")
        let coordinator = ApplicationTerminationCoordinator(
            hasPendingWork: { hasPendingWork },
            prepare: {
                await Task.yield()
                didPrepare = true
                hasPendingWork = false
                return true
            }
        )

        let result = coordinator.requestTermination { shouldTerminate in
            XCTAssertTrue(shouldTerminate)
            replied.fulfill()
        }

        XCTAssertEqual(result, .terminateLater)
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertTrue(didPrepare)
        XCTAssertFalse(hasPendingWork)
    }

    func testCancelledPreparationRepliesFalseAndAllowsTerminationRetry() async {
        var shouldProceed = false
        var preparationCount = 0
        let cancelled = expectation(description: "termination cancelled")
        let accepted = expectation(description: "termination accepted")
        let coordinator = ApplicationTerminationCoordinator(
            hasPendingWork: { true },
            prepare: {
                preparationCount += 1
                return shouldProceed
            }
        )

        XCTAssertEqual(coordinator.requestTermination { result in
            XCTAssertFalse(result)
            cancelled.fulfill()
        }, .terminateLater)
        await fulfillment(of: [cancelled], timeout: 1)

        shouldProceed = true
        XCTAssertEqual(coordinator.requestTermination { result in
            XCTAssertTrue(result)
            accepted.fulfill()
        }, .terminateLater)
        await fulfillment(of: [accepted], timeout: 1)

        XCTAssertEqual(preparationCount, 2)
    }
}
