import XCTest
@testable import PolyglanceKit

final class TextFormattingServiceTests: XCTestCase {
    func testSmartMergeLinesMergesChineseLinesWithoutSpace() {
        let input = "这是一个由于换行产生的\n句子被切断了。"
        let result = TextFormattingService.smartMergeLines(input)
        XCTAssertEqual(result, "这是一个由于换行产生的句子被切断了。")
    }

    func testSmartMergeLinesMergesEnglishLinesWithSpace() {
        let input = "This is a sentence that was\nbroken across lines."
        let result = TextFormattingService.smartMergeLines(input)
        XCTAssertEqual(result, "This is a sentence that was broken across lines.")
    }

    func testSmartMergeLinesPreservesParagraphBreaks() {
        let input = "第一段第一行。\n\n第二段第一行。\n第二段第二行。"
        let result = TextFormattingService.smartMergeLines(input)
        XCTAssertEqual(result, "第一段第一行。\n\n第二段第一行。\n第二段第二行。")
    }

    func testSmartMergeLinesPreservesListItems() {
        let input = "说明如下：\n- 第一项内容\n- 第二项内容"
        let result = TextFormattingService.smartMergeLines(input)
        XCTAssertEqual(result, "说明如下：\n- 第一项内容\n- 第二项内容")
    }

    func testApplyPanguSpacingAddsSpaceBetweenCjkAndAlphaNumeric() {
        let input = "使用Polyglance进行OCR识别，准确率达到99.9%以上。"
        let result = TextFormattingService.applyPanguSpacing(input)
        XCTAssertEqual(result, "使用 Polyglance 进行 OCR 识别，准确率达到 99.9% 以上。")
    }

    func testRemoveExtraneousSpacesRemovesSpacesBetweenCjk() {
        let input = "你 好 世 界 ， 这 是 一 段 测 试 。 Hello World!"
        let result = TextFormattingService.removeExtraneousSpaces(input)
        XCTAssertEqual(result, "你好世界，这是一段测试。Hello World!")
    }

    func testFormatSmartMergeCombinesMergeAndPangu() {
        let input = "这是第一行具有OCR\n识别能力的文本。"
        let result = TextFormattingService.format(input, mode: .smartMerge)
        XCTAssertEqual(result, "这是第一行具有 OCR 识别能力的文本。")
    }
}
