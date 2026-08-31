import XCTest
@testable import Polyglance
import PolyglanceKit

final class OpenAIStreamingTranslationTests: XCTestCase {
    func testEmissionPolicyPublishesFirstUpdateThrottlesIntermediateUpdatesAndAlwaysPublishesFinal() {
        let policy = TranslationStreamEmissionPolicy(minimumInterval: .milliseconds(40))

        XCTAssertTrue(policy.shouldEmit(at: .zero, isFinal: false))
        XCTAssertFalse(policy.shouldEmit(at: .milliseconds(10), isFinal: false))
        XCTAssertFalse(policy.shouldEmit(at: .milliseconds(39), isFinal: false))
        XCTAssertTrue(policy.shouldEmit(at: .milliseconds(40), isFinal: false))
        XCTAssertTrue(policy.shouldEmit(at: .milliseconds(41), isFinal: true))
    }

    func testParserExtractsContentAndRecognizesCompletion() throws {
        XCTAssertEqual(
            try OpenAIStreamParser.event(from: #"data: {"choices":[{"delta":{"content":"你"}}]}"#),
            .delta("你")
        )
        XCTAssertEqual(
            try OpenAIStreamParser.event(from: #"data: {"choices":[{"delta":{"content":"好"}}]}"#),
            .delta("好")
        )
        XCTAssertEqual(try OpenAIStreamParser.event(from: "data: [DONE]"), .done)
        XCTAssertNil(try OpenAIStreamParser.event(from: ": keep-alive"))
        XCTAssertNil(try OpenAIStreamParser.event(from: ""))
    }

    func testParserRejectsProviderErrorWithoutEchoingCredentials() {
        XCTAssertThrowsError(try OpenAIStreamParser.event(
            from: #"data: {"error":{"message":"model unavailable"}}"#
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("model unavailable"))
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
        }
    }

    func testRequestUsesStreamingAndKeepsAPIKeyOutOfURLAndBody() throws {
        let configuration = try OpenAIStreamingConfiguration(
            endpoint: "https://example.com/v1",
            apiKey: "test-secret",
            model: "test-model",
            denyDataCollection: true
        )
        let request = try configuration.makeRequest(AppTranslationRequest(
            text: "Hello",
            sourceLanguage: nil,
            targetLanguage: "zh-CN"
        ))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertNotNil(object["provider"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-secret"))
        XCTAssertFalse(request.url?.absoluteString.contains("test-secret") ?? true)
    }

    func testConfigurationRejectsInsecureRemoteEndpoint() {
        XCTAssertThrowsError(try OpenAIStreamingConfiguration(
            endpoint: "http://example.com/v1",
            apiKey: "test-secret",
            model: "test-model",
            denyDataCollection: false
        ))
    }

    /// The whole point of the bundled endpoint: a captured request reveals the
    /// text being translated and nothing that could be reused to spend money.
    func testFreeTranslateRequestCarriesNeitherModelNorPromptNorCredential() throws {
        let configuration = try OpenAIStreamingConfiguration(
            freeTranslateEndpoint: "https://polyglance.example/api/free-translate"
        )
        let request = try configuration.makeRequest(AppTranslationRequest(
            text: "Hello",
            sourceLanguage: "en",
            targetLanguage: "zh-CN"
        ))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://polyglance.example/api/free-translate"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(object["text"] as? String, "Hello")
        // The shared request builder canonicalizes Worker language aliases to
        // the lowercase wire format accepted by the public translation API.
        XCTAssertEqual(object["target"] as? String, "zh-cn")
        XCTAssertEqual(object["source"] as? String, "en")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertNil(object["model"])
        XCTAssertNil(object["messages"])
        XCTAssertNil(object["temperature"])
        XCTAssertTrue(configuration.model.isEmpty)
    }

    func testFreeTranslateConfigurationRejectsInsecureEndpoint() {
        XCTAssertThrowsError(try OpenAIStreamingConfiguration(
            freeTranslateEndpoint: "http://polyglance.example/api/free-translate"
        ))
    }

    func testStreamingHTTPFailuresUseActionableLocalizedMessages() {
        XCTAssertEqual(
            OpenAIStreamingError.httpStatus(429).errorDescription,
            "翻译请求过于频繁，请稍后再试"
        )
        XCTAssertEqual(
            OpenAIStreamingError.httpStatus(503).errorDescription,
            "翻译服务暂时不可用，请稍后再试"
        )
    }
}
