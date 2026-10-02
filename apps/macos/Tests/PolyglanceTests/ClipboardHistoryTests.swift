import AppKit
import XCTest
import TranslatorCore
@testable import Polyglance

@MainActor
final class ClipboardHistoryTests: XCTestCase {
    func testNewInstallDoesNotEnableRecording() {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let service = ClipboardHistoryService(defaults: defaults, pasteboard: board)
        XCTAssertFalse(service.preferences.enabled)
        XCTAssertFalse(service.paused)
        service.start()
        service.poll()
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testPasteboardBridgeRetainsPlainAndRichText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(" hello\n你好 ", forType: .string)
        let html = Data("<b>hello</b>".utf8)
        item.setData(html, forType: .html)
        board.writeObjects([item])
        let representations = try XCTUnwrap(ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 1024))
        XCTAssertEqual(ClipboardHistoryService.text(in: representations), " hello\n你好 ")
        XCTAssertEqual(representations.first { $0.format == "text/html" }?.bytes, html)
    }

    func testFilesAndMultiItemCopiesAreNotFlattenedIntoText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("file:///tmp/example.txt", forType: .fileURL)
        item.setString("example.txt", forType: .string)
        board.writeObjects([item])
        XCTAssertNil(try ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 1024))
        board.clearContents()
        let a = NSPasteboardItem(); a.setString("a", forType: .string)
        let b = NSPasteboardItem(); b.setString("b", forType: .string)
        board.writeObjects([a, b])
        XCTAssertNil(try ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 1024))
    }

    func testImageBridgeConvertsNativeTiffToPortablePNG() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(context.makeImage())
        let tiff = try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setData(tiff, forType: .tiff)
        board.writeObjects([item])
        let representations = try XCTUnwrap(ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 4096))
        let png = try XCTUnwrap(representations.first { $0.format == "image/png" }?.bytes)
        XCTAssertNotNil(NSImage(data: png))
        board.clearContents()
        board.setData(png, forType: .png)
        let replayed = try XCTUnwrap(ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 4096))
        XCTAssertEqual(replayed.first { $0.format == "image/png" }?.bytes, png)
    }

    func testTemporaryClipboardCopiesHaveNestedSuppression() {
        let generation = ClipboardCaptureSuppression.generation
        ClipboardCaptureSuppression.begin()
        ClipboardCaptureSuppression.begin()
        XCTAssertEqual(ClipboardCaptureSuppression.depth, 2)
        ClipboardCaptureSuppression.end()
        XCTAssertEqual(ClipboardCaptureSuppression.depth, 1)
        ClipboardCaptureSuppression.end()
        XCTAssertEqual(ClipboardCaptureSuppression.depth, 0)
        XCTAssertEqual(ClipboardCaptureSuppression.generation, generation + 2)
    }

    func testBridgeRejectsOversizedNativeRepresentations() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("abcd", forType: .string)
        XCTAssertThrowsError(try ClipboardHistoryService.readRepresentations(from: board, maximumBytes: 3))
    }

    func testWorkerPersistsThroughGeneratedBindingsAndUsesPrivateDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = ClipboardHistoryWorker(directory: directory)
        try await worker.configure(clipboardDefaultLimits())
        let input = ClipboardInput(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data("test".utf8))],
                                   sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        let saved = try await worker.record(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: []))
        let id = try XCTUnwrap(saved)
        let reopened = ClipboardHistoryWorker(directory: directory)
        let entries = try await reopened.list(query: "test", pinnedOnly: false, offset: 0)
        XCTAssertEqual(entries.map(\.id), [id])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let payload = try await reopened.payload(id: id)
        XCTAssertEqual(ClipboardHistoryService.text(in: payload), "test")
    }

    func testPanelSupportsKeyboardFocusAndDismissal() {
        _ = NSApplication.shared
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let panel = ClipboardHistoryPanel(service: ClipboardHistoryService(defaults: defaults))
        var dismissed = false
        panel.onDismissed = { dismissed = true }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        panel.cancelOperation(nil)
        XCTAssertTrue(dismissed)
    }
}
