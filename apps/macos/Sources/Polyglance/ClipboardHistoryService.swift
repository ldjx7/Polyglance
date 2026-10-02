import AppKit
import Combine
import ApplicationServices
import ImageIO
import TranslatorCore

/// Platform preferences only. Retention and capture decisions are enforced by Rust.
struct ClipboardHistoryPreferences: Codable, Equatable {
    var enabled = false
    var maximumItems: UInt32
    var maximumMegabytes: UInt64
    var retentionDays: UInt32
    var ignoredApplications: [String] = []
    var ignoredTypes: [String] = []

    init() {
        let defaults = clipboardDefaultLimits()
        maximumItems = defaults.maximumItems
        maximumMegabytes = defaults.maximumBytes / (1024 * 1024)
        retentionDays = defaults.retentionDays
    }

    var limits: ClipboardLimits {
        let defaults = clipboardDefaultLimits()
        let product = maximumMegabytes.multipliedReportingOverflow(by: 1024 * 1024)
        let bytes = product.overflow ? UInt64.max : product.partialValue
        return ClipboardLimits(maximumItems: maximumItems, maximumBytes: bytes,
                               maximumItemBytes: min(defaults.maximumItemBytes, bytes), retentionDays: retentionDays)
    }
    func policy(paused: Bool) -> ClipboardPolicy {
        ClipboardPolicy(enabled: enabled && !paused,
                        ignoredApplications: ignoredApplications, ignoredTypes: ignoredTypes)
    }
}

/// Prevents temporary copies used by selection capture from entering history.
@MainActor
enum ClipboardCaptureSuppression {
    static private(set) var depth = 0
    static private(set) var generation: UInt64 = 0
    static func begin() { depth += 1 }
    static func end() { depth = max(0, depth - 1); generation &+= 1 }
}

/// All database work is serialized away from the main thread.
actor ClipboardHistoryWorker {
    private var history: ClipboardHistory?
    private let directory: URL
    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? support
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.polyglance.macos")
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
    }
    private var initialLimits = clipboardDefaultLimits()
    private func engine(limits: ClipboardLimits? = nil) throws -> ClipboardHistory {
        if let history { return history }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("history.sqlite3").path
        let engine = try ClipboardHistory(path: path, limits: limits ?? initialLimits, nowMs: Self.now)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        history = engine
        return engine
    }
    static var now: UInt64 { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }
    func configure(_ limits: ClipboardLimits) throws {
        if history == nil { _ = try engine(limits: limits) }
        else { try engine().configure(limits: limits, nowMs: Self.now) }
        initialLimits = limits
    }
    func record(_ input: ClipboardInput, policy: ClipboardPolicy) throws -> UInt64? {
        try engine().record(input: input, policy: policy)
    }
    func list(query: String, pinnedOnly: Bool, offset: UInt32) throws -> [ClipboardEntry] {
        try engine().list(query: query, pinnedOnly: pinnedOnly, offset: offset, limit: 100, nowMs: Self.now)
    }
    func payload(id: UInt64) throws -> [ClipboardRepresentation] { try engine().payload(id: id) }
    func pin(id: UInt64, pinned: Bool) throws { try engine().setPinned(id: id, pinned: pinned, nowMs: Self.now) }
    func delete(id: UInt64) throws { try engine().delete(id: id) }
    func clear(includePinned: Bool) throws { try engine().clear(includePinned: includePinned) }
    func stats() throws -> ClipboardStats { try engine().stats() }
    func flush() {}
}

/// NSPasteboard conversion and native presentation state; no history rules here.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    static let preferencesKey = "clipboard-history.preferences.v1"
    @Published private(set) var preferences: ClipboardHistoryPreferences
    @Published private(set) var paused = false
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var selectedID: UInt64?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewText = ""
    @Published private(set) var stats = ClipboardStats(items: 0, bytes: 0)
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?
    @Published var query = "" { didSet { scheduleReload() } }
    @Published var pinnedOnly = false { didSet { scheduleReload() } }
    var onPinImage: ((NSImage) -> Void)?
    var onTranslate: ((String) -> Void)?
    var onRecognizeText: ((String) -> Void)?
    var onRecognizeCodes: ((NSImage) -> Void)?
    var onDismiss: (() -> Void)?
    private var targetApplication: NSRunningApplication?
    private let defaults: UserDefaults
    private let worker: ClipboardHistoryWorker
    private let pasteboard: NSPasteboard
    private var starting = false
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressionGeneration = ClipboardCaptureSuppression.generation
    private var captureBusy = false
    private var copyBusy = false
    private var monitoringGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var reloadGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var isPresented = false
    private var readingSelectionTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         worker: ClipboardHistoryWorker = ClipboardHistoryWorker()) {
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.worker = worker
        lastChangeCount = pasteboard.changeCount
        preferences = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(ClipboardHistoryPreferences.self, from: $0) }
            ?? ClipboardHistoryPreferences()
    }

    func start() {
        guard preferences.enabled, !paused, timer == nil, !starting else { return }
        starting = true
        lastChangeCount = pasteboard.changeCount // Do not ingest pre-opt-in clipboard contents.
        suppressionGeneration = ClipboardCaptureSuppression.generation
        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        Task {
            do {
                try await worker.configure(preferences.limits)
                guard generation == monitoringGeneration, preferences.enabled, !paused else { return }
                starting = false
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.poll() }
                }
                timer?.tolerance = 0.15
            } catch {
                if generation == monitoringGeneration { stop(); present(error) }
            }
        }
    }
    func stop() {
        timer?.invalidate(); timer = nil; starting = false
        monitoringGeneration &+= 1
    }
    func shutdown() async {
        stop()
        searchTask?.cancel()
        readingSelectionTask?.cancel()
        // Actor ordering waits for any accepted database work to finish.
        await worker.flush()
    }
    func togglePause() {
        paused.toggle()
        if paused { stop() } else { start() }
    }
    func savePreferences(_ proposed: ClipboardHistoryPreferences) async {
        // Prevent multiplication overflow from malformed imported preferences.
        guard proposed.maximumMegabytes > 0, proposed.maximumMegabytes <= 2048 else {
            errorMessage = "容量应为 1–2048 MB。"; return
        }
        stop()
        do {
            try await worker.configure(proposed.limits)
            defaults.set(try JSONEncoder().encode(proposed), forKey: Self.preferencesKey)
            preferences = proposed
        } catch { present(error) }
        start()
        await reload()
    }
    func preparePresentation() {
        targetApplication = NSWorkspace.shared.frontmostApplication
        if targetApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { targetApplication = nil }
        isPresented = true
        Task {
            do { try await worker.configure(preferences.limits); await reload() }
            catch { present(error) }
        }
    }
    func didDismiss() {
        isPresented = false
        reloadGeneration &+= 1
        selectionGeneration &+= 1
        searchTask?.cancel()
        previewImage = nil; previewText = ""
        readingSelectionTask?.cancel()
    }
    func poll() {
        if ClipboardCaptureSuppression.depth > 0 || suppressionGeneration != ClipboardCaptureSuppression.generation {
            lastChangeCount = pasteboard.changeCount
            suppressionGeneration = ClipboardCaptureSuppression.generation
            return
        }
        guard !captureBusy, timer != nil, pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let policy = preferences.policy(paused: paused)
        guard clipboardShouldCapture(policy: policy, source: source, types: types) else { return }
        do {
            guard let representations = try Self.readRepresentations(from: pasteboard, maximumBytes: preferences.limits.maximumItemBytes) else { return }
            let input = ClipboardInput(representations: representations, sourceApplication: source,
                                       observedTypes: types, copiedAtMs: ClipboardHistoryWorker.now)
            captureBusy = true
            let generation = monitoringGeneration
            Task {
                defer { captureBusy = false }
                guard generation == monitoringGeneration, preferences.enabled, !paused else { return }
                do {
                    _ = try await worker.record(input, policy: policy)
                    if isPresented { await reload() }
                } catch { present(error) }
            }
        } catch { present(error) }
    }

    /// Rich text is kept alongside plain text; files and multi-item copies are left alone.
    static func readRepresentations(from pasteboard: NSPasteboard, maximumBytes: UInt64) throws -> [ClipboardRepresentation]? {
        guard let items = pasteboard.pasteboardItems, items.count == 1, let item = items.first,
              !item.types.contains(.fileURL) else { return nil }
        if let string = item.string(forType: .string) {
            let plain = Data(string.utf8)
            guard UInt64(plain.count) <= maximumBytes else { throw ClipboardFailure.TooLarge }
            var result = [ClipboardRepresentation(format: "text/plain", bytes: plain)]
            var total = UInt64(plain.count)
            for (type, format) in [(NSPasteboard.PasteboardType.html, "text/html"), (.rtf, "text/rtf")] {
                if let data = item.data(forType: type) {
                    guard UInt64(data.count) <= maximumBytes - total else { throw ClipboardFailure.TooLarge }
                    total += UInt64(data.count)
                    result.append(ClipboardRepresentation(format: format, bytes: data))
                }
            }
            return result
        }
        let raw = item.data(forType: .png) ?? item.data(forType: .tiff)
        guard let raw else { return nil }
        guard UInt64(raw.count) <= maximumBytes else { throw ClipboardFailure.TooLarge }
        guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              clipboardImageDimensionsAllowed(width: width.uint64Value, height: height.uint64Value) else {
            throw ClipboardFailure.TooLarge
        }
        let png: Data
        if item.types.contains(.png) { png = raw }
        else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let encoded = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            png = encoded
        }
        guard UInt64(png.count) <= maximumBytes else { throw ClipboardFailure.TooLarge }
        return [ClipboardRepresentation(format: "image/png", bytes: png)]
    }

    private func scheduleReload() {
        searchTask?.cancel()
        reloadGeneration &+= 1
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }
    func reload(loadMore: Bool = false) async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let offset = loadMore ? UInt32(entries.count) : 0
        let previousSelection = selectedID
        do {
            let page = try await worker.list(query: query, pinnedOnly: pinnedOnly, offset: offset)
            let currentStats = try await worker.stats()
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            entries = loadMore ? entries + page : page
            stats = currentStats
            hasMore = page.count == 100
            if let previousSelection, entries.contains(where: { $0.id == previousSelection }) { select(previousSelection) }
            else { select(entries.first?.id) }
        } catch { if generation == reloadGeneration { present(error) } }
    }
    func select(_ id: UInt64?) {
        selectedID = id
        previewImage = nil; previewText = ""
        selectionGeneration &+= 1
        let generation = selectionGeneration
        readingSelectionTask?.cancel()
        guard let id else { return }
        readingSelectionTask = Task {
            do {
                let payload = try await worker.payload(id: id)
                guard !Task.isCancelled, generation == selectionGeneration else { return }
                previewText = String((Self.text(in: payload) ?? "").prefix(20_000))
                if let data = payload.first(where: { $0.format == "image/png" })?.bytes {
                    // Preview decodes at most a 512 px thumbnail, never the full-resolution image.
                    if let source = CGImageSourceCreateWithData(data as CFData, nil),
                       let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512,
                        kCGImageSourceCreateThumbnailWithTransform: true
                       ] as CFDictionary) {
                        previewImage = NSImage(cgImage: thumbnail, size: .zero)
                    }
                }
            } catch { if generation == selectionGeneration { present(error) } }
        }
    }
    func moveSelection(_ direction: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedID } ?? 0
        select(entries[min(max(0, index + direction), entries.count - 1)].id)
    }
    func pinSelected() async {
        guard let entry = entries.first(where: { $0.id == selectedID }) else { return }
        do { try await worker.pin(id: entry.id, pinned: !entry.pinned); await reload() }
        catch { present(error) }
    }
    func deleteSelected() async {
        guard let id = selectedID else { return }
        do { try await worker.delete(id: id); await reload() }
        catch { present(error) }
    }
    func clear(includePinned: Bool) async {
        do { try await worker.clear(includePinned: includePinned); await reload() }
        catch { present(error) }
    }
    func copySelected(paste: Bool = false, plainTextOnly: Bool = false) async {
        guard !copyBusy, let id = selectedID else { return }
        copyBusy = true
        defer { copyBusy = false }
        let target = targetApplication
        if paste && !AXIsProcessTrusted() {
            errorMessage = "自动粘贴需要辅助功能权限。你也可以先复制，再自行粘贴。"
            return
        }
        do {
            let payload = try await worker.payload(id: id)
            let item = NSPasteboardItem()
            for representation in payload {
                let type: NSPasteboard.PasteboardType
                switch representation.format {
                case "text/plain": type = .string
                case "text/html": type = .html
                case "text/rtf": type = .rtf
                case "image/png": type = .png
                default: continue
                }
                if plainTextOnly && type != .string { continue }
                item.setData(representation.bytes, forType: type)
            }
            guard !item.types.isEmpty else { return }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { throw ClipboardFailure.Storage }
            let writtenChangeCount = pasteboard.changeCount
            lastChangeCount = writtenChangeCount // Suppress this app's own replay, without filtering screenshots.
            onDismiss?()
            if paste, let target, !target.isTerminated {
                target.activate()
                try? await Task.sleep(for: .milliseconds(150))
                // Abort if the user switched apps or copied something during focus restoration.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
                      pasteboard.changeCount == writtenChangeCount else { return }
                Self.postPaste()
            }
        } catch { present(error) }
    }
    static func text(in payload: [ClipboardRepresentation]) -> String? {
        payload.first(where: { $0.format == "text/plain" }).flatMap { String(data: $0.bytes, encoding: .utf8) }
    }
    func translateSelected() async {
        guard let id = selectedID else { return }
        do {
            if let text = Self.text(in: try await worker.payload(id: id)) { onDismiss?(); onTranslate?(text) }
        } catch { present(error) }
    }
    func pinImageSelected() async {
        await withSelectedImage { image in self.onDismiss?(); self.onPinImage?(image) }
    }
    @Published private(set) var recognizingText = false
    func recognizeTextSelected() async {
        guard !recognizingText, let id = selectedID else { return }
        recognizingText = true
        defer { recognizingText = false }
        do {
            guard let data = try await worker.payload(id: id).first(where: { $0.format == "image/png" })?.bytes,
                  let image = NSImage(data: data) else { return }
            let text = try await OCRService().recognizeText(in: image)
            onDismiss?()
            onRecognizeText?(text)
        } catch { present(error) }
    }
    func recognizeCodesSelected() async {
        await withSelectedImage { image in self.onDismiss?(); self.onRecognizeCodes?(image) }
    }
    private func withSelectedImage(_ action: (NSImage) -> Void) async {
        guard let id = selectedID else { return }
        do {
            if let data = try await worker.payload(id: id).first(where: { $0.format == "image/png" })?.bytes,
               let image = NSImage(data: data) { action(image) }
        } catch { present(error) }
    }
    private static func postPaste() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func present(_ error: Error) {
        switch error {
        case ClipboardFailure.TooLarge: errorMessage = "复制内容超过历史容量限制，本次未记录。"
        case ClipboardFailure.Capacity: errorMessage = "收藏已占满历史容量，请删除部分收藏或增加容量。"
        case ClipboardFailure.InvalidInput: errorMessage = "剪贴板内容或历史设置不受支持。"
        case ClipboardFailure.UnsupportedSchema: errorMessage = "历史数据来自较新的版本，请升级 Polyglance。"
        case ClipboardFailure.NotFound: errorMessage = "这条历史已被删除或过期。"
        default: errorMessage = "无法读写剪贴板历史，请检查磁盘空间和目录权限。"
        }
    }
}
