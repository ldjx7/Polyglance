import Foundation
import NativeTranslatorMacKit
import TranslatorCore

final class RustTranslationClient: TranslationClient, @unchecked Sendable {
    private let engine: TranslationEngine
    private let configurationStore: AppConfigurationStore
    private let bundledFreeAIConfiguration: BundledFreeAIConfiguration?

    init(
        configurationStore: AppConfigurationStore,
        bundledFreeAIConfiguration: BundledFreeAIConfiguration? = BundledFreeAIConfiguration()
    ) throws {
        self.configurationStore = configurationStore
        self.bundledFreeAIConfiguration = bundledFreeAIConfiguration
        engine = try TranslationEngine()
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        let configuration = try configurationStore.load()
        let endpoint: String
        let apiKey: String
        let model: String
        let region: String?
        switch configuration.provider {
        case .google:
            endpoint = ""
            apiKey = ""
            model = ""
            region = nil
        case .microsoft:
            endpoint = ""
            apiKey = ""
            model = ""
            region = nil
        case .freeAI:
            guard let bundledFreeAIConfiguration else {
                throw ClientError.freeAIUnavailable
            }
            endpoint = bundledFreeAIConfiguration.endpoint
            apiKey = bundledFreeAIConfiguration.apiKey
            model = bundledFreeAIConfiguration.model
            region = nil
        case .openAICompatible:
            guard !configuration.apiKey.isEmpty else {
                throw ClientError.missingAPIKey
            }
            endpoint = configuration.endpoint
            apiKey = configuration.apiKey
            model = configuration.model
            region = nil
        }

        let input = TranslationInput(
            provider: configuration.provider.rawValue,
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            region: region,
            text: request.text,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        )

        do {
            let output = try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.translate(input: input)
            }.value
            return AppTranslationResult(
                text: output.text,
                provider: output.provider,
                elapsedMilliseconds: output.elapsedMs
            )
        } catch let failure as TranslationFailure {
            throw ClientError(failure)
        }
    }

    func translateStream(
        _ request: AppTranslationRequest
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let configuration = try configurationStore.load()
                    guard configuration.provider == .freeAI
                            || configuration.provider == .openAICompatible else {
                        let result = try await translate(request)
                        continuation.yield(AppTranslationUpdate(
                            text: result.text,
                            provider: result.provider,
                            isFinal: true
                        ))
                        continuation.finish()
                        return
                    }

                    let streamingConfiguration: OpenAIStreamingConfiguration
                    if configuration.provider == .freeAI {
                        guard let bundledFreeAIConfiguration else {
                            throw ClientError.freeAIUnavailable
                        }
                        streamingConfiguration = try OpenAIStreamingConfiguration(
                            endpoint: bundledFreeAIConfiguration.endpoint,
                            apiKey: bundledFreeAIConfiguration.apiKey,
                            model: bundledFreeAIConfiguration.model,
                            denyDataCollection: true
                        )
                    } else {
                        guard !configuration.apiKey.isEmpty else {
                            throw ClientError.missingAPIKey
                        }
                        streamingConfiguration = try OpenAIStreamingConfiguration(
                            endpoint: configuration.endpoint,
                            apiKey: configuration.apiKey,
                            model: configuration.model,
                            denyDataCollection: false
                        )
                    }

                    let service = OpenAIStreamingTranslationService(
                        configuration: streamingConfiguration
                    )
                    var accumulated = ""
                    for try await delta in service.deltas(for: request) {
                        accumulated += delta
                        continuation.yield(AppTranslationUpdate(
                            text: accumulated,
                            provider: configuration.provider.rawValue,
                            isFinal: false
                        ))
                    }
                    let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !finalText.isEmpty else {
                        throw ClientError.invalidResponse
                    }
                    continuation.yield(AppTranslationUpdate(
                        text: finalText,
                        provider: configuration.provider.rawValue,
                        isFinal: true
                    ))
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
private enum ClientError: LocalizedError {
    case missingAPIKey
    case freeAIUnavailable
    case invalidInput
    case invalidConfiguration
    case authentication
    case rateLimited
    case network
    case provider
    case invalidResponse
    case initialization

    init(_ failure: TranslationFailure) {
        switch failure {
        case .InvalidInput:
            self = .invalidInput
        case .InvalidConfiguration:
            self = .invalidConfiguration
        case .Authentication:
            self = .authentication
        case .RateLimited:
            self = .rateLimited
        case .Network:
            self = .network
        case .Provider:
            self = .provider
        case .InvalidResponse:
            self = .invalidResponse
        case .Initialization:
            self = .initialization
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "请先在设置中填写 API Key"
        case .freeAIUnavailable:
            return "当前构建没有配置免费 AI 翻译服务"
        case .invalidInput:
            return "输入内容或语言设置无效"
        case .invalidConfiguration:
            return "翻译服务配置无效，请检查地址和模型"
        case .authentication:
            return "API Key 无效或没有访问权限"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .network:
            return "当前无法连接翻译服务"
        case .provider:
            return "翻译服务暂时不可用"
        case .invalidResponse:
            return "翻译服务返回了无法识别的内容"
        case .initialization:
            return "翻译引擎初始化失败"
        }
    }
}
