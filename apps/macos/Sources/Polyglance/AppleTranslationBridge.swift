import AppKit
import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    struct RequestItem {
        let text: String
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<String, Error>
    }

    @Published var configuration: TranslationSession.Configuration? = nil
    private var activeSession: TranslationSession? = nil
    private var activeSource: Locale.Language? = nil
    private var activeTarget: Locale.Language? = nil

    private var pendingRequest: RequestItem? = nil
    private var queue: [RequestItem] = []
    private var isProcessing = false

    func handleSession(_ session: TranslationSession) async {
        self.activeSession = session
        self.activeSource = session.sourceLanguage
        self.activeTarget = session.targetLanguage

        if let pending = self.pendingRequest {
            self.pendingRequest = nil
            do {
                let response = try await session.translate(pending.text)
                pending.continuation.resume(returning: response.targetText)
            } catch {
                pending.continuation.resume(throwing: error)
            }
        }
        isProcessing = false
        processNextInQueue()
    }

    func translate(text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let item = RequestItem(text: text, source: source, target: target, continuation: continuation)
            self.queue.append(item)
            self.processNextInQueue()
        }
    }

    private func processNextInQueue() {
        guard !isProcessing, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        isProcessing = true

        if let session = self.activeSession,
           self.activeSource == next.source,
           self.activeTarget == next.target {
            Task { @MainActor in
                defer {
                    self.isProcessing = false
                    self.processNextInQueue()
                }
                do {
                    let response = try await session.translate(next.text)
                    next.continuation.resume(returning: response.targetText)
                } catch {
                    next.continuation.resume(throwing: error)
                }
            }
            return
        }

        self.pendingRequest = next
        self.activeSession = nil
        self.activeSource = nil
        self.activeTarget = nil

        if self.configuration != nil {
            self.configuration = nil
        }
        self.configuration = TranslationSession.Configuration(source: next.source, target: next.target)
    }
}

@available(macOS 15.0, *)
struct AppleTranslationBridgeView: View {
    @ObservedObject var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in
                await bridge.handleSession(session)
            }
    }
}
#endif
