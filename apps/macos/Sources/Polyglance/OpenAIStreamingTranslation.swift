import Foundation
import PolyglanceKit

struct TranslationStreamEmissionPolicy {
    let minimumInterval: Duration
    private var lastEmission: Duration?

    init(minimumInterval: Duration) {
        self.minimumInterval = max(.zero, minimumInterval)
    }

    mutating func shouldEmit(at elapsed: Duration, isFinal: Bool) -> Bool {
        if isFinal { return true }
        guard let lastEmission else {
            self.lastEmission = elapsed
            return true
        }
        guard elapsed - lastEmission >= minimumInterval else { return false }
        self.lastEmission = elapsed
        return true
    }
}

enum OpenAIStreamEvent: Equatable {
    case delta(String)
    case done
}

enum OpenAIStreamParser {
    static func event(from line: String) throws -> OpenAIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" { return .done }

        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIStreamingError.invalidResponse
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw OpenAIStreamingError.provider(message)
        }
        guard let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return nil
        }
        guard let content = delta["content"] as? String, !content.isEmpty else {
            return nil
        }
        return .delta(content)
    }
}

struct OpenAIStreamingConfiguration: Sendable {
    private static let maximumResponseCharacters = 2_000_000

    let endpoint: URL
    let apiKey: String
    let model: String
    let denyDataCollection: Bool

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
        self.model = trimmedModel
        self.denyDataCollection = denyDataCollection
    }

    func makeRequest(_ request: AppTranslationRequest) throws -> URLRequest {
        let url = chatCompletionsURL()
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let sourceInstruction = request.sourceLanguage.map { " from \($0)" }
            ?? " after detecting its language"
        let prompt = "Translate the user's text\(sourceInstruction) to \(request.targetLanguage). Return only the translated text, without explanations or quotation marks. Preserve paragraph and sentence boundaries where natural."
        var body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": request.text],
            ],
        ]
        if denyDataCollection {
            body["provider"] = ["data_collection": "deny"]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    private func chatCompletionsURL() -> URL {
        if endpoint.path.hasSuffix("/chat/completions") { return endpoint }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty
            ? "/chat/completions"
            : endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .withLeadingSlash + "/chat/completions"
        return components.url!
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

private extension String {
    var withLeadingSlash: String { hasPrefix("/") ? self : "/" + self }
}

private enum OpenAIStreamingError: LocalizedError {
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
            status == 401 || status == 403
                ? "免费 AI 翻译服务认证失败"
                : "翻译服务返回 HTTP \(status)"
        case .responseTooLarge:
            "翻译结果过大，已停止接收"
        }
    }
}
