import Foundation

public struct AppTranslationRequest: Equatable, Hashable, Sendable {
    public let text: String
    public let sourceLanguage: String?
    public let targetLanguage: String
    public let provider: String?

    public init(text: String, sourceLanguage: String?, targetLanguage: String, provider: String? = nil) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.provider = provider
    }
}

public enum ProviderDisplayMode: String, CaseIterable, Codable, Sendable {
    case normal = "normal"
    case rememberFold = "remember"
    case alwaysFold = "alwaysFold"
    case pinToBar = "pinToBar"
    case closed = "closed"

    public var title: String {
        switch self {
        case .normal: return "普通模式（每次都翻译）"
        case .rememberFold: return "记住折叠状态（折叠后不会自动翻译，点击展开触发翻译并消耗用量）"
        case .alwaysFold: return "总是折叠（不会自动翻译，点击展开触发翻译并消耗用量）"
        case .pinToBar: return "隐藏并钉到语言切换栏（不会自动翻译，点击图标触发一次翻译并消耗用量）"
        case .closed: return "彻底关闭"
        }
    }
}

public struct ProviderTranslationState: Identifiable, Equatable, Sendable {
    public var id: String { provider }
    public let provider: String
    public var displayName: String
    public var text: String
    public var isTranslating: Bool
    public var errorMessage: String?
    public var isCollapsed: Bool
    public var displayMode: ProviderDisplayMode

    public init(
        provider: String,
        displayName: String,
        text: String = "",
        isTranslating: Bool = false,
        errorMessage: String? = nil,
        isCollapsed: Bool = false,
        displayMode: ProviderDisplayMode = .normal
    ) {
        self.provider = provider
        self.displayName = displayName
        self.text = text
        self.isTranslating = isTranslating
        self.errorMessage = errorMessage
        self.isCollapsed = isCollapsed
        self.displayMode = displayMode
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

public struct CustomAIServiceConfig: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var endpoint: String
    public var apiKey: String
    public var model: String
    public var prompt: String
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        endpoint: String = "https://api.openai.com/v1",
        apiKey: String = "",
        model: String = "gpt-4o-mini",
        prompt: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.isEnabled = isEnabled
    }
}
