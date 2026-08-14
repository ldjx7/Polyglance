import XCTest
@testable import NativeTranslatorMac
import NativeTranslatorMacKit

final class OpenAIStreamingTranslationTests: XCTestCase {
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
}
