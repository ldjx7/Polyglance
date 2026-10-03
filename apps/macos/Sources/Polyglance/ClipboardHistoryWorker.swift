import Foundation
import TranslatorCore

/// Serializes persistence and file operations away from the main actor.
actor ClipboardHistoryWorker {
    private var history: ClipboardHistory?
    private let directory: URL
    private var initialLimits = clipboardDefaultLimits()
    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.polyglance.macos").appendingPathComponent("ClipboardHistory", isDirectory: true)
    }
    private var database: URL { directory.appendingPathComponent("history.sqlite3") }
    private func engine(limits: ClipboardLimits? = nil) throws -> ClipboardHistory {
        if let history { return history }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let engine = try ClipboardHistory(path: database.path, limits: limits ?? initialLimits, nowMs: Self.now)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        history = engine
        return engine
    }
    static var now: UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }
    func configure(_ limits: ClipboardLimits) throws {
        if history == nil { initialLimits = limits; _ = try engine(limits: limits) }
        else { try engine().configure(limits: limits, nowMs: Self.now) }
        initialLimits = limits
    }
    func record(_ input: ClipboardInput, policy: ClipboardPolicy) throws -> UInt64? { try engine().record(input: input, policy: policy) }
    func recordBundle(_ input: ClipboardBundleInput, policy: ClipboardPolicy) throws -> UInt64? { try engine().recordBundle(input: input, policy: policy) }
    func recordCapturedBundle(_ input: ClipboardBundleInput, policy: ClipboardPolicy) throws -> ClipboardCapturedRecord? {
        let engine = try engine()
        guard let id = try engine.recordBundle(input: input, policy: policy) else { return nil }
        return ClipboardCapturedRecord(id: id, token: try engine.captureToken(id: id))
    }
    func deleteCapture(_ record: ClipboardCapturedRecord) throws -> Bool { try engine().deleteIfCaptureMatches(id: record.id, token: record.token) }
    func pinShortcuts() throws -> [ClipboardPinShortcut] { try engine().pinShortcuts() }
    func setPinShortcut(id: UInt64, key: String) throws { try engine().setPinShortcut(id: id, key: key) }
    func editPinnedText(id: UInt64, text: String) throws { try engine().editPinnedText(id: id, text: text, nowMs: Self.now) }
    func list(query: String, pinnedOnly: Bool, offset: UInt32) throws -> [ClipboardEntry] { try engine().list(query: query, pinnedOnly: pinnedOnly, offset: offset, limit: 100, nowMs: Self.now) }
    func list(filter: ClipboardFilter, offset: UInt32) throws -> [ClipboardEntry] { try engine().listFiltered(filter: filter, offset: offset, limit: 100, nowMs: Self.now) }
    func payload(id: UInt64) throws -> [ClipboardRepresentation] { try engine().payload(id: id) }
    func bundle(id: UInt64) throws -> [ClipboardItem] { try engine().bundle(id: id) }
    func annotation(id: UInt64) throws -> ClipboardAnnotation { try engine().annotation(id: id) }
    func setAnnotation(id: UInt64, title: String, tags: [String]) throws { try engine().setAnnotation(id: id, title: title, tags: tags, nowMs: Self.now) }
    func pendingOCR() throws -> [UInt64] { try engine().pendingOcr(limit: 1) }
    func storeOCR(id: UInt64, text: String) throws { try engine().storeOcr(id: id, text: text, nowMs: Self.now) }
    func ocrSnapshot(id: UInt64) throws -> ClipboardOCRSnapshot {
        let engine = try engine()
        return ClipboardOCRSnapshot(record: ClipboardCapturedRecord(id: id, token: try engine.captureToken(id: id)),
                                    items: try engine.bundle(id: id), annotation: try engine.annotation(id: id))
    }
    func storeOCR(record: ClipboardCapturedRecord, text: String) throws -> Bool {
        try engine().storeOcrIfCaptureMatches(id: record.id, token: record.token, text: text, nowMs: Self.now)
    }
    func failOCR(record: ClipboardCapturedRecord) throws {
        _ = try engine().markOcrFailedIfCaptureMatches(id: record.id, token: record.token)
    }
    func failOCR(id: UInt64) throws { try engine().markOcrFailed(id: id) }
    func retryOCR() throws { try engine().retryOcr() }
    func sources() throws -> [String] { try engine().sources() }
    func tags() throws -> [String] { try engine().tags() }
    func pin(id: UInt64, pinned: Bool) throws { try engine().setPinned(id: id, pinned: pinned, nowMs: Self.now) }
    func delete(id: UInt64) throws { try engine().delete(id: id) }
    func clear(includePinned: Bool) throws { try engine().clear(includePinned: includePinned) }
    func clearPreview(includePinned: Bool) throws -> ClipboardClearPreview { try engine().clearPreview(includePinned: includePinned) }
    func stats() throws -> ClipboardStats { try engine().stats() }
    func entry(id: UInt64) throws -> ClipboardEntry? { try engine().entry(id: id, nowMs: Self.now) }
    func exportBackup(path: String) throws { _ = try engine().exportBackup(path: path) }
    func inspectBackup(path: String) throws -> ClipboardBackupInfo { try clipboardInspectBackup(path: path) }
    func importBackup(path: String, mode: ClipboardRestoreMode) throws -> ClipboardRestoreReport {
        do { return try engine().importBackup(path: path, mode: mode, nowMs: Self.now) }
        catch ClipboardFailure.Corrupt where mode == .replace && history == nil {
            let report = try clipboardRecoverDatabase(path: database.path, backup: path, limits: initialLimits, nowMs: Self.now)
            _ = try engine()
            return report
        }
    }
    func flush() {}
}
struct ClipboardCapturedRecord: Sendable { let id: UInt64; let token: String }
struct ClipboardOCRSnapshot: Sendable {
    let record: ClipboardCapturedRecord
    let items: [ClipboardItem]
    let annotation: ClipboardAnnotation
}
