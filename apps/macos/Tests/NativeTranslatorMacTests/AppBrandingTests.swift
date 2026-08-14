import AppKit
import XCTest
@testable import NativeTranslatorMac

@MainActor
final class AppBrandingTests: XCTestCase {
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
