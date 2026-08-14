import XCTest
@testable import NativeTranslatorMac

@MainActor
final class SelectedTextReaderPermissionTests: XCTestCase {
    func testMissingAccessibilityPermissionDoesNotOpenSystemSettingsAutomatically() async {
        var requestCount = 0
        let reader = SelectedTextReader(
            accessibilityTrustCheck: { false },
            accessibilityPermissionRequest: { requestCount += 1 }
        )

        let result = await reader.read()

        XCTAssertEqual(result, .permissionRequired)
        XCTAssertEqual(requestCount, 0)
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
