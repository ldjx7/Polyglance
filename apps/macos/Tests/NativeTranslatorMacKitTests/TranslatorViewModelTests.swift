import XCTest
@testable import NativeTranslatorMacKit

@MainActor
final class TranslatorViewModelTests: XCTestCase {
    func testSuccessfulTranslationPublishesResult() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "你好", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"

        await viewModel.translate()

        XCTAssertEqual(viewModel.translatedText, "你好")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isTranslating)
    }

    func testBlankTextIsRejectedWithoutCallingClient() async {
        let client = StubTranslationClient(result: .failure(TestFailure.unexpectedCall))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "  \n "

        await viewModel.translate()

        XCTAssertEqual(viewModel.errorMessage, "请输入要翻译的文本")
        let callCount = await client.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testClientFailureBecomesUserVisible() async {
        let client = StubTranslationClient(result: .failure(TestFailure.offline))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"

        await viewModel.translate()

        XCTAssertEqual(viewModel.errorMessage, "当前无法连接翻译服务")
        XCTAssertEqual(viewModel.translatedText, "")
    }

    func testCapturedTextIsTrimmed() {
        let client = StubTranslationClient(result: .failure(TestFailure.unexpectedCall))
        let viewModel = TranslatorViewModel(client: client)

        viewModel.applyCapturedText("  selected text \n")

        XCTAssertEqual(viewModel.sourceText, "selected text")
    }

    func testPlatformErrorCanBePresentedWithoutChangingSourceText() {
        let client = StubTranslationClient(result: .failure(TestFailure.unexpectedCall))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Keep me"

        viewModel.presentError("快捷键注册失败")

        XCTAssertEqual(viewModel.errorMessage, "快捷键注册失败")
        XCTAssertEqual(viewModel.sourceText, "Keep me")
    }

    func testClearRemovesSourceResultAndError() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "你好", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"
        await viewModel.translate()
        viewModel.presentError("测试错误")

        viewModel.clear()

        XCTAssertEqual(viewModel.sourceText, "")
        XCTAssertEqual(viewModel.translatedText, "")
        XCTAssertNil(viewModel.errorMessage)
    }
}

private actor StubTranslationClient: TranslationClient {
    private(set) var callCount = 0
    private let result: Result<AppTranslationResult, Error>

    init(result: Result<AppTranslationResult, Error>) {
        self.result = result
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        callCount += 1
        return try result.get()
    }
}

private enum TestFailure: LocalizedError {
    case offline
    case unexpectedCall

    var errorDescription: String? {
        switch self {
        case .offline:
            return "当前无法连接翻译服务"
        case .unexpectedCall:
            return "不应发起翻译请求"
        }
    }
}
