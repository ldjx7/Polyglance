import Foundation
import NativeTranslatorMacKit
import TranslatorCore

final class RustTranslationClient: TranslationClient, @unchecked Sendable {
    private let engine: TranslationEngine
    private let configurationStore: AppConfigurationStore

    init(configurationStore: AppConfigurationStore) throws {
        self.configurationStore = configurationStore
        engine = try TranslationEngine()
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        let configuration = try configurationStore.load()
        guard !configuration.apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        let input = TranslationInput(
            endpoint: configuration.endpoint,
            apiKey: configuration.apiKey,
            model: configuration.model,
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
}
private enum ClientError: LocalizedError {
    case missingAPIKey
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
