import XCTest
@testable import PolyglanceKit

final class SelectionCapturePipelineTests: XCTestCase {
    func testDirectSelectionWinsWithoutChangingClipboard() async {
        let fallback = CallCounter()
        let pipeline = SelectionCapturePipeline(
            directReader: { "  directly selected  " },
            copyReader: {
                await fallback.increment()
                return "copied"
            }
        )

        let text = await pipeline.read()
        let fallbackCallCount = await fallback.value

        XCTAssertEqual(text, "directly selected")
        XCTAssertEqual(fallbackCallCount, 0)
    }

    func testAutomaticCopyIsUsedWhenDirectSelectionIsUnavailable() async {
        let pipeline = SelectionCapturePipeline(
            directReader: { nil },
            copyReader: { "  copied selection\n" }
        )

        let text = await pipeline.read()

        XCTAssertEqual(text, "copied selection")
    }

    func testBlankResultsAreRejected() async {
        let pipeline = SelectionCapturePipeline(
            directReader: { " \n " },
            copyReader: { "\t" }
        )

        let text = await pipeline.read()

        XCTAssertNil(text)
    }
}

private actor CallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
