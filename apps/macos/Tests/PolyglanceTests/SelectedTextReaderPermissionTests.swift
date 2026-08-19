import XCTest
@testable import Polyglance

@MainActor
final class SelectedTextReaderPermissionTests: XCTestCase {
    /// The system prompt is what puts the app in the Accessibility list, so it
    /// has to fire on the first denied read. Not opening System Settings without
    /// confirmation is a separate guarantee, covered by the error presenter.
    func testMissingAccessibilityPermissionAsksTheSystemForApproval() async {
        var requestCount = 0
        let reader = SelectedTextReader(
            accessibilityTrustCheck: { false },
            accessibilityPermissionRequest: { requestCount += 1 }
        )

        let result = await reader.read()

        XCTAssertEqual(result, .permissionRequired)
        XCTAssertEqual(requestCount, 1)
    }

    func testExplicitAccessibilityPermissionRequestStillUsesTheSystemPrompt() {
        var requestCount = 0
        let reader = SelectedTextReader(
            accessibilityTrustCheck: { false },
            accessibilityPermissionRequest: { requestCount += 1 }
        )

        reader.requestAccessibilityPermission()

        XCTAssertEqual(requestCount, 1)
    }

    func testTrustedReaderDoesNotRequestPermissionWhenNoTextIsSelected() async {
        var requestCount = 0
        let reader = SelectedTextReader(
            accessibilityTrustCheck: { true },
            accessibilityPermissionRequest: { requestCount += 1 },
            directReader: { nil },
            copyReader: { nil }
        )

        let result = await reader.read()

        XCTAssertEqual(result, .noSelection)
        XCTAssertEqual(requestCount, 0)
    }
}
