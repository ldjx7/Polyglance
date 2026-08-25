import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class AppBrandingTests: XCTestCase {
    func testDisplayedVersionContainsOnlyTheSemanticVersion() {
        let infoDictionary: [String: Any] = [
            "CFBundleShortVersionString": "0.0.4-beta.4+30bf6a517581515aa00770180ce71f580c08f3fa",
            "CFBundleVersion": "29",
        ]

        XCTAssertEqual(
            AppVersionInfo.displayString(infoDictionary: infoDictionary),
            "v0.0.4-beta.4"
        )
    }

    func testDisplayedVersionDoesNotDuplicateAnExistingPrefix() {
        XCTAssertEqual(
            AppVersionInfo.displayString(infoDictionary: ["CFBundleShortVersionString": "v0.0.4-beta.4"]),
            "v0.0.4-beta.4"
        )
    }

    func testMenuBarIconIsAnAdaptiveTemplateAtStatusItemSize() throws {
        let image = PolyglanceMenuBarIcon.image

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, CGSize(width: 18, height: 18))
        let representation: Data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
        let visiblePixelCount = (0 ..< bitmap.pixelsHigh).reduce(into: 0) { rowCount, y in
            for x in 0 ..< bitmap.pixelsWide where bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.05 {
                rowCount += 1
            }
        }
        XCTAssertGreaterThan(visiblePixelCount, 24)
        XCTAssertLessThan(visiblePixelCount, bitmap.pixelsWide * bitmap.pixelsHigh)
    }
}
