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

public protocol TranslationClient: Sendable {
    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult
}
