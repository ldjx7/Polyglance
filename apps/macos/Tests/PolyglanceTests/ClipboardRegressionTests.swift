import AppKit
import XCTest
import TranslatorCore
@testable import Polyglance

@MainActor
final class ClipboardRegressionTests: XCTestCase {
    func testRangeSelectionAfterFilteringAndClearingUsesTheCurrentList() async throws {
        try await withFixture { fixture in
            for index in 0..<12 { _ = try await fixture.record(index < 2 ? "keep \(index)" : "other \(index)") }
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            service.select(service.entries[8].id)
            service.moveSelection(1, extending: true)
            service.query = "keep"; await service.reload()
            XCTAssertEqual(service.entries.count, 2)
            service.moveSelection(1, extending: true)
            XCTAssertEqual(service.selectedIDs, Set(service.entries.map(\.id)))
            try await fixture.worker.clear(includePinned: true); await service.reload()
            _ = try await fixture.record("keep after clear"); await service.reload()
            service.moveSelection(-10, extending: true)
            XCTAssertEqual(service.selectedIDs, Set(service.entries.map(\.id)))
        }
    }

    func testClickingAnotherRowResetsTheKeyboardRangeAnchor() async throws {
        try await withFixture { fixture in
            for index in 0..<12 { _ = try await fixture.record("entry \(index)") }
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            service.select(service.entries[8].id); service.moveSelection(1, extending: true)
            service.select(service.entries[1].id); service.moveSelection(1, extending: true)
            XCTAssertEqual(service.selectedIDs, Set(service.entries[1...2].map(\.id)))
        }
    }

    func testUIClearDrainsAnUncancellableCaptureAndResumesMonitoring() async throws {
        try await checkClear(shortcut: false)
    }

    func testShortcutClearDrainsAnUncancellableCaptureAndResumesMonitoring() async throws {
        try await checkClear(shortcut: true)
    }

    private func checkClear(shortcut: Bool) async throws {
        let processor = SuspendedClipboardProcessor()
        try await withFixture(processor: processor) { fixture in
            let service = fixture.service
            var preferences = ClipboardHistoryPreferences(); preferences.enabled = true
            await service.savePreferences(preferences)
            _ = try await fixture.record("existing history")
            fixture.board.clearContents()
            XCTAssertTrue(fixture.board.setString("captured before clear", forType: .string))
            try await self.eventually("the external copy should reach normalization") {
                service.poll()
                return await processor.normalizationStarted
            }
            let clearing = Task {
                if shortcut { try await service.shortcutClear(includePinned: true) }
                else { await service.clear(includePinned: true) }
            }
            do {
                try await self.eventually("clear should wait for the suspended capture") { service.dataBusy }
                let before = try await fixture.worker.stats()
                XCTAssertEqual(before.items, 1, "Clear must wait for work already in progress.")
                await processor.release()
                try await clearing.value
            } catch {
                await processor.release()
                _ = try? await clearing.value
                throw error
            }
            let cleared = try await fixture.worker.stats()
            XCTAssertEqual(cleared.items, 0)
            service.poll()
            XCTAssertEqual(fixture.board.string(forType: .string), "captured before clear")
            fixture.board.clearContents(); fixture.board.setString("copied after clear", forType: .string)
            try await self.eventually("monitoring should resume after clear") {
                service.poll()
                return try await fixture.worker.stats().items == 1
            }
            let rows = try await fixture.worker.list(query: "", pinnedOnly: false, offset: 0)
            XCTAssertEqual(rows.map(\.preview), ["copied after clear"])
        }
    }

    func testEscapeCancelsCopyAndPasteWaitingForSearchEvenIfTheWindowReopens() async throws {
        for paste in [false, true] {
            try await withFixture { fixture in
                _ = try await fixture.record("selected history")
                let service = fixture.service
                service.preparePresentation(); await service.waitForPresentation()
                fixture.board.setString("leave clipboard alone", forType: .string)
                var committed = false
                service.onDismiss = { committed = true; service.didDismiss() }
                service.query = "selected"
                let copying = Task { await service.copySelected(paste: paste) }
                try await self.eventually { service.copyBusy }
                let panel = ClipboardHistoryPanel(service: service)
                panel.onDismissed = { service.didDismiss() }
                panel.cancelOperation(nil)
                service.preparePresentation()
                await copying.value
                await service.waitForPresentation()
                XCTAssertEqual(fixture.board.string(forType: .string), "leave clipboard alone")
                XCTAssertFalse(committed)
                XCTAssertNil(service.errorMessage, "A cancelled paste must not request Accessibility permission.")
                XCTAssertFalse(service.copyBusy)
                service.onDismiss = nil
            }
        }
    }

    func testExternalClipboardChangeIsPreservedWhileCopyWaitsForSearch() async throws {
        try await withFixture(searchDelay: .milliseconds(500)) { fixture in
            _ = try await fixture.record("selected history")
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            fixture.board.setString("initial", forType: .string)
            service.query = "selected"
            let copying = Task { await service.copySelected() }
            try await self.eventually { service.copyBusy }
            fixture.board.clearContents(); fixture.board.setString("new external copy", forType: .string)
            await copying.value
            XCTAssertEqual(fixture.board.string(forType: .string), "new external copy")
        }
    }

    func testNormalCopyCanCommitAndDismissItsOwnPresentation() async throws {
        try await withFixture { fixture in
            _ = try await fixture.record("selected history")
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            var dismissed = false
            service.onDismiss = { dismissed = true; service.didDismiss() }
            await service.copySelected()
            XCTAssertEqual(fixture.board.string(forType: .string), "selected history")
            XCTAssertTrue(dismissed)
            XCTAssertFalse(service.copyBusy)
            service.onDismiss = nil
        }
    }

    func testGeneratedBindingsRejectOCRFromAnOlderCapture() async throws {
        try await withFixture { fixture in
            let representations = [
                ClipboardRepresentation(format: "text/plain", bytes: Data("same text".utf8)),
                ClipboardRepresentation(format: "image/png", bytes: clipboardTestPNG)
            ]
            let storedID = try await fixture.worker.record(
                ClipboardInput(representations: representations, sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now),
                policy: fixture.policy)
            let id = try XCTUnwrap(storedID)
            let snapshot = try await fixture.worker.ocrSnapshot(id: id)
            _ = try await fixture.record("same text")
            let stored = try await fixture.worker.storeOCR(record: snapshot.record, text: "late OCR")
            try await fixture.worker.failOCR(record: snapshot.record)
            XCTAssertFalse(stored)
            let annotation = try await fixture.worker.annotation(id: id)
            XCTAssertTrue(annotation.ocrText.isEmpty)
        }
    }

    func testDismissalCancelsManualOCRAndIgnoresLateResultsAndErrors() async throws {
        for reopen in [false, true] {
            for fail in [false, true] {
                let processor = SuspendedClipboardOCRProcessor()
                try await withFixture(processor: processor) { fixture in
                    let id = try await fixture.recordImage()
                    let service = fixture.service
                    service.preparePresentation(); await service.waitForPresentation()
                    var results: [String] = []
                    service.onRecognizeText = { results.append($0) }
                    let recognizing = Task { await service.recognizeTextSelected() }
                    try await self.eventually { await processor.requests == 1 }
                    let panel = ClipboardHistoryPanel(service: service)
                    panel.onDismissed = { service.didDismiss() }
                    panel.cancelOperation(nil)
                    XCTAssertFalse(service.recognizingText)
                    if reopen { service.preparePresentation(); await service.waitForPresentation() }
                    await processor.release(1, text: "late result", fail: fail)
                    await recognizing.value
                    let cancelled = await processor.cancelledRequests
                    XCTAssertEqual(cancelled, [1], "Dismissal must cancel the actual processing task.")
                    XCTAssertTrue(results.isEmpty)
                    XCTAssertNil(service.errorMessage)
                    XCTAssertTrue(service.statusMessage.isEmpty)
                    let annotation = try await fixture.worker.annotation(id: id)
                    XCTAssertTrue(annotation.ocrText.isEmpty, "A dismissed recognition must not write a late index.")
                }
            }
        }
    }

    func testOldOCRCompletionCannotClearANewerRecognitionAfterReopening() async throws {
        let processor = SuspendedClipboardOCRProcessor()
        try await withFixture(processor: processor) { fixture in
            let id = try await fixture.recordImage()
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            var results: [String] = []
            var dismissals = 0
            service.onRecognizeText = { results.append($0) }
            service.onDismiss = { dismissals += 1; service.didDismiss() }
            let old = Task { await service.recognizeTextSelected() }
            try await self.eventually { await processor.requests == 1 }
            service.didDismiss(); service.preparePresentation(); await service.waitForPresentation()
            let current = Task { await service.recognizeTextSelected() }
            try await self.eventually { await processor.requests == 2 }
            await service.reload() // Refreshing the same selection keeps its active recognition.
            await processor.release(1, text: "old result"); await old.value
            XCTAssertTrue(service.recognizingText)
            XCTAssertTrue(results.isEmpty)
            XCTAssertEqual(dismissals, 0)
            await processor.release(2, text: "current result"); await current.value
            XCTAssertFalse(service.recognizingText)
            XCTAssertEqual(results, ["current result"])
            XCTAssertEqual(dismissals, 1)
            let annotation = try await fixture.worker.annotation(id: id)
            XCTAssertEqual(annotation.ocrText, "current result")
        }
    }

    func testChangingSelectionCancelsOCREvenWhenReturningToTheSameEntry() async throws {
        let processor = SuspendedClipboardOCRProcessor()
        try await withFixture(processor: processor) { fixture in
            let imageID = try await fixture.recordImage()
            let otherID = try await fixture.record("other entry")
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation(); service.select(imageID)
            var presented = false
            service.onRecognizeText = { _ in presented = true }
            let recognizing = Task { await service.recognizeTextSelected() }
            try await self.eventually { await processor.requests == 1 }
            service.select(otherID); service.select(imageID)
            await processor.release(1); await recognizing.value
            XCTAssertFalse(presented)
            XCTAssertFalse(service.recognizingText)
            XCTAssertNil(service.errorMessage)
        }
    }

    func testClearAndImportCancelManualOCRBeforeChangingHistory() async throws {
        for restore in [false, true] {
            let processor = SuspendedClipboardOCRProcessor()
            try await withFixture(processor: processor) { fixture in
                _ = try await fixture.recordImage()
                let backup = fixture.directory.appendingPathComponent("backup.polyclipboard")
                try await fixture.worker.exportBackup(path: backup.path)
                let service = fixture.service
                service.preparePresentation(); await service.waitForPresentation()
                var presented = false
                service.onRecognizeText = { _ in presented = true }
                let recognizing = Task { await service.recognizeTextSelected() }
                try await self.eventually { await processor.requests == 1 }
                if restore { await service.importBackup(from: backup, mode: .replace) }
                else { await service.clear(includePinned: true) }
                XCTAssertFalse(service.recognizingText)
                await processor.release(1, text: "outdated"); await recognizing.value
                XCTAssertFalse(presented)
                XCTAssertNil(service.errorMessage)
                let rows = try await fixture.worker.list(query: "outdated", pinnedOnly: false, offset: 0)
                XCTAssertTrue(rows.isEmpty)
            }
        }
    }

    func testCallerCancellationReachesTheManualOCRTask() async throws {
        let processor = SuspendedClipboardOCRProcessor()
        try await withFixture(processor: processor) { fixture in
            _ = try await fixture.recordImage()
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            var presented = false
            service.onRecognizeText = { _ in presented = true }
            let recognizing = Task { await service.recognizeTextSelected() }
            try await self.eventually { await processor.requests == 1 }
            recognizing.cancel()
            await processor.release(1); await recognizing.value
            let cancelled = await processor.cancelledRequests
            XCTAssertEqual(cancelled, [1])
            XCTAssertFalse(presented)
            XCTAssertFalse(service.recognizingText)
            XCTAssertNil(service.errorMessage)
        }
    }

    func testCachedOCRCanDismissItsOwnPresentation() async throws {
        let processor = SuspendedClipboardOCRProcessor()
        try await withFixture(processor: processor) { fixture in
            let id = try await fixture.recordImage()
            try await fixture.worker.storeOCR(id: id, text: "cached text")
            let service = fixture.service
            service.preparePresentation(); await service.waitForPresentation()
            var results: [String] = []
            service.onRecognizeText = { results.append($0) }
            service.onDismiss = { service.didDismiss() }
            await service.recognizeTextSelected()
            let requests = await processor.requests
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(results, ["cached text"])
            XCTAssertFalse(service.recognizingText)
            await service.recognizeTextSelected()
            XCTAssertEqual(results.count, 1, "A dismissed window cannot start another manual recognition.")
        }
    }

    private func eventually(_ message: String = "The expected asynchronous state was not reached.",
                            file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message, file: file, line: line)
        throw ClipboardRegressionError.timeout
    }

    private func withFixture(processor: any ClipboardContentProcessing = ClipboardContentProcessor(),
                             searchDelay: Duration = .seconds(30),
                             body: (ClipboardRegressionFixture) async throws -> Void) async throws {
        let fixture = ClipboardRegressionFixture(processor: processor, searchDelay: searchDelay)
        do { try await body(fixture) }
        catch { await fixture.close(); throw error }
        await fixture.close()
    }
}

private enum ClipboardRegressionError: Error { case timeout }

@MainActor
private final class ClipboardRegressionFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let board: NSPasteboard
    let worker: ClipboardHistoryWorker
    let service: ClipboardHistoryService
    let processor: any ClipboardContentProcessing
    let policy = ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: [])
    init(processor: any ClipboardContentProcessing, searchDelay: Duration) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        self.directory = directory; self.suite = suite
        defaults = UserDefaults(suiteName: suite)!
        board = NSPasteboard.withUniqueName()
        worker = ClipboardHistoryWorker(directory: directory)
        self.processor = processor
        service = ClipboardHistoryService(defaults: defaults, pasteboard: board, worker: worker,
                                          processor: processor, searchDelay: searchDelay)
    }
    func record(_ text: String) async throws -> UInt64 {
        let result = try await worker.record(ClipboardInput(
            representations: [ClipboardRepresentation(format: "text/plain", bytes: Data(text.utf8))],
            sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now), policy: policy)
        return try XCTUnwrap(result)
    }
    func recordImage() async throws -> UInt64 {
        let result = try await worker.record(ClipboardInput(
            representations: [ClipboardRepresentation(format: "image/png", bytes: clipboardTestPNG)],
            sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now), policy: policy)
        return try XCTUnwrap(result)
    }
    func close() async {
        if let suspended = processor as? SuspendedClipboardProcessor { await suspended.release() }
        if let suspended = processor as? SuspendedClipboardOCRProcessor { await suspended.releaseAll() }
        service.onDismiss = nil
        service.onRecognizeText = nil
        await service.shutdown()
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Deliberately ignores cancellation, like an image encoder or an already-started database write.
private actor SuspendedClipboardProcessor: ClipboardContentProcessing {
    private let real = ClipboardContentProcessor()
    private var suspendNext = true
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var normalizationStarted = false
    func normalize(_ raw: [ClipboardRawItem], maximumBytes: UInt64) async throws -> [ClipboardItem] {
        if suspendNext {
            suspendNext = false; normalizationStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await real.normalize(raw, maximumBytes: maximumBytes)
    }
    func release() {
        suspendNext = false
        continuation?.resume(); continuation = nil
    }
    func preview(_ items: [ClipboardItem], ocrText: String) async throws -> ClipboardPreview {
        try await real.preview(items, ocrText: ocrText)
    }
    func recognize(_ items: [ClipboardItem]) async throws -> String { try await real.recognize(items) }
}

/// Simulates native OCR that finishes after cancellation, with deterministic completion order.
private actor SuspendedClipboardOCRProcessor: ClipboardContentProcessing {
    private let real = ClipboardContentProcessor()
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var requests = 0
    private(set) var cancelledRequests: Set<Int> = []
    func normalize(_ raw: [ClipboardRawItem], maximumBytes: UInt64) async throws -> [ClipboardItem] {
        try await real.normalize(raw, maximumBytes: maximumBytes)
    }
    func preview(_ items: [ClipboardItem], ocrText: String) async throws -> ClipboardPreview {
        try await real.preview(items, ocrText: ocrText)
    }
    func recognize(_ items: [ClipboardItem]) async throws -> String {
        requests += 1; let request = requests
        defer { if Task.isCancelled { cancelledRequests.insert(request) } }
        return try await withCheckedThrowingContinuation { continuations[request] = $0 }
    }
    func release(_ request: Int, text: String = "recognized text", fail: Bool = false) {
        guard let continuation = continuations.removeValue(forKey: request) else { return }
        if fail { continuation.resume(throwing: OCRError.noText) }
        else { continuation.resume(returning: text) }
    }
    func releaseAll() { for request in Array(continuations.keys) { release(request) } }
}
