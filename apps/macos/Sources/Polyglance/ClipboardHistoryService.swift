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
    var ocrSearchEnabled = false

    init() {
        let defaults = clipboardDefaultLimits()
        maximumItems = defaults.maximumItems
        maximumMegabytes = defaults.maximumBytes / (1024 * 1024)
        retentionDays = defaults.retentionDays
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, maximumItems, maximumMegabytes, retentionDays, ignoredApplications, ignoredTypes, ocrSearchEnabled
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        maximumItems = try values.decodeIfPresent(UInt32.self, forKey: .maximumItems) ?? maximumItems
        maximumMegabytes = try values.decodeIfPresent(UInt64.self, forKey: .maximumMegabytes) ?? maximumMegabytes
        retentionDays = try values.decodeIfPresent(UInt32.self, forKey: .retentionDays) ?? retentionDays
        ignoredApplications = try values.decodeIfPresent([String].self, forKey: .ignoredApplications) ?? []
        ignoredTypes = try values.decodeIfPresent([String].self, forKey: .ignoredTypes) ?? []
        ocrSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .ocrSearchEnabled) ?? false
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

/// Owns native clipboard reads, focus restoration and presentation state.
@MainActor
final class ClipboardHistoryService: ObservableObject {
    static let preferencesKey = "clipboard-history.preferences.v1"
    @Published private(set) var preferences: ClipboardHistoryPreferences
    @Published private(set) var paused = false
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var selectedID: UInt64?
    @Published private(set) var selectedIDs: Set<UInt64> = []
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewText = ""
    @Published private(set) var annotation = ClipboardAnnotation(title: "", tags: [], ocrText: "")
    @Published private(set) var selectionHasImages = false
    @Published private(set) var selectionHasFiles = false
    @Published private(set) var selectionHasPlainText = false
    @Published private(set) var stats = ClipboardStats(items: 0, bytes: 0)
    @Published private(set) var sources: [String] = []
    @Published private(set) var tags: [String] = []
    @Published private(set) var hasMore = false
    @Published private(set) var recognizingText = false
    @Published private(set) var indexingImages = false
    @Published private(set) var dataBusy = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var pasteQueueCount = 0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var query = "" { didSet { scheduleReload() } }
    @Published var pinnedOnly = false { didSet { scheduleReload() } }
    @Published var kindFilter: ClipboardKind? { didSet { scheduleReload() } }
    @Published var sourceFilter = "" { didSet { scheduleReload() } }
    @Published var tagFilter = "" { didSet { scheduleReload() } }
    var onPinImage: ((NSImage) -> Void)?
    var onTranslate: ((String) -> Void)?
    var onRecognizeText: ((String) -> Void)?
    var onRecognizeCodes: ((NSImage) -> Void)?
    var onDismiss: (() -> Void)?
    var onQueueError: (() -> Void)?
    private var targetApplication: NSRunningApplication?
    private var queueTargetApplication: NSRunningApplication?
    private var pasteQueue: [UInt64] = []
    private var pasteQueueGeneration: UInt64 = 0
    private var queueChangeCount = 0
    private let defaults: UserDefaults
    private let worker: ClipboardHistoryWorker
    private let processor: ClipboardContentProcessor
    private let pasteboard: NSPasteboard
    private var starting = false
    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressionGeneration = ClipboardCaptureSuppression.generation
    private var pendingCaptures = 0
    private var copyBusy = false
    private var monitoringGeneration: UInt64 = 0
    private var searchTask: Task<Void, Never>?
    private var reloadGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var indexGeneration: UInt64 = 0
    private var isPresented = false
    private var readingSelectionTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var selectionAnchor: Int?

    init(defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general,
         worker: ClipboardHistoryWorker = ClipboardHistoryWorker(), processor: ClipboardContentProcessor = ClipboardContentProcessor()) {
        self.defaults = defaults; self.pasteboard = pasteboard; self.worker = worker; self.processor = processor
        lastChangeCount = pasteboard.changeCount
        preferences = defaults.data(forKey: Self.preferencesKey).flatMap { try? JSONDecoder().decode(ClipboardHistoryPreferences.self, from: $0) } ?? ClipboardHistoryPreferences()
    }
    func start() {
        guard preferences.enabled, !paused, timer == nil, !starting else { return }
        starting = true
        lastChangeCount = pasteboard.changeCount
        suppressionGeneration = ClipboardCaptureSuppression.generation
        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        Task {
            do {
                try await worker.configure(preferences.limits)
                guard generation == monitoringGeneration, preferences.enabled, !paused else { return }
                starting = false
                let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
                timer.tolerance = 0.05
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                scheduleIndexing()
            } catch { if generation == monitoringGeneration { stop(); present(error, history: true) } }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; starting = false; monitoringGeneration &+= 1 }
    private func stopIndexing() { indexGeneration &+= 1; indexTask?.cancel(); indexTask = nil; indexingImages = false }
    func shutdown() async {
        stop(); stopIndexing(); searchTask?.cancel(); readingSelectionTask?.cancel(); cancelPasteQueue()
        await worker.flush()
    }
    func togglePause() { paused.toggle(); if paused { stop() } else { start() } }
    func savePreferences(_ proposed: ClipboardHistoryPreferences) async {
        guard proposed.maximumMegabytes > 0, proposed.maximumMegabytes <= 2048 else { errorMessage = "容量应为 1–2048 MB。"; return }
        stop(); stopIndexing()
        do {
            try await worker.configure(proposed.limits)
            if proposed.ocrSearchEnabled && !preferences.ocrSearchEnabled { try await worker.retryOCR() }
            defaults.set(try JSONEncoder().encode(proposed), forKey: Self.preferencesKey)
            preferences = proposed
        } catch { present(error, history: true) }
        start(); scheduleIndexing(); await reload()
    }
    func preparePresentation() {
        targetApplication = NSWorkspace.shared.frontmostApplication
        if targetApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { targetApplication = nil }
        isPresented = true
        Task {
            do { try await worker.configure(preferences.limits); needsRecovery = false; await reload(); scheduleIndexing() }
            catch { present(error, history: true) }
        }
    }
    func didDismiss() {
        isPresented = false; reloadGeneration &+= 1; selectionGeneration &+= 1
        searchTask?.cancel(); readingSelectionTask?.cancel(); previewImage = nil; previewText = ""
    }
    func poll() {
        if ClipboardCaptureSuppression.depth > 0 || suppressionGeneration != ClipboardCaptureSuppression.generation {
            lastChangeCount = pasteboard.changeCount; suppressionGeneration = ClipboardCaptureSuppression.generation; return
        }
        guard pendingCaptures < 4, timer != nil, pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let types = Array(Set((pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }))
        let policy = preferences.policy(paused: paused)
        guard clipboardShouldCapture(policy: policy, source: source, types: types) else { return }
        do {
            guard let raw = try Self.readRawItems(from: pasteboard, maximumBytes: preferences.limits.maximumItemBytes) else { return }
            let time = ClipboardHistoryWorker.now
            let generation = monitoringGeneration
            let maximumBytes = preferences.limits.maximumItemBytes
            pendingCaptures += 1
            Task {
                defer { pendingCaptures -= 1 }
                do {
                    let items = try await processor.normalize(raw, maximumBytes: maximumBytes)
                    guard generation == monitoringGeneration, preferences.enabled, !paused else { return }
                    _ = try await worker.recordBundle(ClipboardBundleInput(items: items, sourceApplication: source, observedTypes: types, copiedAtMs: time), policy: policy)
                    scheduleIndexing()
                    if isPresented { await reload() }
                } catch { if generation == monitoringGeneration { present(error, history: true) } }
            }
        } catch { present(error) }
    }
    /// Read only supported original formats; image normalization runs in its own actor.
    static func readRawItems(from board: NSPasteboard, maximumBytes: UInt64) throws -> [ClipboardRawItem]? {
        guard let items = board.pasteboardItems, !items.isEmpty else { return nil }
        guard items.count <= 100 else { throw ClipboardFailure.TooLarge }
        var total: UInt64 = 0
        var result: [ClipboardRawItem] = []
        for item in items {
            if item.types.contains(where: { $0.rawValue.contains("promised-file") }) { return nil }
            var representations: [ClipboardRawItem.Representation] = []
            func append(_ format: String, _ data: Data) throws {
                guard UInt64(data.count) <= maximumBytes - total else { throw ClipboardFailure.TooLarge }
                total += UInt64(data.count)
                representations.append(.init(format: format, bytes: data))
            }
            if let file = item.string(forType: .fileURL) {
                guard let url = URL(string: file), url.isFileURL else { throw ClipboardFailure.InvalidInput }
                try append("text/uri-list", Data(file.utf8))
            } else {
                if let plain = item.string(forType: .string) {
                    try append("text/plain", Data(plain.utf8))
                    for (type, format) in [(NSPasteboard.PasteboardType.html, "text/html"), (.rtf, "text/rtf")] {
                        if let data = item.data(forType: type) { try append(format, data) }
                    }
                }
                if let png = item.data(forType: .png) { try append("image/png", png) }
                else if let tiff = item.data(forType: .tiff) { try append("image/tiff", tiff) }
            }
            guard !representations.isEmpty else { return nil }
            result.append(ClipboardRawItem(representations: representations))
        }
        return result
    }
    private func scheduleReload() {
        searchTask?.cancel(); reloadGeneration &+= 1
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
            await reload()
        }
    }
    func reload(loadMore: Bool = false) async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let offset = loadMore ? UInt32(entries.count) : 0
        let filter = ClipboardFilter(query: query, kind: kindFilter, source: sourceFilter.isEmpty ? nil : sourceFilter, tag: tagFilter.isEmpty ? nil : tagFilter, pinnedOnly: pinnedOnly)
        do {
            let page = try await worker.list(filter: filter, offset: offset)
            let stats = try await worker.stats()
            let sources = try await worker.sources(); let tags = try await worker.tags()
            guard generation == reloadGeneration, !Task.isCancelled else { return }
            if loadMore { let known = Set(entries.map(\.id)); entries.append(contentsOf: page.filter { !known.contains($0.id) }) }
            else { entries = page }
            self.stats = stats; self.sources = sources; self.tags = tags; hasMore = page.count == 100; needsRecovery = false
            let retained = selectedIDs.intersection(Set(entries.map(\.id)))
            setSelection(retained.isEmpty ? Set(entries.first.map { [$0.id] } ?? []) : retained)
        } catch { if generation == reloadGeneration { present(error, history: true) } }
    }
    func select(_ id: UInt64?) { setSelection(id.map { [$0] } ?? []) }
    func setSelection(_ ids: Set<UInt64>) {
        selectedIDs = ids.intersection(Set(entries.map(\.id)))
        let primary = selectedID.flatMap { selectedIDs.contains($0) ? $0 : nil } ?? entries.first { selectedIDs.contains($0.id) }?.id
        selectForPreview(primary)
    }
    private func selectForPreview(_ id: UInt64?) {
        selectedID = id; previewImage = nil; previewText = ""
        selectionHasImages = false; selectionHasFiles = false; selectionHasPlainText = false
        annotation = ClipboardAnnotation(title: "", tags: [], ocrText: "")
        selectionGeneration &+= 1; let generation = selectionGeneration
        readingSelectionTask?.cancel(); guard let id else { return }
        readingSelectionTask = Task {
            do {
                let bundle = try await worker.bundle(id: id); let annotation = try await worker.annotation(id: id)
                let preview = try await processor.preview(bundle, ocrText: annotation.ocrText)
                guard !Task.isCancelled, generation == selectionGeneration else { return }
                self.annotation = annotation; previewText = preview.text
                if let image = preview.image { previewImage = NSImage(cgImage: image, size: .zero) }
                selectionHasImages = preview.hasImages; selectionHasFiles = preview.hasFiles; selectionHasPlainText = preview.plainTextAvailable
            } catch { if generation == selectionGeneration { present(error) } }
        }
    }
    func moveSelection(_ direction: Int, extending: Bool = false) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(0, index + direction), entries.count - 1)
        if extending {
            let anchor = selectionAnchor ?? index; selectionAnchor = anchor
            selectedIDs = Set(entries[min(anchor, next)...max(anchor, next)].map(\.id)); selectForPreview(entries[next].id)
        } else { selectionAnchor = nil; select(entries[next].id) }
    }
    func pinSelected() async {
        guard let entry = entries.first(where: { $0.id == selectedID }) else { return }
        do { try await worker.pin(id: entry.id, pinned: !entry.pinned); await reload() } catch { present(error) }
    }
    func rename(id: UInt64, title: String, tags: [String]) async -> Bool {
        do { try await worker.setAnnotation(id: id, title: title, tags: tags); await reload(); return true } catch { present(error); return false }
    }
    func deleteSelected() async {
        guard let id = selectedID else { return }
        do { try await worker.delete(id: id); await reload() } catch { present(error) }
    }
    func clearPreview(includePinned: Bool) async -> ClipboardClearPreview? {
        do { return try await worker.clearPreview(includePinned: includePinned) } catch { present(error); return nil }
    }
    func clear(includePinned: Bool) async {
        stopIndexing(); cancelPasteQueue()
        do { try await worker.clear(includePinned: includePinned); await reload(); scheduleIndexing() } catch { present(error) }
    }
    private var orderedSelection: [UInt64] { entries.filter { selectedIDs.contains($0.id) }.map(\.id) }
    func copySelected(paste: Bool = false, plainTextOnly: Bool = false) async {
        guard !copyBusy, !dataBusy else { return }
        copyBusy = true; defer { copyBusy = false }
        await searchTask?.value
        guard !Task.isCancelled, !orderedSelection.isEmpty else { return }
        do { _ = try await replay(orderedSelection, paste: paste, plainTextOnly: plainTextOnly, target: targetApplication) } catch { present(error) }
    }
    private func replay(_ ids: [UInt64], paste: Bool, plainTextOnly: Bool, target: NSRunningApplication?, queueGeneration: UInt64? = nil) async throws -> Bool {
        if paste && !AXIsProcessTrusted() { throw NativeClipboardError.message("自动粘贴需要辅助功能权限。也可以先复制，再自行粘贴。") }
        if paste && (target == nil || target?.isTerminated == true) { throw NativeClipboardError.message("原应用已不可用，请回到目标应用后重新打开历史。") }
        var bundle: [ClipboardItem] = []
        var totalBytes: UInt64 = 0
        let maximumBytes = preferences.limits.maximumItemBytes
        for id in ids {
            let items = try await worker.bundle(id: id)
            guard items.count <= 100 - bundle.count else { throw ClipboardFailure.TooLarge }
            for representation in items.flatMap(\.representations) {
                guard UInt64(representation.bytes.count) <= maximumBytes - totalBytes else { throw ClipboardFailure.TooLarge }
                totalBytes += UInt64(representation.bytes.count)
            }
            bundle.append(contentsOf: items)
        }
        let objects = try Self.replayObjects(bundle, plainTextOnly: plainTextOnly)
        guard !objects.isEmpty, !dataBusy, !Task.isCancelled,
              queueGeneration == nil || queueGeneration == pasteQueueGeneration else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { throw ClipboardFailure.Storage }
        let writtenCount = pasteboard.changeCount; lastChangeCount = writtenCount
        onDismiss?()
        guard paste, let target else { return true }
        target.activate()
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, queueGeneration == nil || queueGeneration == pasteQueueGeneration, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,
              pasteboard.changeCount == writtenCount else { return false }
        Self.postPaste(); return true
    }
    static func replayObjects(_ bundle: [ClipboardItem], plainTextOnly: Bool = false) throws -> [NSPasteboardItem] {
        if plainTextOnly {
            guard let text = clipboardPlainText(items: bundle) else { throw NativeClipboardError.message("所选内容包含图片或文件，无法作为纯文本粘贴。") }
            let item = NSPasteboardItem(); item.setString(text, forType: .string); return [item]
        }
        return try bundle.map { source in
            let item = NSPasteboardItem()
            for representation in source.representations {
                let type: NSPasteboard.PasteboardType
                switch representation.format {
                case "text/plain": type = .string
                case "text/html": type = .html
                case "text/rtf": type = .rtf
                case "image/png": type = .png
                case "text/uri-list":
                    guard let value = String(data: representation.bytes, encoding: .utf8), let url = URL(string: value), url.isFileURL,
                          FileManager.default.fileExists(atPath: url.path) else { throw NativeClipboardError.message("历史引用的文件已移动或删除，请重新复制文件。") }
                    type = .fileURL
                default: throw ClipboardFailure.InvalidInput
                }
                item.setData(representation.bytes, forType: type)
            }
            return item
        }
    }
    func queueSelectedForPaste() async {
        await searchTask?.value
        guard !dataBusy, !Task.isCancelled, !orderedSelection.isEmpty else { return }
        guard AXIsProcessTrusted(), let targetApplication else { errorMessage = "连续粘贴需要辅助功能权限和有效的原应用。"; return }
        pasteQueueGeneration &+= 1; queueChangeCount = pasteboard.changeCount
        pasteQueue = orderedSelection; queueTargetApplication = targetApplication; pasteQueueCount = pasteQueue.count
        statusMessage = "已加入粘贴队列，可使用粘贴下一条快捷键。"
    }
    func cancelPasteQueue() { pasteQueueGeneration &+= 1; pasteQueue = []; queueTargetApplication = nil; pasteQueueCount = 0 }
    func pasteNextQueued() async {
        guard !copyBusy, !dataBusy, let id = pasteQueue.first else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard (front?.processIdentifier == queueTargetApplication?.processIdentifier || (isPresented && front?.bundleIdentifier == Bundle.main.bundleIdentifier)),
              pasteboard.changeCount == queueChangeCount else {
            cancelPasteQueue(); errorMessage = "目标应用或剪贴板已变化，连续粘贴已停止。"; onQueueError?(); return
        }
        let generation = pasteQueueGeneration
        copyBusy = true; defer { copyBusy = false }
        do {
            if try await replay([id], paste: true, plainTextOnly: false, target: queueTargetApplication, queueGeneration: generation) {
                guard generation == pasteQueueGeneration, pasteQueue.first == id else { return }
                queueChangeCount = pasteboard.changeCount
                pasteQueue.removeFirst(); pasteQueueCount = pasteQueue.count
                if pasteQueue.isEmpty { queueTargetApplication = nil }
            } else {
                guard generation == pasteQueueGeneration else { return }
                cancelPasteQueue(); errorMessage = "粘贴目标或剪贴板发生变化，连续粘贴已停止。"; onQueueError?()
            }
        } catch { cancelPasteQueue(); present(error); onQueueError?() }
    }
    static func text(in payload: [ClipboardRepresentation]) -> String? { payload.first { $0.format == "text/plain" }.flatMap { String(data: $0.bytes, encoding: .utf8) } }
    func translateSelected() async {
        guard let id = selectedID else { return }
        do { if let text = clipboardPlainText(items: try await worker.bundle(id: id)) { onDismiss?(); onTranslate?(text) } } catch { present(error) }
    }
    func pinImageSelected() async { await withSelectedImage { self.onDismiss?(); self.onPinImage?($0) } }
    func recognizeCodesSelected() async { await withSelectedImage { self.onDismiss?(); self.onRecognizeCodes?($0) } }
    private func withSelectedImage(_ action: (NSImage) -> Void) async {
        guard let id = selectedID else { return }
        do {
            if let data = try await worker.bundle(id: id).flatMap(\.representations).first(where: { $0.format == "image/png" })?.bytes,
               let image = NSImage(data: data) { action(image) }
        } catch { present(error) }
    }
    func recognizeTextSelected() async {
        guard !recognizingText, let id = selectedID else { return }
        recognizingText = true; defer { recognizingText = false }
        do {
            let cached = try await worker.annotation(id: id).ocrText
            let text: String
            if !cached.isEmpty { text = cached }
            else { let bundle = try await worker.bundle(id: id); text = try await processor.recognize(bundle); try await worker.storeOCR(id: id, text: text) }
            guard !text.isEmpty else { throw OCRError.noText }
            guard selectedID == id else { return }
            onDismiss?(); onRecognizeText?(text)
        } catch { present(error) }
    }
    private func scheduleIndexing() {
        guard preferences.ocrSearchEnabled, indexTask == nil, !dataBusy, !needsRecovery else { return }
        indexGeneration &+= 1; let generation = indexGeneration; indexingImages = true
        indexTask = Task {
            defer { if generation == indexGeneration { indexTask = nil; indexingImages = false } }
            do {
                while !Task.isCancelled, preferences.ocrSearchEnabled, generation == indexGeneration {
                    guard let id = try await worker.pendingOCR().first else { break }
                    do {
                        let bundle = try await worker.bundle(id: id)
                        let text = try await processor.recognize(bundle)
                        guard !Task.isCancelled, generation == indexGeneration, preferences.ocrSearchEnabled else { return }
                        try await worker.storeOCR(id: id, text: text)
                    } catch {
                        guard !Task.isCancelled, generation == indexGeneration else { return }
                        try? await worker.failOCR(id: id)
                    }
                    if isPresented { await reload() }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch { if generation == indexGeneration { present(error) } }
        }
    }
    func retryImageIndexing() async {
        stopIndexing()
        do { try await worker.retryOCR(); scheduleIndexing() } catch { present(error) }
    }
    func exportBackup(to url: URL) async {
        guard !dataBusy else { return }; dataBusy = true; defer { dataBusy = false }
        do { try await worker.exportBackup(path: url.path); statusMessage = "备份已保存。" } catch { present(error, backup: true) }
    }
    func inspectBackup(at url: URL) async -> ClipboardBackupInfo? {
        guard !dataBusy else { return nil }; dataBusy = true; defer { dataBusy = false }
        do { return try await worker.inspectBackup(path: url.path) } catch { present(error, backup: true); return nil }
    }
    func importBackup(from url: URL, mode: ClipboardRestoreMode) async {
        guard !dataBusy else { return }; dataBusy = true; stop(); stopIndexing(); cancelPasteQueue()
        do {
            let report = try await worker.importBackup(path: url.path, mode: mode)
            needsRecovery = false; statusMessage = "恢复完成：新增 \(report.added) 条，合并 \(report.merged) 条，按保存规则清理 \(report.evicted) 条。"
            await reload()
        } catch { present(error, backup: true) }
        dataBusy = false; start(); scheduleIndexing()
    }
    private static func postPaste() {
        guard let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func present(_ error: Error, history: Bool = false, backup: Bool = false) {
        if let native = error as? NativeClipboardError { errorMessage = native.localizedDescription; return }
        if let ocr = error as? OCRError { errorMessage = ocr.localizedDescription; return }
        switch error {
        case ClipboardFailure.TooLarge: errorMessage = "内容超过历史容量或图片大小限制。"
        case ClipboardFailure.Capacity: errorMessage = "收藏已占满历史容量，请删除部分收藏或增加容量。"
        case ClipboardFailure.InvalidInput: errorMessage = "内容格式或历史设置不受支持。"
        case ClipboardFailure.UnsupportedSchema: errorMessage = "数据来自较新的版本，请升级 Polyglance。"
        case ClipboardFailure.NotFound: errorMessage = "这条历史已被删除或过期。"
        case ClipboardFailure.Corrupt:
            if history { needsRecovery = true }
            errorMessage = backup ? "备份损坏，已有历史未被修改。" : "历史数据库损坏，可以从备份恢复。"
        default: errorMessage = backup ? "无法读写备份，请检查文件和磁盘空间。" : "无法读写剪贴板历史，请检查磁盘空间和目录权限。"
        }
    }
}
private enum NativeClipboardError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
