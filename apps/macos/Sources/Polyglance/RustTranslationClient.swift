import Foundation
import PolyglanceKit
import TranslatorCore

final class RustTranslationClient: TranslationClient, @unchecked Sendable {
    private let engine: TranslationEngine
    private let configurationStore: AppConfigurationStore
    private let bundledFreeAIConfiguration: BundledFreeAIConfiguration?
    private let cache: TranslationMemoryCache

    init(
        configurationStore: AppConfigurationStore,
        bundledFreeAIConfiguration: BundledFreeAIConfiguration? = BundledFreeAIConfiguration(),
        cache: TranslationMemoryCache = TranslationMemoryCache()
    ) throws {
        self.configurationStore = configurationStore
        self.bundledFreeAIConfiguration = bundledFreeAIConfiguration
        self.cache = cache
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
            // The Worker owns the credential and the model. Neither is shipped
            // in an open-source bundle, so neither is sent.
            endpoint = bundledFreeAIConfiguration.endpoint
            apiKey = ""
            model = ""
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

        let cacheKey = Self.cacheKey(
            provider: configuration.provider,
            endpoint: endpoint,
            model: model,
            request: request
        )
        if let cached = await cache.value(for: cacheKey) {
            return AppTranslationResult(
                text: cached.text,
                provider: cached.provider,
                elapsedMilliseconds: 0
            )
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
            let result = AppTranslationResult(
                text: output.text,
                provider: output.provider,
                elapsedMilliseconds: output.elapsedMs
            )
            await cache.insert(result, for: cacheKey)
            return result
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
                    guard configuration.aiStreamingEnabled,
                          configuration.provider == .freeAI
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
                            freeTranslateEndpoint: bundledFreeAIConfiguration.endpoint
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

                    let cacheKey = Self.cacheKey(
                        provider: configuration.provider,
                        endpoint: streamingConfiguration.endpoint.absoluteString,
                        model: streamingConfiguration.model,
                        request: request
                    )
                    if let cached = await cache.value(for: cacheKey) {
                        continuation.yield(AppTranslationUpdate(
                            text: cached.text,
                            provider: cached.provider,
                            isFinal: true
                        ))
                        continuation.finish()
                        return
                    }

                    let service = OpenAIStreamingTranslationService(
                        configuration: streamingConfiguration
                    )
                    var accumulated = ""
                    let clock = ContinuousClock()
                    let startedAt = clock.now
                    let emissionPolicy = TranslationStreamEmissionPolicy(
                        minimumInterval: .milliseconds(40)
                    )
                    for try await delta in service.deltas(for: request) {
                        accumulated += delta
                        let elapsed = startedAt.duration(to: clock.now)
                        if emissionPolicy.shouldEmit(at: elapsed, isFinal: false) {
                            continuation.yield(AppTranslationUpdate(
                                text: accumulated,
                                provider: configuration.provider.rawValue,
                                isFinal: false
                            ))
                        }
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
                    await cache.insert(
                        AppTranslationResult(
                            text: finalText,
                            provider: configuration.provider.rawValue,
                            elapsedMilliseconds: 0
                        ),
                        for: cacheKey
                    )
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

    private static func cacheKey(
        provider: TranslationProvider,
        endpoint: String,
        model: String,
        request: AppTranslationRequest
    ) -> TranslationCacheKey {
        TranslationCacheKey(
            provider: provider.rawValue,
            endpoint: endpoint,
            model: model,
            request: request
        )
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
            return "免费 AI 翻译服务地址无效"
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
