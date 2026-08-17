import AppKit
import NativeTranslatorMacKit

@MainActor
final class ScreenTranslationCoordinator {
    private let ocrService: OCRService
    private let translationClient: any TranslationClient
    private let configurationStore: AppConfigurationStore
    private let errorPresenter: OperationErrorPresenter
    private var session: ScreenTranslationOverlaySession?
    private var translationTask: Task<Void, Never>?

    init(
        translationClient: any TranslationClient,
        configurationStore: AppConfigurationStore,
        errorPresenter: OperationErrorPresenter,
        ocrService: OCRService = OCRService()
    ) {
        self.translationClient = translationClient
        self.configurationStore = configurationStore
        self.errorPresenter = errorPresenter
        self.ocrService = ocrService
    }

    func begin(with screenshot: SelectedScreenshot) {
        dismissActiveSession()

        let session = ScreenTranslationOverlaySession(screenshot: screenshot)
        session.onClosed = { [weak self] in
            guard let self, self.session === session else {
                return
            }
            translationTask?.cancel()
            translationTask = nil
            self.session = nil
        }
        self.session = session
        session.present()

        translationTask = Task { [weak self] in
            await self?.translate(screenshot, in: session)
        }
    }

    private func dismissActiveSession() {
        translationTask?.cancel()
        translationTask = nil
        session?.close()
        session = nil
    }

    private func translate(
        _ screenshot: SelectedScreenshot,
        in session: ScreenTranslationOverlaySession
    ) async {
        do {
            guard let cgImage = Self.cgImage(from: screenshot.image) else {
                throw OCRError.invalidImage
            }
            let document = try await ocrService.recognizeDocument(in: cgImage)
            let paragraphs = ScreenTranslationLayout.paragraphs(from: document)
            guard !paragraphs.isEmpty else {
                throw OCRError.noText
            }
            let targetLanguage = try configurationStore.load().targetLanguage
            let translations = try await translateParagraphs(
                paragraphs.map(\.text),
                targetLanguage: targetLanguage
            )
            try Task.checkCancellation()
            guard self.session === session else {
                return
            }
            let rendered = zip(paragraphs, translations).map { paragraph, translation in
                Self.renderedParagraph(
                    paragraph: paragraph,
                    translation: translation,
                    image: cgImage
                )
            }
            session.showTranslation(
                rendered,
                sourceText: paragraphs.map(\.text).joined(separator: "\n"),
                translatedText: translations.joined(separator: "\n")
            )
        } catch is CancellationError {
            return
        } catch {
            guard self.session === session else {
                return
            }
            session.close()
            self.session = nil
            translationTask = nil
            errorPresenter.present(.screenTranslation(error))
        }
    }

    private func translateParagraphs(
        _ texts: [String],
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
                                sourceLanguage: nil,
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
            let luminance = ScreenTranslationColorSampler.luminance(
                red: sampled.red,
                green: sampled.green,
                blue: sampled.blue
            )
            textColor = luminance < 0.46
                ? NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1)
                : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
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
}
