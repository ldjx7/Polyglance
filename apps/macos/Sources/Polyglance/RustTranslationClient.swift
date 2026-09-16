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
        let requestedProviderString = request.provider ?? configuration.provider.rawValue
        let customAi = configuration.customAIConfigs.first(where: {
            $0.id == requestedProviderString || $0.name == requestedProviderString
        })

        let endpoint: String
        let apiKey: String
        let model: String
        let region: String?
        let prompt: String?
        let effectiveProviderString: String

        if let customAi {
            guard !customAi.apiKey.isEmpty else {
                throw ClientError.missingAPIKey
            }
            endpoint = customAi.endpoint
            apiKey = customAi.apiKey
            model = customAi.model
            region = nil
            prompt = customAi.prompt.isEmpty ? nil : customAi.prompt
            effectiveProviderString = customAi.id
        } else {
            prompt = nil
            let activeProvider: TranslationProvider
            if let p = TranslationProvider(rawValue: requestedProviderString) {
                activeProvider = p
            } else {
                activeProvider = configuration.provider
            }
            effectiveProviderString = activeProvider.rawValue
            switch activeProvider {
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
                apiKey = ""
                model = ""
                region = nil
            case .deepl:
                guard !configuration.deeplAuthKey.isEmpty else {
                    throw ClientError.missingAPIKey
                }
                endpoint = configuration.deeplEndpoint
                apiKey = configuration.deeplAuthKey
                model = ""
                region = nil
            case .baidu:
                guard !configuration.baiduAppId.isEmpty && !configuration.baiduSecretKey.isEmpty else {
                    throw ClientError.missingAPIKey
                }
                endpoint = ""
                apiKey = "\(configuration.baiduAppId):\(configuration.baiduSecretKey)"
                model = ""
                region = nil
            case .youdao:
                guard !configuration.youdaoAppKey.isEmpty && !configuration.youdaoSecret.isEmpty else {
                    throw ClientError.missingAPIKey
                }
                endpoint = ""
                apiKey = "\(configuration.youdaoAppKey):\(configuration.youdaoSecret)"
                model = ""
                region = nil
            case .volcano:
                guard !configuration.volcanoAccessKey.isEmpty else {
                    throw ClientError.missingAPIKey
                }
                endpoint = ""
                apiKey = configuration.volcanoSecretKey.isEmpty
                    ? configuration.volcanoAccessKey
                    : "\(configuration.volcanoAccessKey):\(configuration.volcanoSecretKey)"
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
        }

        let input = TranslationInput(
            provider: effectiveProviderString,
            endpoint: endpoint,
            apiKey: apiKey,
            model: model,
            region: region,
            text: request.text,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            prompt: prompt
        )

        do {
            let output = try await Task.detached(priority: .userInitiated) { [engine] in
                try engine.translate(input: input)
            }.value
            let result = AppTranslationResult(
                text: output.text,
                provider: requestedProviderString,
                elapsedMilliseconds: output.elapsedMs
            )
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
                    let requestedProviderString = request.provider ?? configuration.provider.rawValue
                    let customAi = configuration.customAIConfigs.first(where: {
                        $0.id == requestedProviderString || $0.name == requestedProviderString
                    })
                    let isFreeAI = (requestedProviderString == "free-ai" || requestedProviderString == "freeai") && customAi == nil
                    let isCustomAI = customAi != nil || requestedProviderString == "openai-compatible" || requestedProviderString == "openaicompatible"

                    guard configuration.aiStreamingEnabled, (isFreeAI || isCustomAI) else {
                        let result = try await translate(request)
                        continuation.yield(AppTranslationUpdate(
                            text: result.text,
                            provider: requestedProviderString,
                            isFinal: true
                        ))
                        continuation.finish()
                        return
                    }

                    let streamingConfiguration: OpenAIStreamingConfiguration
                    if isFreeAI {
                        guard let bundledFreeAIConfiguration else {
                            throw ClientError.freeAIUnavailable
                        }
                        streamingConfiguration = try OpenAIStreamingConfiguration(
                            freeTranslateEndpoint: bundledFreeAIConfiguration.endpoint
                        )
                    } else {
                        let aiEndpoint = customAi?.endpoint ?? configuration.endpoint
                        let aiApiKey = customAi?.apiKey ?? configuration.apiKey
                        let aiModel = customAi?.model ?? configuration.model
                        let aiPrompt = customAi?.prompt
                        guard !aiApiKey.isEmpty else {
                            throw ClientError.missingAPIKey
                        }
                        streamingConfiguration = try OpenAIStreamingConfiguration(
                            endpoint: aiEndpoint,
                            apiKey: aiApiKey,
                            model: aiModel,
                            denyDataCollection: false,
                            prompt: aiPrompt
                        )
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
                                provider: requestedProviderString,
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
                        provider: requestedProviderString,
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
