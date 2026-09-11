import XCTest
@testable import PolyglanceKit

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

    func testStreamingTranslationPublishesProgressBeforeCompletion() async {
        let client = StreamingStubTranslationClient(updates: [
            AppTranslationUpdate(text: "你", provider: "stream", isFinal: false),
            AppTranslationUpdate(text: "你好", provider: "stream", isFinal: true),
        ])
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"

        let task = Task { await viewModel.translate() }
        await client.waitUntilFirstUpdateWasConsumed()
        for _ in 0..<100 where viewModel.translatedText.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(viewModel.translatedText, "你")
        XCTAssertTrue(viewModel.isTranslating)

        await client.releaseRemainingUpdates()
        await task.value
        XCTAssertEqual(viewModel.translatedText, "你好")
        XCTAssertFalse(viewModel.isTranslating)
    }

    func testAlignmentPairsSourceAndTranslatedSentences() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "你好。世界！", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello. World!"

        await viewModel.translate()

        XCTAssertEqual(viewModel.alignedSegments.map(\.sourceText), ["Hello.", "World!"])
        XCTAssertEqual(viewModel.alignedSegments.map(\.targetText), ["你好。", "世界！"])
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

    func testSubsequentTranslationClearsPreviousResultAndTranslates() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "你好", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"
        await viewModel.translate()
        XCTAssertEqual(viewModel.translatedText, "你好")
        let firstCount = await client.callCount
        XCTAssertEqual(firstCount, 1)

        viewModel.sourceText = "World"
        await viewModel.translate()
        XCTAssertEqual(viewModel.translatedText, "你好")
        let secondCount = await client.callCount
        XCTAssertEqual(secondCount, 2)
    }

    func testReTranslationWithSameSourceTextClearsPreviousResultAndTranslates() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "你好", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.sourceText = "Hello"
        await viewModel.translate()
        XCTAssertEqual(viewModel.translatedText, "你好")
        let firstCount = await client.callCount
        XCTAssertEqual(firstCount, 1)

        await viewModel.translate()
        XCTAssertEqual(viewModel.translatedText, "你好")
        let secondCount = await client.callCount
        XCTAssertEqual(secondCount, 2)
    }

    func testEnteringChineseAutomaticallySwitchesTargetLanguageToSecondTargetLanguage() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "Hello", provider: "test", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.defaultTargetLanguage = "zh-CN"
        viewModel.secondTargetLanguage = "en"

        viewModel.sourceText = "你好世界"
        await viewModel.translate()

        XCTAssertEqual(viewModel.targetLanguage, "en")
        let lastTarget = await client.lastRequest?.targetLanguage
        XCTAssertEqual(lastTarget, "en")

        viewModel.sourceText = "Hello world"
        await viewModel.translate()

        XCTAssertEqual(viewModel.targetLanguage, "zh-CN")
        let secondTarget = await client.lastRequest?.targetLanguage
        XCTAssertEqual(secondTarget, "zh-CN")
    }

    func testSwitchingLanguageDirectionViaApplyCapturedTextTranslatesSuccessfully() async {
        let client = StubTranslationClient(result: .success(
            AppTranslationResult(text: "Hello", provider: "free-ai", elapsedMilliseconds: 12)
        ))
        let viewModel = TranslatorViewModel(client: client)
        viewModel.defaultTargetLanguage = "zh-CN"
        viewModel.secondTargetLanguage = "en"

        // First translation: English to Chinese
        viewModel.applyCapturedText("Hello world")
        viewModel.startTranslation()
        await viewModel.debouncedTask?.value

        XCTAssertEqual(viewModel.targetLanguage, "zh-CN")
        XCTAssertEqual(viewModel.translatedText, "Hello")
        XCTAssertFalse(viewModel.providerStates.first?.text.isEmpty ?? true)

        // Second translation: Chinese to English (switches language direction)
        viewModel.applyCapturedText("你好世界")
        viewModel.startTranslation()
        await viewModel.debouncedTask?.value

        XCTAssertEqual(viewModel.targetLanguage, "en")
        XCTAssertEqual(viewModel.translatedText, "Hello")
        XCTAssertFalse(viewModel.providerStates.first?.text.isEmpty ?? true)
    }
}

private actor StubTranslationClient: TranslationClient {
    private(set) var callCount = 0
    private(set) var lastRequest: AppTranslationRequest?
    private let result: Result<AppTranslationResult, Error>

    init(result: Result<AppTranslationResult, Error>) {
        self.result = result
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        callCount += 1
        lastRequest = request
        return try result.get()
    }
}

private actor StreamingStubTranslationClient: TranslationClient {
    private let updates: [AppTranslationUpdate]
    private var firstUpdateConsumed = false
    private var firstUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(updates: [AppTranslationUpdate]) {
        self.updates = updates
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        AppTranslationResult(
            text: updates.last?.text ?? "",
            provider: updates.last?.provider ?? "stream",
            elapsedMilliseconds: 0
        )
    }

    nonisolated func translateStream(
        _ request: AppTranslationRequest
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let values = self.updates
                for (index, update) in values.enumerated() {
                    continuation.yield(update)
                    if index == 0 {
                        await self.markFirstUpdateConsumed()
                        await self.waitForRelease()
                    }
                }
                continuation.finish()
            }
        }
    }

    func waitUntilFirstUpdateWasConsumed() async {
        if firstUpdateConsumed { return }
        await withCheckedContinuation { firstUpdateWaiters.append($0) }
    }

    func releaseRemainingUpdates() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }

    private func markFirstUpdateConsumed() {
        firstUpdateConsumed = true
        firstUpdateWaiters.forEach { $0.resume() }
        firstUpdateWaiters.removeAll()
    }

    private func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
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
