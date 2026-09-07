import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class PinArchiveTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        super.tearDown()
    }

    private func makeSolidImage(width: Int = 40, height: Int = 30) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    func testNewItemsAreReturnedInReverseChronologicalOrder() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img1 = makeSolidImage(width: 10, height: 10)
        let img2 = makeSolidImage(width: 20, height: 20)

        let item1 = try XCTUnwrap(store.append(image: img1, source: .screenshot))
        // Ensure timestamp order
        Thread.sleep(forTimeInterval: 0.05)
        let item2 = try XCTUnwrap(store.append(image: img2, source: .clipboard))

        let items = store.list()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, item2.id)
        XCTAssertEqual(items[0].source, .clipboard)
        XCTAssertEqual(items[1].id, item1.id)
        XCTAssertEqual(items[1].source, .screenshot)
    }

    func testAppendRecoversCorruptIndexBeforeWritingNewImage() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory)
        _ = try XCTUnwrap(store.append(image: makeSolidImage(), source: .screenshot))
        try Data("broken".utf8).write(to: temporaryDirectory.appendingPathComponent("index.json"))
        let added = try XCTUnwrap(store.append(image: makeSolidImage(), source: .clipboard))
        let items = store.list()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
        XCTAssertEqual(items.filter { $0.imageFileName == added.imageFileName }.count, 1)
    }

    func testClearFailureSurvivesViewReload() async throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, removeFile: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        _ = try XCTUnwrap(store.append(image: makeSolidImage(), source: .screenshot))
        let model = PinHistoryViewModel(archiveStore: store, onPinItem: { _ in })
        await model.reload()
        await model.clearAll()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 1)
    }

    func testRecordThenClearUsesOrderedBackgroundQueue() async throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory)
        store.record(image: makeSolidImage(), source: .screenshot)
        let result = await store.perform { $0.deleteAll() }
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(store.list().isEmpty)
        let ranOnMain = await store.perform { _ in Thread.isMainThread }
        XCTAssertFalse(ranOnMain)
    }

    func testIndexedTruncatedPNGIsExcludedAndClearRemovesQuarantine() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory)
        let item = try XCTUnwrap(store.append(image: makeSolidImage(), source: .screenshot))
        let url = store.imageURL(for: item)
        let png = try Data(contentsOf: url)
        try png.prefix(33).write(to: url)
        XCTAssertTrue(store.list().isEmpty)
        _ = store.deleteAll()
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .contains { $0.hasPrefix("pin_") })
    }

    func testEvictionOnCountLimit() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 2, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage()

        let item1 = try XCTUnwrap(store.append(image: img, source: .screenshot))
        Thread.sleep(forTimeInterval: 0.02)
        let item2 = try XCTUnwrap(store.append(image: img, source: .longScreenshot))
        Thread.sleep(forTimeInterval: 0.02)
        let item3 = try XCTUnwrap(store.append(image: img, source: .ocr))

        let items = store.list()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.id), [item3.id, item2.id])

        let file1URL = temporaryDirectory.appendingPathComponent(item1.imageFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1URL.path))
    }

    func testEvictionOnByteLimit() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 900)
        let img = makeSolidImage(width: 10, height: 10)

        let item1 = try XCTUnwrap(store.append(image: img, source: .screenshot))
        Thread.sleep(forTimeInterval: 0.02)
        let item2 = try XCTUnwrap(store.append(image: img, source: .translation))

        let items = store.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, item2.id)
        let file1URL = temporaryDirectory.appendingPathComponent(item1.imageFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1URL.path))
    }

    func testPersistenceAcrossStoreInstances() throws {
        let store1 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage(width: 32, height: 24)
        let item = try XCTUnwrap(store1.append(image: img, source: .screenshot))

        let store2 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let items = store2.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, item.id)
        XCTAssertEqual(items[0].pixelWidth, item.pixelWidth)
        XCTAssertEqual(items[0].pixelHeight, item.pixelHeight)

        let loadedImage = try XCTUnwrap(store2.loadImage(id: item.id))
        XCTAssertGreaterThan(loadedImage.size.width, 0)
    }

    func testCorruptedOrMissingImageSkippedAndRepairsIndex() throws {
        let store1 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage()
        let item1 = try XCTUnwrap(store1.append(image: img, source: .screenshot))
        Thread.sleep(forTimeInterval: 0.02)
        let item2 = try XCTUnwrap(store1.append(image: img, source: .clipboard))

        // Delete image 1 file to simulate missing file
        let file1 = temporaryDirectory.appendingPathComponent(item1.imageFileName)
        try FileManager.default.removeItem(at: file1)

        let store2 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let items = store2.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, item2.id)

        // Verify index was repaired on disk
        let store3 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        XCTAssertEqual(store3.list().count, 1)
    }

    func testCorruptedIndexRebuildsFromExistingImagesAndBacksUpCorruptIndex() throws {
        let store1 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img1 = makeSolidImage(width: 50, height: 40)
        let img2 = makeSolidImage(width: 60, height: 45)
        let item1 = try XCTUnwrap(store1.append(image: img1, source: .screenshot))
        Thread.sleep(forTimeInterval: 0.02)
        let item2 = try XCTUnwrap(store1.append(image: img2, source: .clipboard))

        let indexFile = temporaryDirectory.appendingPathComponent("index.json")
        try "Not a valid JSON content".write(to: indexFile, atomically: true, encoding: .utf8)

        let store2 = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let items = store2.list()
        // Must rebuild 2 items from the 2 existing PNGs instead of treating archive as empty
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains(where: { $0.id == item1.id }))
        XCTAssertTrue(items.contains(where: { $0.id == item2.id }))

        // Verify corrupted index was backed up
        let files = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        let backupFiles = files.filter { $0.hasPrefix("index.corrupt.") }
        XCTAssertFalse(backupFiles.isEmpty)
    }

    func testCorruptedAndNonImagePngFilesAreSkippedAndQuarantined() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let validImg = makeSolidImage(width: 30, height: 30)
        let validItem = try XCTUnwrap(store.append(image: validImg, source: .screenshot))

        // Create a non-image file pretending to be pin_fake.png
        let fakeFile = temporaryDirectory.appendingPathComponent("pin_fake_corrupt.png")
        try "This is not a png file at all".write(to: fakeFile, atomically: true, encoding: .utf8)

        let items = store.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, validItem.id)

        // The corrupt file should be quarantined (.corrupted) so future scans skip it
        let files = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
        XCTAssertFalse(files.contains("pin_fake_corrupt.png"))
        XCTAssertTrue(files.contains("pin_fake_corrupt.png.corrupted"))
    }

    func testThumbnailDecodingDoesNotExceedMaxDimension() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let largeImage = makeSolidImage(width: 1200, height: 800)
        let item = try XCTUnwrap(store.append(image: largeImage, source: .screenshot))

        let thumbnail = try XCTUnwrap(store.loadThumbnail(id: item.id, maxPixelDimension: 480))
        let rep = try XCTUnwrap(thumbnail.representations.first)
        XCTAssertLessThanOrEqual(rep.pixelsWide, 480)
        XCTAssertLessThanOrEqual(rep.pixelsHigh, 480)

        // Extreme aspect ratio
        let tallImage = makeSolidImage(width: 100, height: 2000)
        let tallItem = try XCTUnwrap(store.append(image: tallImage, source: .longScreenshot))
        let tallThumb = try XCTUnwrap(store.loadThumbnail(id: tallItem.id, maxPixelDimension: 480))
        let tallRep = try XCTUnwrap(tallThumb.representations.first)
        XCTAssertLessThanOrEqual(tallRep.pixelsHigh, 480)
    }

    func testDeleteSingleItem() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage()
        let item1 = try XCTUnwrap(store.append(image: img, source: .screenshot))
        let item2 = try XCTUnwrap(store.append(image: img, source: .clipboard))

        store.delete(id: item1.id)

        let items = store.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, item2.id)

        let file1URL = temporaryDirectory.appendingPathComponent(item1.imageFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1URL.path))
    }

    func testDeleteAll() throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage()
        let item1 = try XCTUnwrap(store.append(image: img, source: .screenshot))
        let item2 = try XCTUnwrap(store.append(image: img, source: .clipboard))

        store.deleteAll()

        XCTAssertEqual(store.list().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent(item1.imageFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent(item2.imageFileName).path))
    }

    func testPinHistoryViewModelOperations() async throws {
        let store = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let img = makeSolidImage()
        let item1 = try XCTUnwrap(store.append(image: img, source: .screenshot))
        try await Task.sleep(for: .milliseconds(20))
        let item2 = try XCTUnwrap(store.append(image: img, source: .clipboard))

        var pinnedImages: [NSImage] = []
        let viewModel = PinHistoryViewModel(archiveStore: store) { image in
            pinnedImages.append(image)
        }

        await viewModel.reload()
        XCTAssertEqual(viewModel.items.count, 2)
        _ = viewModel.thumbnail(for: item2)
        for _ in 0..<50 {
            if viewModel.thumbnail(for: item2) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(viewModel.thumbnail(for: item2))

        await viewModel.pinSelected()
        XCTAssertEqual(pinnedImages.count, 1)

        viewModel.select(item1.id)
        await viewModel.deleteSelected()
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.selectedItemID, item2.id)

        await viewModel.clearAll()
        XCTAssertEqual(viewModel.items.count, 0)
        XCTAssertNil(viewModel.selectedItemID)
    }

    func testPinWindowManagerArchivesVariousSourcesAndAvoidsDuplicatesOnHistoryPin() async throws {
        _ = NSApplication.shared
        let archiveStore = PinArchiveStore(directoryURL: temporaryDirectory, maximumCount: 10, maximumTotalBytes: 10 * 1024 * 1024)
        let manager = PinWindowManager(
            historyStore: PinHistoryStore(),
            archiveStore: archiveStore
        )

        let img = makeSolidImage(width: 40, height: 40)
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let frame = CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 40, height: 40)

        // 1. Screenshot source
        manager.pin(img, sourceFrame: frame, source: .screenshot, recordInArchive: true)
        await archiveStore.perform { _ in () }
        XCTAssertEqual(archiveStore.list().count, 1)
        XCTAssertEqual(archiveStore.list().first?.source, .screenshot)

        // 2. Long screenshot source
        manager.pin(img, sourceFrame: frame, source: .longScreenshot, recordInArchive: true)
        await archiveStore.perform { _ in () }
        XCTAssertEqual(archiveStore.list().count, 2)
        XCTAssertEqual(archiveStore.list().first?.source, .longScreenshot)

        // 3. Translation source
        manager.pinTranslation(
            image: img,
            sourceText: "Hello",
            translatedText: "你好",
            sourceFrame: frame,
            recordInArchive: true
        )
        await archiveStore.perform { _ in () }
        XCTAssertEqual(archiveStore.list().count, 3)
        XCTAssertEqual(archiveStore.list().first?.source, .translation)

        // 4. Pinning from history with recordInArchive = false does NOT increase archive count
        manager.pin(img, sourceFrame: nil, source: .legacy, recordInArchive: false)
        await archiveStore.perform { _ in () }
        XCTAssertEqual(archiveStore.list().count, 3)

        // 5. Closing pins and restoring does NOT add duplicate archive entries
        manager.closeAllPins()
        XCTAssertTrue(manager.canRestoreMostRecentPin)
        manager.restoreMostRecentPin()
        await archiveStore.perform { _ in () }
        XCTAssertEqual(archiveStore.list().count, 3)

        manager.destroyAllPins()
    }

    func testSaveCompletedScreenshotsConfigurationDefaultAndBehavior() throws {
        let store = AppConfigurationStore(defaults: UserDefaults(suiteName: "PinArchiveTests-\(UUID().uuidString)")!)
        let config = try store.load()
        XCTAssertFalse(config.saveCompletedScreenshotsToHistory)

        var modified = config
        modified.saveCompletedScreenshotsToHistory = true
        try store.save(modified)

        let reloaded = try store.load()
        XCTAssertTrue(reloaded.saveCompletedScreenshotsToHistory)
    }
}
