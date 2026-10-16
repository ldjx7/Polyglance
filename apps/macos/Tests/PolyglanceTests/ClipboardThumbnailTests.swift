import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TranslatorCore
@testable import Polyglance

@MainActor
final class ClipboardThumbnailTests: XCTestCase {
    func testScreenshotCopiesReachHistoryThumbnailsThroughTheRealPasteboardBridge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let worker = ClipboardHistoryWorker(directory: directory)
        try await worker.configure(clipboardDefaultLimits())
        let processor = ClipboardContentProcessor()
        let service = ClipboardHistoryService(defaults: defaults, pasteboard: board, worker: worker, processor: processor)
        let source = try XCTUnwrap(NSImage(data: imageData(.png)))
        for nativeTIFF in [false, true] {
            if nativeTIFF {
                board.clearContents()
                board.setData(try XCTUnwrap(source.tiffRepresentation), forType: .tiff)
            } else {
                // This is the same writer used by screenshot and long-screenshot copy.
                try ImagePasteboard.write(source, to: board)
            }
            let raw = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 4_000_000))
            let items = try await processor.normalize(raw, maximumBytes: 4_000_000)
            _ = try await worker.recordBundle(
                ClipboardBundleInput(items: items, sourceApplication: "test.screenshot", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now),
                policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
            let entries = try await worker.list(query: "", pinnedOnly: false, offset: 0)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry.kind, .image)
            let thumbnail = await service.thumbnail(for: entry)
            XCTAssertEqual(thumbnail?.size, NSSize(width: 96, height: 48))
            let restored = try await worker.bundle(id: entry.id)
            let replayed = try ClipboardHistoryService.replayObjects(restored)
            let original = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(replayed[0].data(forType: .png))))
            XCTAssertEqual(original.pixelsWide, 600)
            XCTAssertEqual(original.pixelsHigh, 300)
        }
    }

    func testBitmapThumbnailIsBoundedAndPreservesAspectRatio() async throws {
        let items = [ClipboardItem(representations: [.init(format: "image/png", bytes: try imageData(.png))])]
        let processor = ClipboardContentProcessor()
        let result = try await processor.thumbnail(items)
        let image = try XCTUnwrap(result?.image)
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 48)
        let preview = try await processor.preview(items, ocrText: "cached OCR")
        XCTAssertEqual(preview.image?.width, 512)
        XCTAssertEqual(preview.text, "cached OCR")
        XCTAssertTrue(preview.hasImages)
        XCTAssertFalse(preview.hasFiles)
    }

    func testFinderImageFilesShowThumbnailsAndReplayAsFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let processor = ClipboardContentProcessor()
        for (type, name) in [(NSBitmapImageRep.FileType.png, "图片.png"), (.jpeg, "photo.jpg"), (.tiff, "scan.tiff")] {
            let file = directory.appendingPathComponent(name)
            try imageData(type).write(to: file)
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            // Finder may also supply an icon bitmap; the actual image file wins.
            item.setData(clipboardTestPNG, forType: .png)
            board.clearContents()
            board.writeObjects([item])
            let raw = try XCTUnwrap(ClipboardHistoryService.readRawItems(from: board, maximumBytes: 4096))
            let items = try await processor.normalize(raw, maximumBytes: 4096)
            XCTAssertEqual(items[0].representations.map(\.format), ["text/uri-list"])
            let thumbnail = try await processor.thumbnail(items)
            XCTAssertEqual(thumbnail?.image.width, 96)
            XCTAssertEqual(thumbnail?.image.height, 48)
            let preview = try await processor.preview(items, ocrText: "")
            XCTAssertEqual(preview.image?.width, 512)
            XCTAssertEqual(preview.text, file.path)
            XCTAssertTrue(preview.hasFiles)
            XCTAssertFalse(preview.hasImages)
            let replayed = try ClipboardHistoryService.replayObjects(items)
            XCTAssertEqual(replayed[0].string(forType: .fileURL), file.absoluteString)
            XCTAssertFalse(replayed[0].types.contains(.png))
        }
    }

    func testFileThumbnailAppliesOrientation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try imageData(.jpeg) as CFData, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = directory.appendingPathComponent("rotated.jpg")
        try (data as Data).write(to: file)
        let thumbnail = try await ClipboardContentProcessor().thumbnail([fileItem(file)])
        XCTAssertEqual(thumbnail?.image.width, 48)
        XCTAssertEqual(thumbnail?.image.height, 96)
    }

    func testUnavailableAndNonImageFilesKeepTextAndAllowLaterImageInBundle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: text)
        let files = [fileItem(directory.appendingPathComponent("missing.png")), fileItem(text), fileItem(directory),
                     fileItem(URL(string: "https://example.com/image.png")!)]
        let processor = ClipboardContentProcessor()
        let preview = try await processor.preview(files, ocrText: "")
        XCTAssertNil(preview.image)
        XCTAssertTrue(preview.text.contains("note.txt"))
        XCTAssertTrue(preview.hasFiles)
        let image = directory.appendingPathComponent("valid.png")
        try imageData(.png).write(to: image)
        let thumbnail = try await processor.thumbnail(files + [fileItem(image)])
        XCTAssertNotNil(thumbnail)
    }

    func testStoredEntryThumbnailDoesNotChangeSelectionOrPasteboardAndHandlesDeletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("untouched", forType: .string)
        let worker = ClipboardHistoryWorker(directory: directory.appendingPathComponent("history"))
        try await worker.configure(clipboardDefaultLimits())
        let file = directory.appendingPathComponent("image.png")
        try imageData(.png).write(to: file)
        let input = ClipboardBundleInput(items: [fileItem(file)], sourceApplication: "test.app", observedTypes: [], copiedAtMs: ClipboardHistoryWorker.now)
        _ = try await worker.recordBundle(input, policy: ClipboardPolicy(enabled: true, ignoredApplications: [], ignoredTypes: [], ignoredPatterns: []))
        let entries = try await worker.list(query: "", pinnedOnly: false, offset: 0)
        let entry = try XCTUnwrap(entries.first)
        let service = ClipboardHistoryService(defaults: defaults, pasteboard: board, worker: worker)
        let image = await service.thumbnail(for: entry)
        XCTAssertEqual(image?.size, NSSize(width: 96, height: 48))
        XCTAssertNil(service.selectedID)
        XCTAssertNil(service.previewImage)
        XCTAssertEqual(board.string(forType: .string), "untouched")
        try FileManager.default.removeItem(at: file)
        let missing = await service.thumbnail(for: entry)
        XCTAssertNil(missing)
        XCTAssertNil(service.errorMessage)
    }

    private func fileItem(_ url: URL) -> ClipboardItem {
        ClipboardItem(representations: [.init(format: "text/uri-list", bytes: Data(url.absoluteString.utf8))])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageData(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 2400,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: XCTUnwrap(context.makeImage())).representation(using: type, properties: [:]))
    }
}
