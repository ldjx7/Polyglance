import Foundation
import PolyglanceKit
import TranslatorCore

/// Thin forwarding layer over `translator-providers`.
struct TranslationStreamEmissionPolicy {
    private let policy: StreamEmissionPolicy

    init(minimumInterval: Duration) {
        let components = max(.zero, minimumInterval).components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        policy = StreamEmissionPolicy(minimumIntervalNanoseconds: nanoseconds)
    }

    func shouldEmit(at elapsed: Duration, isFinal: Bool) -> Bool {
        let components = elapsed.components
        let nanoseconds = components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
        return policy.shouldEmit(elapsedNanoseconds: nanoseconds, isFinal: isFinal)
    }
}

enum OpenAIStreamEvent: Equatable {
    case delta(String)
    case done
}

enum OpenAIStreamParser {
    static func event(from line: String) throws -> OpenAIStreamEvent? {
        do {
            switch try TranslatorCore.streamEvent(line: line) {
            case .none:
                return nil
            case let .delta(text):
                return .delta(text)
            case .done:
                return .done
            }
        } catch StreamParseFailure.InvalidResponse {
            throw OpenAIStreamingError.invalidResponse
        } catch let StreamParseFailure.Provider(message) {
            throw OpenAIStreamingError.provider(message)
        }
    }
}

/// How the request is shaped on the wire.
///
/// The bundled free service is deliberately not OpenAI-shaped. It accepts
/// content and languages and nothing else, so a reverse-engineered client can
/// neither name a model nor rewrite the prompt.
enum StreamingRequestShape: Sendable {
    case chatCompletions(model: String, denyDataCollection: Bool)
    case freeTranslate
}

struct OpenAIStreamingConfiguration: Sendable {
    private static let maximumResponseCharacters = 2_000_000

    let endpoint: URL
    let apiKey: String
    let shape: StreamingRequestShape

    init(
        endpoint: String,
        apiKey: String,
        model: String,
        denyDataCollection: Bool
    ) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, !trimmedModel.isEmpty,
              let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || (scheme == "http" && Self.isLoopback(url))) else {
            throw OpenAIStreamingError.invalidConfiguration
        }
        self.endpoint = url
        self.apiKey = trimmedKey
        self.shape = .chatCompletions(
            model: trimmedModel,
            denyDataCollection: denyDataCollection
        )
    }

    /// The bundled service needs no credential and no model, because the Worker
    /// it talks to owns both.
    init(freeTranslateEndpoint: String) throws {
        guard let url = URL(
            string: freeTranslateEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        ), url.scheme?.lowercased() == "https" else {
            throw OpenAIStreamingError.invalidConfiguration
        }
        self.endpoint = url
        self.apiKey = ""
        self.shape = .freeTranslate
    }

    /// Empty for the bundled service, which names its own model server-side.
    var model: String {
        guard case let .chatCompletions(model, _) = shape else { return "" }
        return model
    }

    func makeRequest(_ request: AppTranslationRequest) throws -> URLRequest {
        let url: URL?
        let body: String
        switch shape {
        case let .chatCompletions(model, denyDataCollection):
            url = URL(string: streamChatCompletionsUrl(endpoint: endpoint.absoluteString))
            body = streamRequestBody(
                model: model,
                text: request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                denyDataCollection: denyDataCollection
            )
        case .freeTranslate:
            url = URL(string: streamFreeTranslateUrl(endpoint: endpoint.absoluteString))
            body = streamFreeTranslateRequestBody(
                text: request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage
            )
        }
        guard let url else {
            throw OpenAIStreamingError.invalidConfiguration
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = Data(body.utf8)
        return urlRequest
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static var maximumCharacters: Int { maximumResponseCharacters }
}

final class OpenAIStreamingTranslationService: @unchecked Sendable {
    private let configuration: OpenAIStreamingConfiguration
    private let session: URLSession

    init(
        configuration: OpenAIStreamingConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    func deltas(
        for request: AppTranslationRequest
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try configuration.makeRequest(request)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw OpenAIStreamingError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw OpenAIStreamingError.httpStatus(httpResponse.statusCode)
                    }
                    var receivedCharacters = 0
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch try OpenAIStreamParser.event(from: line) {
                        case let .delta(content):
                            receivedCharacters += content.count
                            guard receivedCharacters <= OpenAIStreamingConfiguration.maximumCharacters else {
                                throw OpenAIStreamingError.responseTooLarge
                            }
                            continuation.yield(content)
                        case .done:
                            continuation.finish()
                            return
                        case nil:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum OpenAIStreamingError: LocalizedError {
    case invalidConfiguration
    case invalidResponse
    case provider(String)
    case httpStatus(Int)
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "翻译服务配置无效，请检查地址和模型"
        case .invalidResponse:
            "翻译服务返回了无法识别的流式内容"
        case let .provider(message):
            "翻译服务暂时不可用：\(message)"
        case let .httpStatus(status):
            switch status {
            case 401, 403:
                "翻译服务认证失败"
            case 429:
                "翻译请求过于频繁，请稍后再试"
            case 503:
                "翻译服务暂时不可用，请稍后再试"
            default:
                "翻译服务返回 HTTP \(status)"
            }
        case .responseTooLarge:
            "翻译结果过大，已停止接收"
        }
    }
}
