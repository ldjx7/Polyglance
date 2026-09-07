import AppKit
import Foundation
import ImageIO
import os

enum PinArchiveSource: String, Codable, CaseIterable, Sendable {
    case screenshot
    case longScreenshot
    case clipboard
    case ocr
    case translation
    case legacy

    var displayName: String {
        switch self {
        case .screenshot:
            return "截图"
        case .longScreenshot:
            return "长截图"
        case .clipboard:
            return "剪贴板"
        case .ocr:
            return "文字识别"
        case .translation:
            return "截屏翻译"
        case .legacy:
            return "历史导入"
        }
    }
}

enum PinArchiveOperationResult: Equatable, Sendable {
    case success
    case failed(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct PinArchiveDeleteAllResult: Equatable, Sendable {
    let deletedCount: Int
    let failedCount: Int
    let errorMessage: String?
}

struct PinArchiveItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let source: PinArchiveSource
    let imageFileName: String
}

private struct PinArchiveManifest: Codable {
    var version: Int = 1
    var items: [PinArchiveItem] = []
}

final class PinArchiveStore: @unchecked Sendable {
    static let writeFailedNotification = Notification.Name("PolyglancePinArchiveWriteFailed")
    static let defaultDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Polyglance", isDirectory: true)
            .appendingPathComponent("PinHistory", isDirectory: true)
    }()

    private static let logger = Logger(subsystem: "io.polyglance", category: "PinArchiveStore")

    let directoryURL: URL
    let maximumCount: Int
    let maximumTotalBytes: Int64
    private let lock = NSLock()
    private let deletionLock = NSLock()
    private var deletedIDs = Set<String>()
    private let indexURL: URL
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private let ioQueue = DispatchQueue(label: "io.polyglance.pin-archive", qos: .utility)
    private let removeFile: (URL) throws -> Void
    private var verifiedImages: [String: (size: UInt64, modified: Date, width: Int, height: Int)] = [:]

    /// Submit operations synchronously to preserve user action order; execution is off the main thread.
    func perform<T: Sendable>(_ operation: @escaping @Sendable (PinArchiveStore) -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: operation(self)) }
        }
    }

    @MainActor
    @discardableResult
    func record(image: NSImage, source: PinArchiveSource, id: String = UUID().uuidString) -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            reportWriteFailure()
            return id
        }
        ioQueue.async {
            let snapshot = NSImage(cgImage: cgImage, size: .zero)
            let result = self.append(image: snapshot, source: source, id: id)
            if result == nil { Task { @MainActor in self.reportWriteFailure() } }
        }
        return id
    }

    // Session metadata contains original text. It is atomically replaced without backups.
    // All mutations share the archive queue/lock so a late window update cannot resurrect a deletion.
    func loadSessions() -> [PinSessionRecord] {
        lock.lock(); defer { lock.unlock() }
        return sessionsLocked()
    }

    func wasDeleted(_ id: String) -> Bool {
        deletionLock.lock(); defer { deletionLock.unlock() }
        return deletedIDs.contains(id)
    }

    private func markDeleted(_ id: String) {
        deletionLock.lock(); defer { deletionLock.unlock() }
        deletedIDs.insert(id)
    }

    @discardableResult
    func saveSession(_ record: PinSessionRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard record.isValid, loadManifestLocked().items.contains(where: {
            $0.id == record.archiveID && isValidFileName($0.imageFileName)
                && FileManager.default.fileExists(atPath: imageURL(for: $0).path)
        }) else { return false }
        var records = sessionsLocked().filter { $0.id != record.id }
        records.append(record)
        let closed = records.indices.filter { records[$0].status == .closed }
        for index in closed.dropLast(20) { records[index].status = .archived }
        // A historical content needs only one metadata copy once its windows are no longer restorable.
        records = records.filter { entry in
            entry.status != .archived || !records.contains { $0.id != entry.id && $0.archiveID == entry.archiveID && $0.status != .archived }
        }
        return writeSessionsLocked(records)
    }

    private func sessionsLocked() -> [PinSessionRecord] {
        let records = rawSessionsLocked()
        let ids = Set(loadManifestLocked().items.filter {
            isValidFileName($0.imageFileName) && FileManager.default.fileExists(atPath: imageURL(for: $0).path)
        }.map(\.id))
        var seen = Set<String>()
        return records.filter { $0.isValid && ids.contains($0.archiveID) && seen.insert($0.id).inserted }
    }

    private func rawSessionsLocked() -> [PinSessionRecord] {
        guard let data = try? Data(contentsOf: directoryURL.appendingPathComponent("sessions.json")),
              data.count <= 40 * 1_048_576,
              let records = try? jsonDecoder.decode([PinSessionRecord].self, from: data) else { return [] }
        return records.filter(\.isValid)
    }

    func enqueueSession(_ record: PinSessionRecord) {
        ioQueue.async {
            // A missing archive can mean it was explicitly deleted while this update was queued.
            if !self.saveSession(record), self.loadImage(id: record.archiveID) != nil {
                Task { @MainActor in self.reportWriteFailure() }
            }
        }
    }

    @MainActor
    func updateRecordedImage(_ image: NSImage, id: String) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        ioQueue.async {
            if !self.replaceImage(NSImage(cgImage: cg, size: .zero), id: id), !self.wasDeleted(id) {
                Task { @MainActor in self.reportWriteFailure() }
            }
        }
    }

    @discardableResult
    func replaceImage(_ image: NSImage, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let items = loadManifestLocked().items
        guard let item = items.first(where: { $0.id == id }), isValidFileName(item.imageFileName),
              let (data, width, height) = encodePNG(image), width == item.pixelWidth, height == item.pixelHeight,
              Int64(data.count) + imageBytes(items.filter { $0.id != id }) + quarantineBytes() <= maximumTotalBytes,
              FileManager.default.fileExists(atPath: imageURL(for: item).path) else { return false }
        do { try data.write(to: imageURL(for: item), options: .atomic); return true }
        catch { return false }
    }

    private func writeSessionsLocked(_ records: [PinSessionRecord]) -> Bool {
        do {
            let url = directoryURL.appendingPathComponent("sessions.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try Data(contentsOf: url)
                guard existing.count <= 40 * 1_048_576,
                      (try? jsonDecoder.decode([PinSessionRecord].self, from: existing)) != nil else { return false }
            }
            var archivedIDs = Set<String>()
            let compact = records.reversed().filter { $0.status != .archived || archivedIDs.insert($0.archiveID).inserted }.reversed()
            let data = try jsonEncoder.encode(Array(compact))
            guard data.count <= 40 * 1_048_576 else { return false }
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    @MainActor
    private func reportWriteFailure() {
        NotificationCenter.default.post(name: Self.writeFailedNotification, object: nil)
    }

    init(
        directoryURL: URL = PinArchiveStore.defaultDirectory,
        maximumCount: Int = 30,
        maximumTotalBytes: Int64 = 512 * 1024 * 1024,
        removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.directoryURL = directoryURL
        self.maximumCount = max(0, maximumCount)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
        self.removeFile = removeFile
        self.indexURL = directoryURL.appendingPathComponent("index.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.jsonEncoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)) {
                return date
            }
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid archive date")
            }
            return date
        }
        self.jsonDecoder = decoder

        ensureDirectoryExists()
        cleanupTemporaryFiles()
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func cleanupTemporaryFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else { return }
        for file in files where file.hasSuffix(".tmp") || file.hasPrefix("tmp_") {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(file))
        }
    }

    func isValidFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.contains(".."),
              fileName.hasPrefix("pin_"),
              fileName.hasSuffix(".png") else {
            return false
        }
        let url = directoryURL.appendingPathComponent(fileName)
        return url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == directoryURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func list() -> [PinArchiveItem] {
        lock.lock()
        defer { lock.unlock() }

        var manifest = loadManifestLocked()
        let (repairedItems, changed) = validateAndPruneItemsLocked(manifest.items)
        if changed {
            manifest.items = repairedItems
            _ = saveManifestLocked(manifest)
        }
        if FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("sessions.json").path) {
            _ = writeSessionsLocked(sessionsLocked())
        }
        return repairedItems
    }

    func loadImage(id: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        let manifest = loadManifestLocked()
        guard let item = manifest.items.first(where: { $0.id == id }) else {
            return nil
        }
        guard isValidFileName(item.imageFileName) else {
            return nil
        }
        let imageURL = directoryURL.appendingPathComponent(item.imageFileName)
        guard let data = try? Data(contentsOf: imageURL) else {
            return nil
        }
        return NSImage(data: data)
    }

    func loadThumbnail(id: String, maxPixelDimension: Int = 480) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }

        let manifest = loadManifestLocked()
        guard let item = manifest.items.first(where: { $0.id == id }) else {
            return nil
        }
        return decodeThumbnail(fileName: item.imageFileName, maxPixelDimension: maxPixelDimension)
    }

    private func decodeThumbnail(fileName: String, maxPixelDimension: Int) -> NSImage? {
        guard isValidFileName(fileName) else { return nil }
        let imageURL = directoryURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension)
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgThumb)
        let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        image.addRepresentation(rep)
        return image
    }

    func imageURL(for item: PinArchiveItem) -> URL {
        directoryURL.appendingPathComponent(item.imageFileName)
    }

    @discardableResult
    func append(image: NSImage, source: PinArchiveSource, id: String = UUID().uuidString) -> PinArchiveItem? {
        lock.lock()
        defer { lock.unlock() }

        guard maximumCount > 0, maximumTotalBytes > 0 else {
            return nil
        }

        // Recover and import BEFORE creating the new PNG, so recovery cannot import it twice.
        var manifest = loadManifestLocked()
        manifest.items = validateAndPruneItemsLocked(manifest.items).0

        guard let (pngData, pixelWidth, pixelHeight) = encodePNG(image) else {
            Self.logger.error("Failed to encode pin image to PNG")
            return nil
        }

        guard Int64(pngData.count) <= maximumTotalBytes else {
            Self.logger.error("Pin image size exceeds maximum archive byte capacity")
            return nil
        }

        guard UUID(uuidString: id) != nil, !manifest.items.contains(where: { $0.id == id }) else { return nil }
        let itemID = id
        let fileName = "pin_\(itemID).png"
        let fileURL = directoryURL.appendingPathComponent(fileName)

        ensureDirectoryExists()
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to write pin archive image file: \(error.localizedDescription)")
            return nil
        }

        let newItem = PinArchiveItem(
            id: itemID,
            createdAt: Date(),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            source: source,
            imageFileName: fileName
        )

        manifest.items.insert(newItem, at: 0)
        if !saveManifestLocked(manifest) {
            // Roll back image file if saving manifest failed
            try? FileManager.default.removeItem(at: fileURL)
            Self.logger.error("Failed to save manifest after writing image; rolled back image file")
            return nil
        }

        manifest.items = pruneToLimitsLocked(manifest.items).0
        if !fitsLimits(manifest.items) {
            // A locked oldest file must not cause deletion of more unrelated images.
            do {
                try removeFile(fileURL)
                manifest.items.removeAll { $0.id == newItem.id }
            } catch { /* Keep the failed rollback visible and manageable. */ }
            _ = saveManifestLocked(manifest)
            return nil
        }
        guard saveManifestLocked(manifest) else { return nil }
        guard manifest.items.contains(where: { $0.id == id }) else { return nil }

        return newItem
    }

    @discardableResult
    func delete(id: String) -> PinArchiveOperationResult {
        lock.lock()
        defer { lock.unlock() }

        var manifest = loadManifestLocked()
        guard let index = manifest.items.firstIndex(where: { $0.id == id }) else {
            if UUID(uuidString: id) != nil {
                let name = "pin_\(id).png"
                if isValidFileName(name), FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent(name).path) {
                    do { try removeFile(directoryURL.appendingPathComponent(name)) }
                    catch { return .failed("无法删除磁盘图片文件，请重试") }
                }
                markDeleted(id)
                return writeSessionsLocked(rawSessionsLocked().filter { $0.archiveID != id }) ? .success : .failed("贴图状态清理失败，请重试")
            }
            return .failed("未找到指定历史记录")
        }
        let removed = manifest.items[index]
        guard isValidFileName(removed.imageFileName) else { return .failed("历史文件路径无效") }
        let fileURL = directoryURL.appendingPathComponent(removed.imageFileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try removeFile(fileURL)
            } catch {
                Self.logger.error("Failed to delete pin image file: \(error.localizedDescription)")
                return .failed("无法删除磁盘图片文件：\(error.localizedDescription)")
            }
        }
        manifest.items.remove(at: index)
        markDeleted(id)
        if !saveManifestLocked(manifest) {
            return .failed("更新历史索引文件失败")
        }
        guard writeSessionsLocked(sessionsLocked().filter { $0.archiveID != id }) else {
            return .failed("图片已删除，但贴图状态清理失败，请重试")
        }
        return .success
    }

    @discardableResult
    func deleteAll() -> PinArchiveDeleteAllResult {
        lock.lock()
        defer { lock.unlock() }

        var manifest = loadManifestLocked()
        let knownNames = Set(manifest.items.map(\.imageFileName))
        // Explicit clear also owns validly named orphan PNGs when the index was removed.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
            where isValidFileName(name) && !knownNames.contains(name) {
            manifest.items.append(PinArchiveItem(id: String(name.dropFirst(4).dropLast(4)), createdAt: Date(),
                pixelWidth: 0, pixelHeight: 0, source: .legacy, imageFileName: name))
        }
        var deletedCount = 0
        var failedCount = 0
        var remainingItems: [PinArchiveItem] = []

        for item in manifest.items {
            guard isValidFileName(item.imageFileName) else {
                failedCount += 1
                remainingItems.append(item)
                continue
            }
            let fileURL = directoryURL.appendingPathComponent(item.imageFileName)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    try removeFile(fileURL)
                    deletedCount += 1
                } catch {
                    Self.logger.error("Failed to delete pin image: \(error.localizedDescription)")
                    failedCount += 1
                    remainingItems.append(item)
                }
            } else {
                deletedCount += 1
            }
        }

        // Quarantined images are still user data and must be included in explicit clear.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) {
            for name in names where name.hasSuffix(".png.corrupted") {
                let original = String(name.dropLast(".corrupted".count))
                guard isValidFileName(original) else { continue }
                do { try removeFile(directoryURL.appendingPathComponent(name)); deletedCount += 1 }
                catch { failedCount += 1 }
            }
        }

        let remainingIDs = Set(remainingItems.map(\.id))
        for item in manifest.items where !remainingIDs.contains(item.id) { markDeleted(item.id) }
        manifest.items = remainingItems
        for record in rawSessionsLocked() where !remainingIDs.contains(record.archiveID) { markDeleted(record.archiveID) }
        let saveOk = saveManifestLocked(manifest)
        let sessionOK = writeSessionsLocked(sessionsLocked())
        let errorMessage: String? = (failedCount > 0)
            ? "有 \(failedCount) 项图片文件未能删除"
            : (!saveOk || !sessionOK ? "历史索引或贴图状态文件保存失败" : nil)

        return PinArchiveDeleteAllResult(
            deletedCount: deletedCount,
            failedCount: failedCount,
            errorMessage: errorMessage
        )
    }

    private func loadManifestLocked() -> PinArchiveManifest {
        ensureDirectoryExists()
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return PinArchiveManifest()
        }
        guard let data = try? Data(contentsOf: indexURL) else {
            return recoverCorruptedIndexLocked()
        }
        if let manifest = try? jsonDecoder.decode(PinArchiveManifest.self, from: data) {
            return manifest
        }
        if let legacyList = try? jsonDecoder.decode([PinArchiveItem].self, from: data) {
            return PinArchiveManifest(version: 1, items: legacyList)
        }
        Self.logger.error("Pin archive index is invalid JSON; recovering from files")
        return recoverCorruptedIndexLocked()
    }

    private func recoverCorruptedIndexLocked() -> PinArchiveManifest {
        // 1. Backup corrupt index
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let backupName = "index.corrupt.\(Int(Date().timeIntervalSince1970)).json"
            let backupURL = directoryURL.appendingPathComponent(backupName)
            try? FileManager.default.copyItem(at: indexURL, to: backupURL)
            pruneCorruptBackupsLocked()
        }

        // 2. Scan directory for valid pin_*.png files
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else {
            return PinArchiveManifest()
        }

        var recoveredItems: [PinArchiveItem] = []
        for name in fileNames {
            guard isValidFileName(name) else { continue }
            let fileURL = directoryURL.appendingPathComponent(name)
            guard let dims = verifyImageAndGetDimensions(at: fileURL) else {
                // Quarantine bad file
                quarantineFileLocked(at: fileURL)
                continue
            }
            let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
            let date = attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date ?? Date()

            // Extract id from pin_<id>.png
            let rawID = name.dropFirst(4).dropLast(4)
            let itemID = rawID.isEmpty ? UUID().uuidString : String(rawID)

            recoveredItems.append(PinArchiveItem(
                id: itemID,
                createdAt: date,
                pixelWidth: dims.width,
                pixelHeight: dims.height,
                source: .legacy,
                imageFileName: name
            ))
        }

        // Stable sort: newest first, tie-breaker id descending
        recoveredItems.sort { a, b in
            if a.createdAt != b.createdAt {
                return a.createdAt > b.createdAt
            }
            return a.id > b.id
        }

        let (pruned, _) = pruneToLimitsLocked(recoveredItems)
        let newManifest = PinArchiveManifest(version: 1, items: pruned)
        _ = saveManifestLocked(newManifest)
        return newManifest
    }

    private func pruneCorruptBackupsLocked() {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else { return }
        let backups = fileNames.filter { $0.hasPrefix("index.corrupt.") && $0.hasSuffix(".json") }
        if backups.count > 3 {
            let sorted = backups.sorted()
            for old in sorted.prefix(backups.count - 3) {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(old))
            }
        }
    }

    private func quarantineFileLocked(at fileURL: URL) {
        let quarantinedURL = fileURL.appendingPathExtension("corrupted")
        try? FileManager.default.moveItem(at: fileURL, to: quarantinedURL)
    }

    private func verifyImageAndGetDimensions(at fileURL: URL) -> (width: Int, height: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if let cached = verifiedImages[fileURL.path], cached.size == size, cached.modified == modified {
            return (cached.width, cached.height)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        verifiedImages[fileURL.path] = (size, modified, width, height)
        return (width, height)
    }

    private func saveManifestLocked(_ manifest: PinArchiveManifest) -> Bool {
        ensureDirectoryExists()
        do {
            let data = try jsonEncoder.encode(manifest)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            Self.logger.error("Failed to save pin archive index: \(error.localizedDescription)")
            return false
        }
    }

    private func validateAndPruneItemsLocked(_ items: [PinArchiveItem]) -> ([PinArchiveItem], Bool) {
        var validItems: [PinArchiveItem] = []
        var changed = false
        var ids = Set<String>()
        var names = Set<String>()

        for item in items {
            guard !item.id.isEmpty, ids.insert(item.id).inserted,
                  names.insert(item.imageFileName).inserted else { changed = true; continue }
            guard isValidFileName(item.imageFileName) else {
                changed = true
                continue
            }
            let fileURL = directoryURL.appendingPathComponent(item.imageFileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                changed = true
                continue
            }
            guard let dimensions = verifyImageAndGetDimensions(at: fileURL) else {
                quarantineFileLocked(at: fileURL)
                changed = true
                continue
            }
            if item.pixelWidth != dimensions.width || item.pixelHeight != dimensions.height {
                changed = true
                validItems.append(PinArchiveItem(id: item.id, createdAt: item.createdAt, pixelWidth: dimensions.width,
                    pixelHeight: dimensions.height, source: item.source, imageFileName: item.imageFileName))
            } else { validItems.append(item) }
        }

        // Also scan directory for unindexed pin_*.png or corrupt files
        if let diskFiles = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) {
            let indexedFileNames = Set(validItems.map(\.imageFileName))
            for name in diskFiles where isValidFileName(name) {
                if !indexedFileNames.contains(name) {
                    let fileURL = directoryURL.appendingPathComponent(name)
                    if let dims = verifyImageAndGetDimensions(at: fileURL) {
                        let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
                        let date = attributes[.creationDate] as? Date ?? attributes[.modificationDate] as? Date ?? Date()
                        let rawID = name.dropFirst(4).dropLast(4)
                        let itemID = rawID.isEmpty ? UUID().uuidString : String(rawID)
                        validItems.append(PinArchiveItem(
                            id: itemID,
                            createdAt: date,
                            pixelWidth: dims.width,
                            pixelHeight: dims.height,
                            source: .legacy,
                            imageFileName: name
                        ))
                        changed = true
                    } else {
                        quarantineFileLocked(at: fileURL)
                    }
                }
            }
        }

        // Stable sort: newest first, tie-breaker id
        // Preserve insertion order for legacy records whose dates have only second precision.
        validItems.sort { $0.createdAt > $1.createdAt }

        let (pruned, limitsChanged) = pruneToLimitsLocked(validItems)
        return (pruned, changed || limitsChanged)
    }

    private func pruneToLimitsLocked(_ items: [PinArchiveItem]) -> ([PinArchiveItem], Bool) {
        var currentItems = items
        var changed = false
        guard pruneQuarantineLocked(imageBytes: imageBytes(items)) else { return (items, false) }
        let activeIDs = Set(rawSessionsLocked().filter { $0.status == .active }.map(\.archiveID))

        while currentItems.count > maximumCount {
            if let index = currentItems.lastIndex(where: { !activeIDs.contains($0.id) }) {
                let removed = currentItems.remove(at: index)
                let fileURL = directoryURL.appendingPathComponent(removed.imageFileName)
                do {
                    try removeFile(fileURL)
                    changed = true
                } catch {
                    // If deletion failed, do not discard from list to avoid desync
                    currentItems.append(removed)
                    break
                }
            } else { break }
        }

        var totalBytes = quarantineBytes() + currentItems.reduce(into: Int64(0)) { total, item in
            let fileURL = directoryURL.appendingPathComponent(item.imageFileName)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int64 {
                total += size
            }
        }

        while totalBytes > maximumTotalBytes, !currentItems.isEmpty {
            guard let index = currentItems.lastIndex(where: { !activeIDs.contains($0.id) }) else { break }
            let removed = currentItems.remove(at: index)
            let fileURL = directoryURL.appendingPathComponent(removed.imageFileName)
            var deletedSize: Int64 = 0
            if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int64 {
                deletedSize = size
            }
            do {
                try removeFile(fileURL)
                totalBytes -= deletedSize
                changed = true
            } catch {
                currentItems.append(removed)
                break
            }
        }

        return (currentItems, changed)
    }

    private func fitsLimits(_ items: [PinArchiveItem]) -> Bool {
        items.count <= maximumCount && imageBytes(items) + quarantineBytes() <= maximumTotalBytes
    }

    private func imageBytes(_ items: [PinArchiveItem]) -> Int64 {
        let bytes = items.reduce(Int64(0)) { total, item in
            let attrs = try? FileManager.default.attributesOfItem(atPath: imageURL(for: item).path)
            return total + (attrs?[.size] as? Int64 ?? 0)
        }
        return bytes
    }

    private func quarantineFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? [])
            .filter { $0.hasSuffix(".png.corrupted") && isValidFileName(String($0.dropLast(".corrupted".count))) }
            .map { directoryURL.appendingPathComponent($0) }
    }

    private func fileBytes(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func quarantineBytes() -> Int64 {
        quarantineFiles().reduce(0) { $0 + fileBytes($1) }
    }

    private func pruneQuarantineLocked(imageBytes: Int64) -> Bool {
        var files = quarantineFiles().sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return aDate < bDate
        }
        var bytes = files.reduce(Int64(0)) { $0 + fileBytes($1) }
        while !files.isEmpty && (files.count > 3 || bytes + imageBytes > maximumTotalBytes) {
            let oldest = files.removeFirst()
            let size = fileBytes(oldest)
            do { try removeFile(oldest); bytes -= size }
            catch { return false }
        }
        return true
    }

    private func encodePNG(_ image: NSImage) -> (data: Data, pixelWidth: Int, pixelHeight: Int)? {
        var rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        if rep == nil {
            if let tiffData = image.tiffRepresentation,
               let newRep = NSBitmapImageRep(data: tiffData) {
                rep = newRep
            } else if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                rep = NSBitmapImageRep(cgImage: cgImage)
            }
        }
        guard let finalRep = rep,
              let pngData = finalRep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let width = max(1, finalRep.pixelsWide > 0 ? finalRep.pixelsWide : Int(image.size.width))
        let height = max(1, finalRep.pixelsHigh > 0 ? finalRep.pixelsHigh : Int(image.size.height))
        return (pngData, width, height)
    }
}
