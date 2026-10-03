import AppIntents
import Foundation
import TranslatorCore

@MainActor
enum ClipboardIntentAccess {
    static weak var service: ClipboardHistoryService?
    static var showHistory: (() -> Void)?
    static func controller() async throws -> ClipboardHistoryService {
        for _ in 0..<30 {
            if let service { return service }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClipboardIntentError.unavailable
    }
}
private enum ClipboardIntentError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Polyglance 正在启动，请稍后重试。" }
}

struct ClipboardHistoryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "剪贴板历史条目")
    static var defaultQuery = ClipboardHistoryEntityQuery()
    let id: String
    let title: String
    let preview: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(preview)") }
    init(_ entry: ClipboardEntry) {
        id = String(entry.id)
        title = entry.title.isEmpty ? (entry.kind == .image ? "图片" : entry.kind == .file ? "文件" : "剪贴板内容") : entry.title
        preview = String(entry.preview.prefix(160))
    }
}
struct ClipboardHistoryEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ClipboardHistoryEntity] {
        let service = try await ClipboardIntentAccess.controller()
        return try await service.shortcutEntries(ids: identifiers.compactMap(UInt64.init)).map(ClipboardHistoryEntity.init)
    }
    @MainActor
    func entities(matching string: String) async throws -> [ClipboardHistoryEntity] {
        let service = try await ClipboardIntentAccess.controller()
        return try await service.shortcutSearch(query: string, limit: 100).map(ClipboardHistoryEntity.init)
    }
    @MainActor
    func suggestedEntities() async throws -> [ClipboardHistoryEntity] { try await entities(matching: "") }
}

struct OpenClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "打开剪贴板历史"
    static var description = IntentDescription("打开 Polyglance 的本机剪贴板历史窗口。")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await ClipboardIntentAccess.controller()
        ClipboardIntentAccess.showHistory?()
        return .result()
    }
}
struct SearchClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索剪贴板历史"
    static var description = IntentDescription("按文字、标题、标签或 OCR 搜索本机历史，返回最多 100 条。")
    static var openAppWhenRun = true
    @Parameter(title: "搜索内容", default: "") var query: String
    @Parameter(title: "最多条数", default: 20) var limit: Int
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ClipboardHistoryEntity]> {
        let service = try await ClipboardIntentAccess.controller()
        return .result(value: try await service.shortcutSearch(query: query, limit: limit).map(ClipboardHistoryEntity.init))
    }
}
struct GetClipboardHistoryTextIntent: AppIntent {
    static var title: LocalizedStringResource = "获取历史条目的文字"
    static var description = IntentDescription("返回完整原文，不使用预览摘要。图片或文件请使用复制条目动作。")
    static var openAppWhenRun = true
    @Parameter(title: "历史条目") var item: ClipboardHistoryEntity
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await ClipboardIntentAccess.controller()
        guard let id = UInt64(item.id) else { throw ClipboardFailure.NotFound }
        return .result(value: try await service.shortcutText(id: id))
    }
}
struct CopyClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "复制历史条目"
    static var description = IntentDescription("将条目的原始格式写入系统剪贴板。")
    static var openAppWhenRun = true
    @Parameter(title: "历史条目") var item: ClipboardHistoryEntity
    @MainActor
    func perform() async throws -> some IntentResult {
        let service = try await ClipboardIntentAccess.controller()
        guard let id = UInt64(item.id) else { throw ClipboardFailure.NotFound }
        try await service.shortcutCopy(id: id)
        return .result()
    }
}
struct DeleteClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "删除历史条目"
    static var description = IntentDescription("删除指定条目，也可删除固定条目。删除后无法恢复。")
    static var openAppWhenRun = true
    @Parameter(title: "历史条目") var item: ClipboardHistoryEntity
    @MainActor
    func perform() async throws -> some IntentResult {
        let service = try await ClipboardIntentAccess.controller()
        guard let id = UInt64(item.id) else { throw ClipboardFailure.NotFound }
        try await service.shortcutDelete(id: id)
        return .result()
    }
}
struct ClearClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "清空剪贴板历史"
    static var description = IntentDescription("默认保留固定条目。清空后无法恢复，系统当前剪贴板保持不变。")
    static var openAppWhenRun = true
    @Parameter(title: "同时删除固定条目", default: false) var includePinned: Bool
    @MainActor
    func perform() async throws -> some IntentResult {
        let service = try await ClipboardIntentAccess.controller()
        try await service.shortcutClear(includePinned: includePinned)
        return .result()
    }
}
struct PauseClipboardHistoryIntent: AppIntent {
    static var title: LocalizedStringResource = "设置剪贴板记录暂停状态"
    static var description = IntentDescription("暂停或恢复记录。首次保存历史仍需在应用设置中主动开启。")
    static var openAppWhenRun = true
    @Parameter(title: "暂停记录", default: true) var paused: Bool
    @MainActor
    func perform() async throws -> some IntentResult {
        let service = try await ClipboardIntentAccess.controller()
        try service.shortcutPause(paused)
        return .result()
    }
}
struct IgnoreNextClipboardCopyIntent: AppIntent {
    static var title: LocalizedStringResource = "忽略下一次复制"
    static var description = IntentDescription("下一次外部复制不写入历史，之后自动恢复记录。")
    static var openAppWhenRun = true
    @MainActor
    func perform() async throws -> some IntentResult {
        let service = try await ClipboardIntentAccess.controller()
        service.ignoreNextCopy()
        return .result()
    }
}
struct ClipboardAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenClipboardHistoryIntent(), phrases: ["打开 \(.applicationName) 的剪贴板历史"], shortTitle: "剪贴板历史", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: IgnoreNextClipboardCopyIntent(), phrases: ["用 \(.applicationName) 忽略下一次复制"], shortTitle: "忽略下一次复制", systemImageName: "eye.slash")
    }
}
