import XCTest
@testable import PolyglanceKit

@MainActor
final class AuxiliaryWindowCoordinatorTests: XCTestCase {
    func testShowCreatesOneWindowAndReusesIt() {
        var creationCount = 0
        let coordinator = AuxiliaryWindowCoordinator<WindowSpy>(
            makeWindow: {
                creationCount += 1
                return WindowSpy()
            },
            present: { $0.presentCount += 1 },
            close: { $0.closeCount += 1 }
        )

        coordinator.show()
        coordinator.show()

        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(coordinator.window?.presentCount, 2)
    }

    func testCloseClosesExistingWindowWithoutCreatingOne() {
        var creationCount = 0
        let coordinator = AuxiliaryWindowCoordinator<WindowSpy>(
            makeWindow: {
                creationCount += 1
                return WindowSpy()
            },
            present: { $0.presentCount += 1 },
            close: { $0.closeCount += 1 }
        )

        coordinator.close()
        XCTAssertEqual(creationCount, 0)

        coordinator.show()
        coordinator.close()

        XCTAssertEqual(coordinator.window?.closeCount, 1)
    }

    func testDiscardMakesTheNextShowCreateAFreshWindow() {
        var creationCount = 0
        let coordinator = AuxiliaryWindowCoordinator<WindowSpy>(
            makeWindow: {
                creationCount += 1
                return WindowSpy()
            },
            present: { $0.presentCount += 1 },
            close: { $0.closeCount += 1 }
        )

        coordinator.show()
        let firstWindow = coordinator.window
        coordinator.discard()
        coordinator.show()

        XCTAssertEqual(creationCount, 2)
        XCTAssertFalse(firstWindow === coordinator.window)
    }
}

private final class WindowSpy {
    var presentCount = 0
    var closeCount = 0
}
