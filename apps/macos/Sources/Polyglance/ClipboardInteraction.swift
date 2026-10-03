import AppKit
import UserNotifications

/// Native sample identity is transient; Rust verifies the stored content before removal.
struct ClipboardCaptureLifecycle {
    enum Action: Equatable { case capture, skip, clear(Int?), idle }
    private(set) var ignoringNext = false
    private(set) var latestSequence: Int?
    mutating func armIgnore() { ignoringNext = true }
    mutating func cancelIgnore() { ignoringNext = false }
    mutating func invalidateInternalSample() { latestSequence = nil }
    mutating func observe(sequence: Int, empty: Bool) -> Action {
        if empty { let previous = latestSequence; latestSequence = nil; return .clear(previous) }
        latestSequence = sequence
        if ignoringNext { ignoringNext = false; return .skip }
        return .capture
    }
}

struct ClipboardHexColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    init?(text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard [3,4,6,8].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        if value.count <= 4 { value = value.map { "\($0)\($0)" }.joined() }
        if value.count == 6 { value += "ff" }
        guard let rgba = UInt32(value, radix: 16) else { return nil }
        red = Double((rgba >> 24) & 255) / 255; green = Double((rgba >> 16) & 255) / 255
        blue = Double((rgba >> 8) & 255) / 255; alpha = Double(rgba & 255) / 255
    }
}

@MainActor
final class ClipboardSourceCatalog {
    private var cache: [String: (String, NSImage?)] = [:]
    func source(_ identifier: String) -> (name: String, icon: NSImage?) {
        guard !identifier.isEmpty else { return ("来源未知", nil) }
        if let cached = cache[identifier] { return cached }
        let result: (String, NSImage?)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            result = (FileManager.default.displayName(atPath: url.path), NSWorkspace.shared.icon(forFile: url.path))
        } else { result = (identifier, nil) }
        if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
        cache[identifier] = result
        return result
    }
}

@MainActor
final class ClipboardNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var lastSent: [String: Date] = [:]
    func authorize() async throws -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        return try await center.requestAuthorization(options: [.alert])
    }
    func send(copied: Bool) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let kind = copied ? "capture" : "selection"
        let now = Date()
        if let last = lastSent[kind], now.timeIntervalSince(last) < 2 { return }
        lastSent[kind] = now
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = copied ? "已记录新的剪贴板内容" : "已复制历史内容"
        content.body = copied ? "可以在 Polyglance 剪贴板历史中查看。" : "可以粘贴到需要的位置。"
        // Never put clipboard payloads, source names or OCR text on the lock screen.
        Task { try? await center.add(UNNotificationRequest(identifier: "clipboard.\(kind)", content: content, trigger: nil)) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
