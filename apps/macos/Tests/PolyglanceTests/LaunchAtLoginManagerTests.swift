import XCTest
@testable import Polyglance

@MainActor
final class LaunchAtLoginManagerTests: XCTestCase {
    func testEnabledReflectsEffectiveSystemStatus() {
        let enabledService = StubLaunchAtLoginService(status: .enabled)
        let approvalService = StubLaunchAtLoginService(status: .requiresApproval)

        XCTAssertTrue(LaunchAtLoginManager(service: enabledService).isEnabled)
        XCTAssertFalse(LaunchAtLoginManager(service: approvalService).isEnabled)
    }

    func testEnablingRegistersDisabledService() throws {
        let service = StubLaunchAtLoginService(status: .notRegistered)
        let manager = LaunchAtLoginManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertTrue(manager.isEnabled)
    }

    func testDisablingUnregistersEnabledService() throws {
        let service = StubLaunchAtLoginService(status: .enabled)
        let manager = LaunchAtLoginManager(service: service)

        try manager.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(manager.isEnabled)
    }

    func testApplyingCurrentStateIsIdempotent() throws {
        let enabledService = StubLaunchAtLoginService(status: .enabled)
        let disabledService = StubLaunchAtLoginService(status: .notRegistered)

        try LaunchAtLoginManager(service: enabledService).setEnabled(true)
        try LaunchAtLoginManager(service: disabledService).setEnabled(false)

        XCTAssertEqual(enabledService.registerCallCount, 0)
        XCTAssertEqual(enabledService.unregisterCallCount, 0)
        XCTAssertEqual(disabledService.registerCallCount, 0)
        XCTAssertEqual(disabledService.unregisterCallCount, 0)
    }

    func testEnablingApprovalRequiredServiceOpensSystemSettingsAndThrows() {
        let service = StubLaunchAtLoginService(status: .requiresApproval)
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .requiresApproval)
        }
        XCTAssertEqual(service.openSettingsCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testRegistrationThatStillRequiresApprovalOpensSystemSettingsAndThrows() {
        let service = StubLaunchAtLoginService(
            status: .notRegistered,
            statusAfterRegister: .requiresApproval
        )
        let manager = LaunchAtLoginManager(service: service)

        XCTAssertThrowsError(try manager.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .requiresApproval)
        }
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.openSettingsCallCount, 1)
    }
}

@MainActor
private final class StubLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    let statusAfterRegister: LaunchAtLoginServiceStatus
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(
        status: LaunchAtLoginServiceStatus,
        statusAfterRegister: LaunchAtLoginServiceStatus = .enabled
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
    }

    func register() throws {
        registerCallCount += 1
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }

    func openSystemSettings() {
        openSettingsCallCount += 1
    }
}
