import Foundation

public struct AppTranslationRequest: Equatable, Sendable {
    public let text: String
    public let sourceLanguage: String?
    public let targetLanguage: String

    public init(text: String, sourceLanguage: String?, targetLanguage: String) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}
public struct AppTranslationResult: Equatable, Sendable {
    public let text: String
    public let provider: String
    public let elapsedMilliseconds: UInt64

    public init(text: String, provider: String, elapsedMilliseconds: UInt64) {
        self.text = text
        self.provider = provider
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct AppTranslationUpdate: Equatable, Sendable {
    public let text: String
    public let provider: String
    public let isFinal: Bool

    public init(text: String, provider: String, isFinal: Bool) {
        self.text = text
        self.provider = provider
        self.isFinal = isFinal
    }
}

public protocol TranslationClient: Sendable {
    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult
    func translateStream(
        _ request: AppTranslationRequest
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error>
}

public extension TranslationClient {
    func translateStream(
        _ request: AppTranslationRequest
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await translate(request)
                    continuation.yield(AppTranslationUpdate(
                        text: result.text,
                        provider: result.provider,
                        isFinal: true
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
