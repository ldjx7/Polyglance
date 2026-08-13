import XCTest
@testable import NativeTranslatorMac

final class AppUpdaterTests: XCTestCase {
    func testConfigurationRequiresHTTPSFeedAndPublicKey() {
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [:]).isConfigured)
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": "public-key",
        ]).isConfigured)
        XCTAssertFalse(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml",
        ]).isConfigured)
        XCTAssertTrue(AppUpdateConfiguration(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": "public-key",
        ]).isConfigured)
    }
}
