import Foundation
import PolyglanceKit
import Translation

@available(macOS 26.0, *)
final class AppleTranslationClient: @unchecked Sendable {
    static let shared = AppleTranslationClient()

    private let availability = LanguageAvailability()

    private func mapLanguage(_ lang: String?) -> Locale.Language? {
        guard let lang = lang?.trimmingCharacters(in: .whitespacesAndNewlines), !lang.isEmpty else {
            return nil
        }
        let lower = lang.lowercased()
        switch lower {
        case "auto":
            return nil
        case "zh", "zh-cn", "zh-hans":
            return Locale.Language(identifier: "zh-Hans")
        case "zh-tw", "zh-hk", "zh-hant":
            return Locale.Language(identifier: "zh-Hant")
        case "en", "en-us", "en-gb":
            return Locale.Language(identifier: "en")
        case "ja":
            return Locale.Language(identifier: "ja")
        case "ko":
            return Locale.Language(identifier: "ko")
        case "fr":
            return Locale.Language(identifier: "fr")
        case "de":
            return Locale.Language(identifier: "de")
        case "es":
            return Locale.Language(identifier: "es")
        case "ru":
            return Locale.Language(identifier: "ru")
        case "it":
            return Locale.Language(identifier: "it")
        case "pt", "pt-br":
            return Locale.Language(identifier: "pt")
        default:
            return Locale.Language(identifier: lang)
        }
    }

    func translate(_ request: AppTranslationRequest) async throws -> AppTranslationResult {
        let startTime = DispatchTime.now()

        let targetLang = mapLanguage(request.targetLanguage) ?? Locale.Language(identifier: "zh-Hans")
        var sourceLang: Locale.Language
        if let mapped = mapLanguage(request.sourceLanguage) {
            sourceLang = mapped
        } else {
            let hasChinese = request.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            sourceLang = hasChinese ? Locale.Language(identifier: "zh-Hans") : Locale.Language(identifier: "en")
        }
        if sourceLang == targetLang {
            if targetLang == Locale.Language(identifier: "zh-Hans") {
                sourceLang = Locale.Language(identifier: "en")
            } else {
                sourceLang = Locale.Language(identifier: "zh-Hans")
            }
        }

        let status = await availability.status(from: sourceLang, to: targetLang)
        if status == .unsupported {
            throw NSError(
                domain: "Polyglance.AppleTranslation",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Apple 翻译暂不支持当前的源语言与目标语言组合。"]
            )
        }

        do {
            let session = TranslationSession(installedSource: sourceLang, target: targetLang)
            let response = try await session.translate(request.text)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
            return AppTranslationResult(
                text: response.targetText,
                provider: "apple",
                elapsedMilliseconds: elapsed
            )
        } catch let error as TranslationError {
            if error.localizedDescription.contains("notInstalled") || "\(error)".contains("notInstalled") {
                throw NSError(
                    domain: "Polyglance.AppleTranslation",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Apple 离线翻译语言包未安装。请打开「系统设置」➔「通用」➔「语言与地区」➔ 滑动至最底部点击「翻译语言...」下载对应离线语言包。"]
                )
            }
            throw error
        }
    }
}
