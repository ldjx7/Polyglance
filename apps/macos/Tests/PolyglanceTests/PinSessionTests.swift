import AppKit
import XCTest
@testable import Polyglance

final class PinSessionTests: XCTestCase {
    func testSessionMemoryBudgetUsesDecodedImageDimensions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        _ = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        let path = dir.appendingPathComponent("index.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var items = try XCTUnwrap(manifest["items"] as? [[String: Any]])
        items[0]["pixelWidth"] = Int.max
        items[0]["pixelHeight"] = Int.max
        manifest["items"] = items
        try JSONSerialization.data(withJSONObject: manifest).write(to: path)
        let loaded = try XCTUnwrap(store.list().first)
        XCTAssertEqual(loaded.pixelWidth, 8)
        XCTAssertEqual(loaded.pixelHeight, 8)
    }
    func testMissingIndexDoesNotLetDestroyOrClearLeaveOrphanImages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let item = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        XCTAssertTrue(store.delete(id: item.id).isSuccess)
        XCTAssertTrue(store.list().isEmpty)
        _ = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        XCTAssertNil(store.deleteAll().errorMessage)
        XCTAssertTrue(store.list().isEmpty)
    }
    private func image() -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
    }

    func testClosedHistoryIsBoundedAndClearRemovesText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let item = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        for number in 0..<25 {
            var record = PinSessionRecord(archiveID: item.id, text: "text-\(number)", frame: CGRect(x: number, y: 0, width: 200, height: 100))
            record.status = .closed
            XCTAssertTrue(store.saveSession(record))
        }
        XCTAssertEqual(store.loadSessions().filter { $0.status == .closed }.count, 20)
        XCTAssertEqual(store.loadSessions().last?.text, "text-24")
        XCTAssertNil(store.deleteAll().errorMessage)
        XCTAssertTrue(store.loadSessions().isEmpty)
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent("sessions.json"), encoding: .utf8).contains("text-"))
    }

    func testFullActiveArchiveRejectsNewRecordAndDoesNotEvictActive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir, maximumCount: 1)
        let active = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        XCTAssertTrue(store.saveSession(PinSessionRecord(archiveID: active.id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))))
        XCTAssertNil(store.append(image: image(), source: .screenshot))
        XCTAssertEqual(store.list().map(\.id), [active.id])
    }

    func testReplacementCannotRecreateDeletedImageAndInvalidStateIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let item = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        var state = PinSessionRecord(archiveID: item.id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        state.opacity = .nan
        XCTAssertFalse(store.saveSession(state))
        XCTAssertTrue(store.replaceImage(image(), id: item.id))
        XCTAssertTrue(store.delete(id: item.id).isSuccess)
        XCTAssertTrue(store.wasDeleted(item.id))
        XCTAssertFalse(store.replaceImage(image(), id: item.id))
        XCTAssertTrue(store.delete(id: item.id).isSuccess)
        let specialized = try XCTUnwrap(store.append(image: image(), source: .ocr))
        XCTAssertNil(store.deleteAll().errorMessage)
        XCTAssertTrue(store.wasDeleted(specialized.id), "Clear also invalidates in-memory specialized OCR snapshots without session metadata")
    }

    func testCorruptSessionMetadataIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let item = try XCTUnwrap(store.append(image: image(), source: .clipboard))
        let url = dir.appendingPathComponent("sessions.json")
        try Data("damaged metadata".utf8).write(to: url)
        XCTAssertFalse(store.saveSession(PinSessionRecord(archiveID: item.id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "damaged metadata")
    }
    func testSessionRoundTripAndDestroyRemovesOriginalText() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let item = try XCTUnwrap(store.append(image: image, source: .clipboard))
        var state = PinSessionRecord(archiveID: item.id, text: "原文\nselect me", frame: CGRect(x: -500, y: 90, width: 300, height: 200))
        state.opacity = 0.6
        XCTAssertTrue(store.saveSession(state))
        XCTAssertEqual(PinArchiveStore(directoryURL: dir).loadSessions().first, state)
        state.status = .closed
        XCTAssertTrue(store.saveSession(state))
        XCTAssertEqual(store.loadSessions().first?.status, .closed)
        XCTAssertTrue(store.delete(id: item.id).isSuccess)
        XCTAssertTrue(store.loadSessions().isEmpty)
        XCTAssertFalse(store.saveSession(state), "An old queued UI update must not recreate deleted history")
        let metadata = try String(contentsOf: dir.appendingPathComponent("sessions.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("select me"))
    }

    func testActiveImageIsNotEvictedByNewHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir, maximumCount: 2)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let active = try XCTUnwrap(store.append(image: image, source: .clipboard))
        XCTAssertTrue(store.saveSession(PinSessionRecord(archiveID: active.id, frame: CGRect(x: 0, y: 0, width: 100, height: 100))))
        let old = try XCTUnwrap(store.append(image: image, source: .screenshot))
        _ = try XCTUnwrap(store.append(image: image, source: .screenshot))
        XCTAssertNotNil(store.loadImage(id: active.id))
        XCTAssertNil(store.loadImage(id: old.id))
    }
}
