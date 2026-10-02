import AppKit
import SwiftUI
import TranslatorCore

@MainActor
final class ClipboardHistoryPanel: NSPanel {
    var onDismissed: (() -> Void)?
    init(service: ClipboardHistoryService) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 530),
                   styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "剪贴板历史"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        minSize = NSSize(width: 640, height: 420)
        contentView = NSHostingView(rootView: ClipboardHistoryView(service: service))
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }
    override func close() { super.close(); onDismissed?() }
}

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var service: ClipboardHistoryService
    @State private var showPreferences = false
    @State private var confirmClear = false
    @State private var includePinnedInClear = false
    @FocusState private var searchFocused: Bool
    private var selected: ClipboardEntry? { service.entries.first { $0.id == service.selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("搜索文字或来源应用", text: $service.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { Task { await service.copySelected() } }
                Toggle("仅收藏", isOn: $service.pinnedOnly).toggleStyle(.checkbox)
                Button { service.togglePause() } label: {
                    Image(systemName: service.paused ? "play.fill" : "pause.fill")
                }.help(service.paused ? "继续记录" : "暂停记录")
                .disabled(!service.preferences.enabled)
                Button { showPreferences = true } label: { Image(systemName: "gearshape") }
            }.padding(12)
            Divider()
            if !service.preferences.enabled {
                HStack {
                    Text("历史记录尚未开启。开启后，文字和图片会保存在此 Mac。")
                    Spacer()
                    Button("设置…") { showPreferences = true }
                }.font(.callout).padding(12)
                Divider()
            } else if service.paused {
                Text("记录已暂停，已有历史仍可使用。")
                    .font(.callout).foregroundStyle(.secondary).padding(8)
            }
            HSplitView {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { service.selectedID }, set: { service.select($0) })) {
                        ForEach(service.entries, id: \.id) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: entry.kind == .image ? "photo" : "text.alignleft")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.kind == .image ? "图片" : entry.preview)
                                        .lineLimit(2)
                                    Text(entry.sourceApplication.isEmpty ? "来源未知" : entry.sourceApplication)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if entry.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                            }.padding(.vertical, 3).tag(entry.id).id(entry.id)
                        }
                        if service.hasMore {
                            Button("加载更多") { Task { await service.reload(loadMore: true) } }
                        }
                    }
                    .onChange(of: service.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }.frame(minWidth: 260, idealWidth: 330)
                VStack(alignment: .leading, spacing: 12) {
                    if let selected {
                        ScrollView {
                            if let image = service.previewImage {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else if selected.kind == .image {
                                ProgressView()
                            } else {
                                Text(service.previewText).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        Text(Date(timeIntervalSince1970: Double(selected.copiedAtMs) / 1000), style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("复制") { Task { await service.copySelected() } }
                            Button("粘贴") { Task { await service.copySelected(paste: true) } }
                            if selected.kind == .text {
                                Button("纯文本粘贴") { Task { await service.copySelected(paste: true, plainTextOnly: true) } }
                            }
                        }
                        HStack {
                            Button(selected.pinned ? "取消收藏" : "收藏") { Task { await service.pinSelected() } }
                            Button("删除", role: .destructive) { Task { await service.deleteSelected() } }
                            Spacer()
                        }
                        HStack {
                            if selected.kind == .image {
                                Button("贴图") { Task { await service.pinImageSelected() } }
                                Button(service.recognizingText ? "识别中…" : "识别文字") { Task { await service.recognizeTextSelected() } }.disabled(service.recognizingText)
                                Button("二维码") { Task { await service.recognizeCodesSelected() } }
                            } else {
                                Button("翻译") { Task { await service.translateSelected() } }
                            }
                        }
                    } else {
                        ContentUnavailableView("暂无历史", systemImage: "doc.on.clipboard",
                                               description: Text("开启记录后复制文字或图片，或尝试其他搜索条件。"))
                    }
                }.padding(12).frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("\(service.stats.items) 条 · \(ByteCountFormatter.string(fromByteCount: Int64(service.stats.bytes), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清理…") { confirmClear = true }
            }.padding(10)
        }
        .onAppear { searchFocused = true }
        .onMoveCommand { direction in
            if direction == .down { service.moveSelection(1) }
            if direction == .up { service.moveSelection(-1) }
        }
        .background {
            // Hidden buttons preserve native shortcuts while the search field has focus.
            Group {
                Button("") { Task { await service.copySelected(paste: true) } }
                    .keyboardShortcut(.return, modifiers: [.option])
                Button("") { Task { await service.copySelected(paste: true, plainTextOnly: true) } }
                    .keyboardShortcut(.return, modifiers: [.option, .shift])
                Button("") { Task { await service.pinSelected() } }
                    .keyboardShortcut("p", modifiers: [.option])
                Button("") { Task { await service.deleteSelected() } }
                    .keyboardShortcut(.delete, modifiers: [.option])
            }.hidden().disabled(selected == nil)
        }
        .sheet(isPresented: $showPreferences) { ClipboardHistoryPreferencesView(service: service) }
        .sheet(isPresented: $confirmClear) {
            VStack(alignment: .leading, spacing: 16) {
                Text("清理剪贴板历史").font(.headline)
                Toggle("同时删除收藏", isOn: $includePinnedInClear)
                Text("删除后无法恢复。系统当前剪贴板内容不会被清除。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { confirmClear = false }
                    Button("删除", role: .destructive) {
                        confirmClear = false
                        Task { await service.clear(includePinned: includePinnedInClear) }
                    }
                }
            }.padding(24).frame(width: 380)
        }
        .alert("剪贴板历史", isPresented: Binding(get: { service.errorMessage != nil },
                                             set: { if !$0 { service.errorMessage = nil } })) {
            Button("好") { service.errorMessage = nil }
        } message: { Text(service.errorMessage ?? "") }
    }
}

@MainActor
private struct ClipboardHistoryPreferencesView: View {
    @ObservedObject var service: ClipboardHistoryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClipboardHistoryPreferences()
    @State private var ignoredApplications = ""
    @State private var ignoredTypes = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("剪贴板历史设置").font(.headline)
            Toggle("在本机保存复制的文字和图片", isOn: $draft.enabled)
            Text("内容不会自动上传。识别不到敏感标记的密码仍可能被记录，请排除相关应用或暂停记录。关闭记录不会删除已有历史。")
                .font(.callout).foregroundStyle(.secondary)
            Stepper("最多 \(draft.maximumItems) 条（包含收藏）", value: $draft.maximumItems, in: 100...10000, step: 100)
            Stepper("内容容量 \(draft.maximumMegabytes) MB", value: $draft.maximumMegabytes, in: 16...2048, step: 16)
            Stepper("保留 \(draft.retentionDays) 天（0 为不限，收藏不过期）", value: $draft.retentionDays, in: 0...3650)
            Text("忽略的应用 Bundle ID，每行一个").font(.callout)
            TextEditor(text: $ignoredApplications).font(.system(.body, design: .monospaced)).frame(height: 80)
            Text("额外忽略的剪贴板类型，每行一个").font(.callout)
            TextEditor(text: $ignoredTypes).font(.system(.body, design: .monospaced)).frame(height: 50)
            if let error = service.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    draft.ignoredApplications = ignoredApplications.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft.ignoredTypes = ignoredTypes.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    saving = true
                    Task {
                        await service.savePreferences(draft)
                        saving = false
                        if service.preferences == draft { dismiss() }
                    }
                }.disabled(saving)
            }
        }.padding(24).frame(width: 510)
        .onAppear {
            draft = service.preferences
            ignoredApplications = draft.ignoredApplications.joined(separator: "\n")
            ignoredTypes = draft.ignoredTypes.joined(separator: "\n")
        }
    }
}
