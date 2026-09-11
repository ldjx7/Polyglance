import AppKit
import NaturalLanguage
import PolyglanceKit

@MainActor
final class ScreenTranslationCoordinator {
    private let ocrService: OCRService
    private let translationClient: any TranslationClient
    private let configurationStore: AppConfigurationStore
    private let errorPresenter: OperationErrorPresenter
    private let pinWindowManager: PinWindowManager
    private let onReselect: @MainActor () -> Void

    private var capture: ScreenTranslationCapture?
    private var session: ScreenTranslationOverlaySession?
    private var selection: CGRect = .zero
    private var sourceLanguage: String?
    private var targetLanguage = "zh-CN"
    private var paragraphs: [ScreenTranslationParagraph] = []
    private var translations: [String] = []
    private var croppedCGImage: CGImage?
    private var generation = 0
    private var pipelineTask: Task<Void, Never>?

    init(
        translationClient: any TranslationClient,
        configurationStore: AppConfigurationStore,
        errorPresenter: OperationErrorPresenter,
        pinWindowManager: PinWindowManager,
        onReselect: @escaping @MainActor () -> Void,
        ocrService: OCRService = OCRService()
    ) {
        self.translationClient = translationClient
        self.configurationStore = configurationStore
        self.errorPresenter = errorPresenter
        self.pinWindowManager = pinWindowManager
        self.onReselect = onReselect
        self.ocrService = ocrService
    }

    func begin(with capture: ScreenTranslationCapture, selection: CGRect) {
        dismissActiveSession()
        let clampedSelection = capture.clamped(selection: selection)
        guard let croppedImage = capture.croppedImage(for: clampedSelection) else {
            errorPresenter.present(.screenTranslation(OCRError.invalidImage))
            return
        }
        self.capture = capture
        self.selection = clampedSelection
        sourceLanguage = nil
        targetLanguage = (try? configurationStore.load().targetLanguage) ?? "zh-CN"

        let session = ScreenTranslationOverlaySession(
            image: croppedImage,
            region: clampedSelection,
            screenBounds: capture.screenFrame
        )
        self.session = session
        configureCallbacks(for: session)
        let config = try? configurationStore.load()
        let currentProvider = config?.provider ?? .freeAI
        session.setProvider(currentProvider)
        session.setLanguages(source: sourceLanguage, target: targetLanguage)
        session.beginLoading()
        session.present()
        startPipeline(reRunOCR: true)
    }

    private func configureCallbacks(for session: ScreenTranslationOverlaySession) {
        session.liveCropProvider = { [weak self] region in
            self?.capture?.croppedImage(for: region)
        }
        session.onProviderChanged = { [weak self] provider in
            guard let self, self.session === session else { return }
            do {
                var config = try self.configurationStore.load()
                config.provider = provider
                try self.configurationStore.save(config)
            } catch {}
            session.beginLoading()
            self.startPipeline(reRunOCR: false)
        }
        session.onRegionChanged = { [weak self] region in
            guard let self, self.session === session else { return }
            selection = capture?.clamped(selection: region) ?? region
            session.beginLoading()
            startPipeline(reRunOCR: true)
        }
        session.onLanguageChanged = { [weak self] source, target in
            guard let self, self.session === session else { return }
            sourceLanguage = source
            targetLanguage = target
            session.beginLoading()
            startPipeline(reRunOCR: false)
        }
        session.onExtractText = { [weak self] in
            self?.extractText()
        }
        session.onReselect = { [weak self] in
            guard let self else { return }
            cleanupAfterSessionClosed()
            onReselect()
        }
        session.onPin = { [weak self] image, region in
            guard let self, self.session === session else { return }
            session.close()
            cleanupAfterSessionClosed()
            pinWindowManager.pin(
                image,
                sourceFrame: region,
                preferredDisplaySize: region.size
            )
        }
        session.onRefresh = { [weak self] in
            self?.refreshFromLiveScreen()
        }
        session.onClosed = { [weak self] in
            self?.cleanupAfterSessionClosed()
        }
    }

    private func dismissActiveSession() {
        pipelineTask?.cancel()
        pipelineTask = nil
        generation += 1
        session?.close()
        session = nil
        capture = nil
        paragraphs = []
        translations = []
        croppedCGImage = nil
    }

    private func cleanupAfterSessionClosed() {
        pipelineTask?.cancel()
        pipelineTask = nil
        generation += 1
        session = nil
        capture = nil
        paragraphs = []
        translations = []
        croppedCGImage = nil
    }

    private func startPipeline(reRunOCR: Bool) {
        pipelineTask?.cancel()
        generation += 1
        let currentGeneration = generation
        pipelineTask = Task { [weak self] in
            await self?.runPipeline(generation: currentGeneration, reRunOCR: reRunOCR)
        }
    }

    private func runPipeline(generation: Int, reRunOCR: Bool) async {
        guard let capture, let session else {
            return
        }
        do {
            guard let croppedImage = capture.croppedImage(for: selection),
                  let cgImage = Self.cgImage(from: croppedImage) else {
                throw OCRError.invalidImage
            }
            if reRunOCR {
                let document = try await ocrService.recognizeDocument(in: cgImage)
                guard self.generation == generation else { return }
                paragraphs = ScreenTranslationLayout.paragraphs(from: document)
                let fullText = paragraphs.map(\.text).joined(separator: "\n")
                let detected = Self.detectLanguageName(for: fullText)
                session.setDetectedLanguage(detected)
            }
            croppedCGImage = cgImage
            guard !paragraphs.isEmpty else {
                throw OCRError.noText
            }
            let translations = try await translateParagraphs(
                paragraphs.map(\.text),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            try Task.checkCancellation()
            guard self.generation == generation, self.session === session else {
                return
            }
            self.translations = translations
            let rendered = zip(paragraphs, translations).map { paragraph, translation in
                Self.renderedParagraph(
                    paragraph: paragraph,
                    translation: translation,
                    image: cgImage
                )
            }
            session.showTranslation(
                rendered,
                image: croppedImage,
                sourceText: paragraphs.map(\.text).joined(separator: "\n"),
                translatedText: translations.joined(separator: "\n")
            )
        } catch is CancellationError {
            return
        } catch {
            guard self.generation == generation, self.session === session else {
                return
            }
            session.close()
            cleanupAfterSessionClosed()
            errorPresenter.present(.screenTranslation(error))
        }
    }

    private func extractText() {
        guard let capture,
              let croppedImage = capture.croppedImage(for: selection),
              !paragraphs.isEmpty,
              !translations.isEmpty else {
            return
        }
        pinWindowManager.pinTranslation(
            image: croppedImage,
            sourceText: paragraphs.map(\.text).joined(separator: "\n"),
            translatedText: translations.joined(separator: "\n"),
            sourceFrame: selection
        )
    }

    private func refreshFromLiveScreen() {
        guard let session, let capture else {
            return
        }
        session.beginLoading()
        session.hideForRecapture()
        let screenFrame = capture.screenFrame
        let currentGeneration = generation + 1
        generation = currentGeneration
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let refreshed = try await ScreenTranslationRecapture.captureScreen(
                    withFrame: screenFrame
                )
                guard let self, self.generation == currentGeneration,
                      self.session === session else {
                    return
                }
                self.capture = refreshed
                selection = refreshed.clamped(selection: selection)
                session.showAfterRecapture()
                if let preview = refreshed.croppedImage(for: selection) {
                    session.showPlainImage(preview)
                }
                await runPipeline(generation: currentGeneration, reRunOCR: true)
            } catch {
                guard let self, self.generation == currentGeneration,
                      self.session === session else {
                    return
                }
                session.showAfterRecapture()
                session.close()
                cleanupAfterSessionClosed()
                errorPresenter.present(.screenTranslation(error))
            }
        }
    }

    private func translateParagraphs(
        _ texts: [String],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [String] {
        var results = [String](repeating: "", count: texts.count)
        let batchSize = 4
        for batchStart in stride(from: 0, to: texts.count, by: batchSize) {
            let batch = Array(batchStart..<min(batchStart + batchSize, texts.count))
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for index in batch {
                    let text = texts[index]
                    group.addTask { [translationClient] in
                        let result = try await translationClient.translate(
                            AppTranslationRequest(
                                text: text,
                                sourceLanguage: sourceLanguage,
                                targetLanguage: targetLanguage
                            )
                        )
                        return (index, result.text)
                    }
                }
                for try await (index, translation) in group {
                    results[index] = translation
                }
            }
            try Task.checkCancellation()
        }
        return results
    }

    private static func renderedParagraph(
        paragraph: ScreenTranslationParagraph,
        translation: String,
        image: CGImage
    ) -> ScreenTranslationRenderedParagraph {
        let sampled = ScreenTranslationColorSampler.averageColor(
            of: image,
            inNormalizedRect: paragraph.boundingBox
        )
        let backgroundColor: NSColor
        let textColor: NSColor
        if let sampled {
            backgroundColor = NSColor(
                srgbRed: sampled.red,
                green: sampled.green,
                blue: sampled.blue,
                alpha: 1
            )
            if let dominant = ScreenTranslationColorSampler.dominantTextColor(
                of: image,
                inNormalizedRect: paragraph.boundingBox,
                background: sampled
            ) {
                textColor = NSColor(
                    srgbRed: dominant.red,
                    green: dominant.green,
                    blue: dominant.blue,
                    alpha: 1
                )
            } else {
                let luminance = ScreenTranslationColorSampler.luminance(
                    red: sampled.red,
                    green: sampled.green,
                    blue: sampled.blue
                )
                textColor = luminance < 0.46
                    ? NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
                    : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            }
        } else {
            backgroundColor = .windowBackgroundColor
            textColor = .labelColor
        }
        return ScreenTranslationRenderedParagraph(
            normalizedRect: paragraph.boundingBox,
            text: translation.trimmingCharacters(in: .whitespacesAndNewlines),
            backgroundColor: backgroundColor,
            textColor: textColor,
            lineCount: paragraph.lineCount
        )
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func detectLanguageName(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "自动检测" }

        if trimmed.range(of: "[\\u3040-\\u30FF]", options: .regularExpression) != nil { return "日语" }
        if trimmed.range(of: "[\\uAC00-\\uD7AF]", options: .regularExpression) != nil { return "韩语" }
        if trimmed.range(of: "[\\u4E00-\\u9FA5]", options: .regularExpression) != nil { return "简体中文" }
        if trimmed.range(of: "[\\u0400-\\u04FF]", options: .regularExpression) != nil { return "俄语" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let isPureASCII = trimmed.allSatisfy { $0.isASCII }
        let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

        if isPureASCII && wordCount <= 2 {
            let dominantConf = recognizer.dominantLanguage.flatMap { hypotheses[$0] } ?? 0
            if dominantConf < 0.75 {
                return "英语"
            }
        }

        guard let lang = recognizer.dominantLanguage else {
            return "英语"
        }

        switch lang {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .russian: return "俄语"
        case .italian: return "意大利语"
        case .portuguese: return "葡萄牙语"
        default:
            if isPureASCII && (hypotheses[lang] ?? 0) < 0.85 {
                return "英语"
            }
            return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
        }
    }
}
