import AppKit
import XCTest
import TranslatorCore
@testable import Polyglance

@MainActor
final class ClipboardInteractionTests: XCTestCase {
    func testIgnoreNextConsumesOnlyOneNonemptyExternalSample() {
        var state = ClipboardCaptureLifecycle()
        state.armIgnore()
        XCTAssertEqual(state.observe(sequence: 1, empty: true), .clear(nil))
        XCTAssertTrue(state.ignoringNext)
        state.invalidateInternalSample()
        XCTAssertTrue(state.ignoringNext)
        XCTAssertEqual(state.observe(sequence: 2, empty: false), .skip)
        XCTAssertFalse(state.ignoringNext)
        XCTAssertEqual(state.observe(sequence: 3, empty: false), .capture)
        XCTAssertEqual(state.observe(sequence: 4, empty: true), .clear(3))
        XCTAssertEqual(state.observe(sequence: 5, empty: true), .clear(nil))
    }
    func testInternalReplayInvalidatesTheClearCandidate() {
        var state = ClipboardCaptureLifecycle()
        XCTAssertEqual(state.observe(sequence: 1, empty: false), .capture)
        state.invalidateInternalSample()
        XCTAssertEqual(state.observe(sequence: 2, empty: true), .clear(nil))
        state.armIgnore(); state.cancelIgnore()
        XCTAssertEqual(state.observe(sequence: 3, empty: false), .capture)
    }
    func testHexColorsRequireCompleteValidColorText() throws {
        XCTAssertEqual(try XCTUnwrap(ClipboardHexColor(text: " #f00 \n")).red, 1)
        XCTAssertEqual(try XCTUnwrap(ClipboardHexColor(text: "#ff000080")).alpha, 128.0 / 255.0)
        XCTAssertEqual(try XCTUnwrap(ClipboardHexColor(text: "#abcd")).alpha, 221.0 / 255.0)
        XCTAssertNil(ClipboardHexColor(text: "see #ff0000 here"))
        XCTAssertNil(ClipboardHexColor(text: "#gggggg"))
        XCTAssertNil(ClipboardHexColor(text: "#12345"))
    }
    func testNativeEmptyAndOriginalSourceMetadata() {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        XCTAssertTrue(ClipboardHistoryService.isEmpty(board))
        let item = NSPasteboardItem()
        item.setString("payload", forType: .string)
        item.setString("com.apple.Terminal", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        board.writeObjects([item])
        XCTAssertFalse(ClipboardHistoryService.isEmpty(board))
        XCTAssertEqual(ClipboardHistoryService.sourceIdentifier(from: board), "com.apple.Terminal")
        board.clearContents(); board.setString("", forType: .string)
        XCTAssertTrue(ClipboardHistoryService.isEmpty(board))
        board.clearContents(); board.setString(" ", forType: .string)
        XCTAssertFalse(ClipboardHistoryService.isEmpty(board))
    }
    func testOldPreferencesKeepAutomaticPasteCycleAndNotificationsOff() throws {
        let data = Data(#"{"enabled":true,"maximumItems":500,"maximumMegabytes":256,"retentionDays":30}"#.utf8)
        let p = try JSONDecoder().decode(ClipboardHistoryPreferences.self, from: data)
        XCTAssertTrue(p.enabled); XCTAssertTrue(p.autoPreview); XCTAssertTrue(p.purgeClearedContent)
        XCTAssertFalse(p.selectionPastesAutomatically); XCTAssertFalse(p.cycleSelectionEnabled)
        XCTAssertFalse(p.notifyCopies); XCTAssertFalse(p.notifySelections)
        XCTAssertTrue(p.ignoredPatterns.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistoryPreferences.self, from: JSONEncoder().encode(p)), p)
    }
    func testShortcutsReadFullContentCopyOriginalFormatsAndDeleteThroughTheService() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let worker = ClipboardHistoryWorker(directory: directory)
        let service = ClipboardHistoryService(defaults: defaults, pasteboard: board, worker: worker)
        let text = String(repeating: "完整文字\n", count: 5000)
        let input = ClipboardInput(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data(text.utf8)), ClipboardRepresentation(format: "text/html", bytes: Data("<b>rich</b>".utf8))], sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        let stored = try await worker.record(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
        let id = try XCTUnwrap(stored)
        let rows = try await service.shortcutSearch(query: "完整文字")
        XCTAssertEqual(rows.map(\.id), [id])
        let full = try await service.shortcutText(id: id); XCTAssertEqual(full, text)
        try await service.shortcutCopy(id: id)
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertEqual(board.data(forType: .html), Data("<b>rich</b>".utf8))
        try await service.shortcutDelete(id: id)
        let deleted = try await service.shortcutEntries(ids: [id]); XCTAssertTrue(deleted.isEmpty)
        await service.shutdown()
    }
    func testShortcutsDoNotEnableHistoryAndClearingPreservesPinsByDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = UUID().uuidString; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let worker = ClipboardHistoryWorker(directory: directory)
        let service = ClipboardHistoryService(defaults: defaults, worker: worker)
        XCTAssertThrowsError(try service.shortcutPause(false))
        let input = ClipboardInput(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data("pinned".utf8))], sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        let stored = try await worker.record(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
        let id = try XCTUnwrap(stored); try await worker.pin(id: id, pinned: true)
        try await service.shortcutClear(includePinned: false)
        let remaining = try await service.shortcutEntries(ids: [id]); XCTAssertEqual(remaining.map(\.id), [id])
        XCTAssertFalse(service.preferences.enabled)
        await service.shutdown()
    }
}
