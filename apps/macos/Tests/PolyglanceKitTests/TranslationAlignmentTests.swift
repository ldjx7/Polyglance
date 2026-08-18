import XCTest
@testable import PolyglanceKit

final class TranslationAlignmentTests: XCTestCase {
    func testPairsEnglishAndChineseSentencesInReadingOrder() {
        let pairs = TranslationAlignment.pairs(
            source: "First sentence. Second sentence!\nThird?",
            target: "第一句。第二句！\n第三句？"
        )

        XCTAssertEqual(pairs.map(\.sourceText), ["First sentence.", "Second sentence!", "Third?"])
        XCTAssertEqual(pairs.map(\.targetText), ["第一句。", "第二句！", "第三句？"])
        XCTAssertEqual(pairs.map(\.id), [0, 1, 2])
    }

    func testRangesIdentifyTheSamePairFromEitherText() throws {
        let pairs = TranslationAlignment.pairs(source: "Hello. World!", target: "你好。世界！")
        let first = try XCTUnwrap(pairs.first)

        XCTAssertEqual(("Hello. World!" as NSString).substring(with: first.sourceRange), "Hello.")
        XCTAssertEqual(("你好。世界！" as NSString).substring(with: first.targetRange), "你好。")
        XCTAssertEqual(TranslationAlignment.pairID(at: 2, inSource: true, pairs: pairs), first.id)
        XCTAssertEqual(TranslationAlignment.pairID(at: 1, inSource: false, pairs: pairs), first.id)
    }

    func testUnequalSentenceCountsRemainAddressableWithoutDroppingText() {
        let pairs = TranslationAlignment.pairs(source: "One. Two.", target: "一和二。")

        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].targetText, "一和二。")
        XCTAssertEqual(pairs[1].sourceText, "Two.")
        XCTAssertEqual(pairs[1].targetText, "")
    }
}
