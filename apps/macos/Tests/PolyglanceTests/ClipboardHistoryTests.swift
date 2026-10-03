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

    func testPasteboardBridgeRetainsPlainAndRichText() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString(" hello\n你好 ", forType: .string)
        let html = Data("<b>hello</b>".utf8)
        item.setData(html, forType: .html)
        board.writeObjects([item])
        let raw = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 1024))
        let bundle = try await ClipboardContentProcessor().normalize(raw, maximumBytes: 1024)
        let representations = try XCTUnwrap(bundle.first).representations
        XCTAssertEqual(ClipboardHistoryService.text(in: representations), " hello\n你好 ")
        XCTAssertEqual(representations.first { $0.format == "text/html" }?.bytes, html)
    }

    func testFileAndMultiItemCopiesKeepTheirOrderAndFormats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("你好.txt")
        try Data("file contents".utf8).write(to: file)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL)
        let second = NSPasteboardItem(); second.setString("second", forType: .string)
        board.writeObjects([item, second])
        let raw = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 4096))
        let bundle = try await ClipboardContentProcessor().normalize(raw, maximumBytes: 4096)
        XCTAssertEqual(bundle.count, 2)
        XCTAssertEqual(bundle[0].representations[0].format, "text/uri-list")
        let replayed = try ClipboardHistoryService.replayObjects(bundle)
        board.clearContents(); board.writeObjects(replayed)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .fileURL), file.absoluteString)
        XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "second")
        try FileManager.default.removeItem(at: file)
        XCTAssertThrowsError(try ClipboardHistoryService.replayObjects(bundle))
    }

    func testImageBridgeConvertsNativeTiffToPortablePNG() async throws {
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
        let raw = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 4096))
        let bundle = try await ClipboardContentProcessor().normalize(raw, maximumBytes: 4096)
        let representations = try XCTUnwrap(bundle.first).representations
        let png = try XCTUnwrap(representations.first { $0.format == "image/png" }?.bytes)
        XCTAssertNotNil(NSImage(data: png))
        board.clearContents()
        board.setData(png, forType: .png)
        let rawReplay = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 4096))
        let replayBundle = try await ClipboardContentProcessor().normalize(rawReplay, maximumBytes: 4096)
        let replayed = try XCTUnwrap(replayBundle.first).representations
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
        XCTAssertThrowsError(try ClipboardHistoryService.readRawItems(from: board, maximumBytes: 3))
    }

    func testWorkerPersistsThroughGeneratedBindingsAndUsesPrivateDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = ClipboardHistoryWorker(directory: directory)
        try await worker.configure(clipboardDefaultLimits())
        let input = ClipboardInput(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data("test".utf8))],
                                   sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        let saved = try await worker.record(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
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
    func testOldPreferencesRetainOptInAndNewOCRSettingDefaultsOff() throws {
        let old = Data(#"{"enabled":true,"maximumItems":1000,"maximumMegabytes":512,"retentionDays":60,"ignoredApplications":["private.app"],"ignoredTypes":[]}"#.utf8)
        let preferences = try JSONDecoder().decode(ClipboardHistoryPreferences.self, from: old)
        XCTAssertTrue(preferences.enabled)
        XCTAssertFalse(preferences.ocrSearchEnabled)
        XCTAssertEqual(preferences.maximumItems, 1000)
        XCTAssertEqual(preferences.ignoredApplications, ["private.app"])
        XCTAssertEqual(try JSONDecoder().decode(ClipboardHistoryPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testPlainTextReplayCombinesOnlyTextAndDropsRichFormatting() throws {
        let items = [ClipboardItem(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data("first".utf8)), ClipboardRepresentation(format: "text/html", bytes: Data("<b>first</b>".utf8))]),
                     ClipboardItem(representations: [ClipboardRepresentation(format: "text/plain", bytes: Data("second".utf8))])]
        let replayed = try ClipboardHistoryService.replayObjects(items, plainTextOnly: true)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed[0].string(forType: .string), "first\nsecond")
        XCTAssertFalse(replayed[0].types.contains(.html))
        let image = ClipboardItem(representations: [ClipboardRepresentation(format: "image/png", bytes: Data())])
        XCTAssertThrowsError(try ClipboardHistoryService.replayObjects([image], plainTextOnly: true))
    }

    func testWorkerBackupRestoreIncludesAnnotationsAndOCRIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = ClipboardHistoryWorker(directory: directory)
        try await worker.configure(clipboardDefaultLimits())
        let input = ClipboardBundleInput(items: [ClipboardItem(representations: [ClipboardRepresentation(format: "image/png", bytes: Data([137,80,78,71,13,10,26,10,1]))])], sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        let saved = try await worker.recordBundle(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
        let id = try XCTUnwrap(saved)
        try await worker.setAnnotation(id: id, title: "截图", tags: ["项目"])
        try await worker.storeOCR(id: id, text: "OCR 内容")
        let path = directory.appendingPathComponent("backup.polyclipboard").path
        try await worker.exportBackup(path: path)
        try await worker.clear(includePinned: true)
        let result = try await worker.importBackup(path: path, mode: .replace)
        XCTAssertEqual(result.items, 1)
        let rows = try await worker.list(filter: ClipboardFilter(query: "OCR", kind: .image, source: "test.app", tag: "项目", pinnedOnly: false), offset: 0)
        let entry = try XCTUnwrap(rows.first)
        XCTAssertEqual(entry.title, "截图")
        let restored = try await worker.annotation(id: entry.id)
        XCTAssertEqual(restored.ocrText, "OCR 内容")
    }

    func testBackgroundOCRRecognizesTextAndBuildsSearchIndex() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 600, height: 160))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        ("CLIPBOARD SEARCH" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let raw = ClipboardRawItem(representations: [.init(format: "image/tiff", bytes: try XCTUnwrap(image.tiffRepresentation))])
        let processor = ClipboardContentProcessor()
        let bundle = try await processor.normalize([raw], maximumBytes: 1024 * 1024)
        let text = try await processor.recognize(bundle)
        XCTAssertTrue(text.uppercased().contains("CLIPBOARD"))
        XCTAssertTrue(text.uppercased().contains("SEARCH"))
        let preview = try await processor.preview(bundle, ocrText: text)
        XCTAssertLessThanOrEqual(try XCTUnwrap(preview.image).width, 512)
    }

    func testOversizedImageDimensionsAreRejectedBeforeDecoding() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4001, height: 4000, bitsPerComponent: 8, bytesPerRow: 4001 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        do {
            _ = try await ClipboardContentProcessor().normalize([ClipboardRawItem(representations: [.init(format: "image/png", bytes: data)])], maximumBytes: 16 * 1024 * 1024)
            XCTFail("Image dimensions should be rejected")
        } catch ClipboardFailure.TooLarge {} catch { XCTFail("Unexpected error: \(error)") }
    }

}
