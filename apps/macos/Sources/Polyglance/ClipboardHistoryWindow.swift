import AppKit
import SwiftUI
import TranslatorCore
import UniformTypeIdentifiers
import PolyglanceKit
import AppIntents

private extension Notification.Name { static let clipboardFocusSearch = Notification.Name("clipboard-history.focus-search") }
@MainActor
final class ClipboardHistoryPanel: NSPanel {
    var onDismissed: (() -> Void)?
    private let service: ClipboardHistoryService
    private(set) var isCycling = false
    private var cycleModifiers: NSEvent.ModifierFlags = []
    private var cycleKeyCode: UInt16?
    private var cycleGeneration: UInt64 = 0
    private var cycleTask: Task<Void, Never>?
    private var pendingCycleSteps = 0
    private var committedDismissal = false
    init(service: ClipboardHistoryService) {
        self.service = service
        super.init(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "剪贴板历史"; level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false; hidesOnDeactivate = false; minSize = NSSize(width: 760, height: 520)
        contentView = NSHostingView(rootView: ClipboardHistoryView(service: service))
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if event.type == .flagsChanged, isCycling, !modifiers.isSuperset(of: cycleModifiers) {
            finishCycle(); super.sendEvent(event); return
        }
        if event.type == .leftMouseDown { cancelCycle() }
        if event.type == .keyDown, isCycling, event.keyCode != cycleKeyCode { cancelCycle() }
        if event.type == .keyDown, attachedSheet == nil, !composing {
            if event.keyCode == 3, modifiers == .command { NotificationCenter.default.post(name: .clipboardFocusSearch, object: nil); return }
            if event.keyCode == 49, modifiers == .control { service.previewVisible.toggle(); return }
            let selectionModifiers: [NSEvent.ModifierFlags] = [.command, .option, [.option, .shift]]
            if selectionModifiers.contains(modifiers) {
                let paste = modifiers.contains(.option) || service.preferences.selectionPastesAutomatically
                let plain = modifiers.contains(.option) && modifiers.contains(.shift)
                let digits: [UInt16: Int] = [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9]
                if let number = digits[event.keyCode] { cancelCycle(); Task { await service.copyNumbered(number, paste: paste, plainTextOnly: plain) }; return }
                if let key = event.charactersIgnoringModifiers?.lowercased(), service.pinShortcuts.contains(where: { $0.key == key }) {
                    cancelCycle(); Task { await service.copyPinnedKey(key, paste: paste, plainTextOnly: plain) }; return
                }
            }
            if modifiers.intersection([.command, .control]).isEmpty {
                if event.keyCode == 36 || event.keyCode == 76 {
                    cancelCycle()
                    Task { await service.copySelected(paste: modifiers.contains(.option) || service.preferences.selectionPastesAutomatically, plainTextOnly: modifiers.contains(.option) && modifiers.contains(.shift)) }
                    return
                }
                if !modifiers.contains(.option) {
                    if event.keyCode == 125 { service.moveSelection(1, extending: modifiers.contains(.shift)); return }
                    if event.keyCode == 126 { service.moveSelection(-1, extending: modifiers.contains(.shift)); return }
                }
            }
        }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) {
        if let editor = firstResponder as? NSTextView, editor.hasMarkedText() { editor.unmarkText(); return }
        close()
    }
    func beginCycle(_ shortcut: RecordedShortcut) {
        guard attachedSheet == nil else { return }
        cancelCycle()
        cycleKeyCode = UInt16(exactly: shortcut.keyCode)
        if shortcut.modifiers.contains(.command) { cycleModifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { cycleModifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { cycleModifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { cycleModifiers.insert(.shift) }
        isCycling = !cycleModifiers.isEmpty
        if isCycling, !NSEvent.modifierFlags.isSuperset(of: cycleModifiers) { finishCycle() }
    }
    func advanceCycle() {
        guard isCycling else { return }
        let generation = cycleGeneration
        pendingCycleSteps += 1
        cycleTask?.cancel()
        cycleTask = Task {
            await service.waitForPresentation(); guard !Task.isCancelled, generation == cycleGeneration, isCycling else { return }
            let steps = pendingCycleSteps; pendingCycleSteps = 0; service.cycleSelection(steps: steps)
        }
    }
    private func finishCycle() {
        isCycling = false
        let generation = cycleGeneration
        cycleTask?.cancel()
        cycleTask = Task {
            await service.waitForPresentation()
            guard !Task.isCancelled, generation == cycleGeneration, isVisible, attachedSheet == nil,
                  (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
            let steps = pendingCycleSteps; pendingCycleSteps = 0; service.cycleSelection(steps: steps)
            await service.copySelected(paste: service.preferences.selectionPastesAutomatically)
        }
    }
    private func cancelCycle(cancelPending: Bool = true) {
        cycleGeneration &+= 1; isCycling = false; cycleModifiers = []; cycleKeyCode = nil; pendingCycleSteps = 0
        if cancelPending { cycleTask?.cancel() }; cycleTask = nil
    }
    func closeAfterSelection() { committedDismissal = true; close(); committedDismissal = false }
    override func resignKey() { cancelCycle(cancelPending: !committedDismissal); super.resignKey() }
    override func close() { cancelCycle(cancelPending: !committedDismissal); super.close(); onDismissed?() }
}

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var service: ClipboardHistoryService
    @State private var showPreferences = false
    @State private var confirmClear = false
    @State private var editingEntry: ClipboardAnnotationSelection?
    @State private var editingContent: ClipboardAnnotationSelection?
    @State private var editingShortcut: ClipboardAnnotationSelection?
    @State private var restoreSelection: ClipboardBackupSelection?
    @FocusState private var searchFocused: Bool
    private var selected: ClipboardEntry? { service.entries.first { $0.id == service.selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("搜索文字、OCR、标签或来源", text: $service.query).textFieldStyle(.plain).focused($searchFocused)
                Toggle("仅收藏", isOn: $service.pinnedOnly).toggleStyle(.checkbox)
                Button { service.togglePause() } label: { Image(systemName: service.paused ? "play.fill" : "pause.fill") }
                    .help(service.paused ? "继续记录" : "暂停记录").disabled(!service.preferences.enabled || service.dataBusy)
                Button { showPreferences = true } label: { Image(systemName: "gearshape") }.disabled(service.dataBusy)
                Button { service.previewVisible.toggle() } label: { Image(systemName: "sidebar.right") }.help("展开或收起预览（Control+Space）")
                Menu {
                    if service.ignoringNextCopy { Button("取消忽略下一次复制") { service.cancelIgnoreNextCopy() } }
                    else { Button("忽略下一次复制") { service.ignoreNextCopy() } }
                } label: { Image(systemName: "eye.slash") }.disabled(!service.preferences.enabled || service.paused)
            }.padding(12)
            HStack(spacing: 12) {
                Picker("类型", selection: $service.kindFilter) {
                    Text("全部").tag(ClipboardKind?.none)
                    Text("文字").tag(ClipboardKind?.some(.text)); Text("图片").tag(ClipboardKind?.some(.image))
                    Text("文件").tag(ClipboardKind?.some(.file)); Text("多项").tag(ClipboardKind?.some(.multiple))
                }.frame(width: 150)
                Picker("来源", selection: $service.sourceFilter) {
                    Text("全部应用").tag("")
                    ForEach(service.sources, id: \.self) { Text(service.sourceName($0)).tag($0) }
                }.frame(maxWidth: 280)
                Picker("标签", selection: $service.tagFilter) {
                    Text("全部标签").tag("")
                    ForEach(service.tags, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if service.needsRecovery {
                HStack { Text("历史数据暂不可读，请选择有效备份恢复。") ; Spacer(); Button("恢复备份…") { chooseBackup() } }.padding(12)
            } else if !service.preferences.enabled {
                HStack { Text("历史记录尚未开启。开启后，内容和文件引用会保存在此 Mac。") ; Spacer(); Button("设置…") { showPreferences = true } }.font(.callout).padding(12)
            } else if service.paused { Text("记录已暂停，已有历史仍可使用。 ").font(.callout).foregroundStyle(.secondary).padding(8) }
            if service.ignoringNextCopy { Text("下一次外部复制将被忽略，之后自动恢复记录。 ").font(.callout).foregroundStyle(.secondary).padding(8) }
            HSplitView {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { service.selectedIDs }, set: { service.setSelection($0) })) {
                        ForEach(service.entries, id: \.id) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(entry.kind))
                                if service.preferences.showSourceIcons, let image = service.sourceIcon(entry.sourceApplication) { Image(nsImage: image).resizable().frame(width: 18, height: 18) }
                                if service.preferences.showColorSwatches, let color = ClipboardHexColor(text: entry.preview) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)).frame(width: 20, height: 20).overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 1))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(entry)).lineLimit(2)
                                    Text(service.sourceName(entry.sourceApplication)).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(entry.sourceApplication)
                                    if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                if let binding = service.pinShortcuts.first(where: { $0.entryId == entry.id }) { Text("⌘\(binding.key.uppercased())").font(.caption).foregroundStyle(.secondary) }
                                else if let index = service.entries.firstIndex(where: { $0.id == entry.id }), index < 9 { Text("⌘\(index + 1)").font(.caption).foregroundStyle(.secondary) }
                                if entry.pinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                                if entry.ocrIndexed { Image(systemName: "text.viewfinder").foregroundStyle(.secondary).help("已建立 OCR 搜索索引") }
                            }.padding(.vertical, 3).tag(entry.id).id(entry.id)
                        }
                        if service.hasMore { Button("加载更多") { Task { await service.reload(loadMore: true) } } }
                    }
                    .onChange(of: service.selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }.frame(minWidth: 280, idealWidth: 340)
                VStack(alignment: .leading, spacing: 10) {
                    if let selected {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if service.previewVisible {
                                if let image = service.previewImage { Image(nsImage: image).resizable().scaledToFit() }
                                if !service.previewText.isEmpty { Text(service.previewText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                if service.selectionHasFiles { Text("保存的是文件引用，原文件需仍在原位置。 ").font(.caption).foregroundStyle(.secondary) }
                                } else { Button("展开内容预览") { service.previewVisible = true } }
                            }
                        }
                        Text(Date(timeIntervalSince1970: Double(selected.copiedAtMs) / 1000), style: .date).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(service.selectedIDs.count > 1 ? "复制所选" : "复制") { Task { await service.copySelected() } }
                            Button("粘贴") { Task { await service.copySelected(paste: true) } }
                            if service.selectionHasPlainText { Button("纯文本粘贴") { Task { await service.copySelected(paste: true, plainTextOnly: true) } } }
                        }
                        HStack {
                            Button(selected.pinned ? "取消收藏" : "收藏") { Task { await service.pinSelected() } }
                            Button("名称和标签…") { editingEntry = ClipboardAnnotationSelection(entry: selected) }
                            Button("删除", role: .destructive) { Task { await service.deleteSelected() } }
                        }
                        if selected.pinned {
                            HStack {
                                Button("固定项快捷键…") { editingShortcut = ClipboardAnnotationSelection(entry: selected) }
                                if selected.kind == .text, !service.selectionHasImages { Button("编辑内容…") { editingContent = ClipboardAnnotationSelection(entry: selected) } }
                            }
                        }
                        HStack {
                            if service.selectionHasImages {
                                Button("贴图") { Task { await service.pinImageSelected() } }
                                Button(service.recognizingText ? "识别中…" : "识别文字") { Task { await service.recognizeTextSelected() } }.disabled(service.recognizingText)
                                Button("二维码") { Task { await service.recognizeCodesSelected() } }
                            }
                            if service.selectionHasPlainText { Button("翻译") { Task { await service.translateSelected() } } }
                        }
                        Button("加入连续粘贴队列（\(service.selectedIDs.count) 条）") { Task { await service.queueSelectedForPaste() } }
                            .help("Command 点击或 Shift 选择多条；每次使用粘贴下一条快捷键发送一条。")
                    } else { ContentUnavailableView("暂无历史", systemImage: "doc.on.clipboard", description: Text("开启记录后复制内容，或尝试其他筛选条件。")) }
                }.padding(12).frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity).disabled(service.dataBusy)
            }
            Divider()
            if service.pasteQueueCount > 0 {
                HStack { Text("连续粘贴：剩余 \(service.pasteQueueCount) 条") ; Button("粘贴下一条") { Task { await service.pasteNextQueued() } }; Button("取消队列") { service.cancelPasteQueue() }; Spacer() }.font(.callout).padding(8)
            }
            HStack {
                Text("\(service.stats.items) 条 · \(ByteCountFormatter.string(fromByteCount: Int64(service.stats.bytes), countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                if service.indexingImages { ProgressView().controlSize(.small); Text("图片索引中").font(.caption) }
                if service.dataBusy { ProgressView().controlSize(.small) }
                Spacer()
                Menu("数据…") {
                    Button("导出备份…") { exportBackup() }.disabled(service.needsRecovery)
                    Button("导入或恢复备份…") { chooseBackup() }
                    Button("重试图片 OCR 索引") { Task { await service.retryImageIndexing() } }.disabled(!service.preferences.ocrSearchEnabled)
                }.disabled(service.dataBusy)
                Button("清理…") { confirmClear = true }.disabled(service.dataBusy || service.needsRecovery)
            }.padding(10).opacity(service.preferences.showFooter ? 1 : 0).frame(height: service.preferences.showFooter ? nil : 0).clipped().allowsHitTesting(service.preferences.showFooter).accessibilityHidden(!service.preferences.showFooter)
            if !service.statusMessage.isEmpty { Text(service.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(.horizontal, 10).padding(.bottom, 8) }
        }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardFocusSearch)) { _ in searchFocused = true }
        .background {
            Group {
                Button("") { Task { await service.copySelected(paste: true) } }.keyboardShortcut(.return, modifiers: [.option])
                Button("") { Task { await service.copySelected(paste: true, plainTextOnly: true) } }.keyboardShortcut(.return, modifiers: [.option, .shift])
                Button("") { Task { await service.pinSelected() } }.keyboardShortcut("p", modifiers: [.option])
                Button("") { Task { await service.deleteSelected() } }.keyboardShortcut(.delete, modifiers: [.option])
            }.hidden().disabled(selected == nil || service.dataBusy)
        }
        .sheet(isPresented: $showPreferences) { ClipboardHistoryPreferencesView(service: service) }
        .sheet(isPresented: $confirmClear) { ClipboardClearView(service: service) }
        .sheet(item: $editingEntry) { ClipboardAnnotationView(service: service, entry: $0.entry) }
        .sheet(item: $editingContent) { ClipboardContentEditorView(service: service, entry: $0.entry) }
        .sheet(item: $editingShortcut) { ClipboardPinShortcutView(service: service, entry: $0.entry) }
        .sheet(item: $restoreSelection) { ClipboardRestoreView(service: service, selection: $0) }
        .alert("剪贴板历史", isPresented: Binding(get: { service.errorMessage != nil }, set: { if !$0 { service.errorMessage = nil } })) { Button("好") { service.errorMessage = nil } } message: { Text(service.errorMessage ?? "") }
    }
    private func title(_ entry: ClipboardEntry) -> String {
        if !entry.title.isEmpty { return entry.title }
        switch entry.kind {
        case .image: return "图片"
        case .multiple: return "\(entry.itemCount) 项：\(entry.preview)"
        default: return entry.preview
        }
    }
    private func icon(_ kind: ClipboardKind) -> String {
        switch kind { case .text: return "text.alignleft"; case .image: return "photo"; case .file: return "doc"; case .multiple: return "square.stack" }
    }
    private func exportBackup() {
        let panel = NSSavePanel(); panel.title = "导出剪贴板历史备份"
        panel.message = "备份包含原始剪贴板内容，未加密。文件历史只保存引用。"
        panel.allowedContentTypes = [UTType(filenameExtension: "polyclipboard") ?? .data]
        panel.nameFieldStringValue = "Polyglance-Clipboard.polyclipboard"
        if panel.runModal() == .OK, let url = panel.url { Task { await service.exportBackup(to: url) } }
    }
    private func chooseBackup() {
        let panel = NSOpenPanel(); panel.title = "选择剪贴板历史备份"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { if let info = await service.inspectBackup(at: url) { restoreSelection = ClipboardBackupSelection(url: url, info: info) } }
        }
    }
}

private struct ClipboardAnnotationSelection: Identifiable { let entry: ClipboardEntry; var id: UInt64 { entry.id } }
private struct ClipboardBackupSelection: Identifiable { let id = UUID(); let url: URL; let info: ClipboardBackupInfo }

@MainActor
private struct ClipboardContentEditorView: View {
    @ObservedObject var service: ClipboardHistoryService
    let entry: ClipboardEntry
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var loaded = false
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑固定内容").font(.headline)
            Text("保存为纯文本，保留名称、标签和快捷键。原有 HTML / RTF 格式会移除。 ").font(.callout).foregroundStyle(.secondary)
            if loaded { TextEditor(text: $content).font(.system(.body, design: .monospaced)).frame(minHeight: 260) }
            else { ProgressView() }
            if let error = service.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { saving = true; Task { if await service.editPinnedText(id: entry.id, text: content) { dismiss() }; saving = false } }.disabled(!loaded || saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 580)
        .task { if let text = await service.editableText(id: entry.id), !Task.isCancelled { content = text; loaded = true } }
    }
}

@MainActor
private struct ClipboardPinShortcutView: View {
    @ObservedObject var service: ClipboardHistoryService
    let entry: ClipboardEntry
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("固定项快捷键").font(.headline)
            Picker("快捷键", selection: $key) {
                Text("未分配").tag("")
                ForEach(Array("bdegijklrtuy").map(String.init), id: \.self) { key in
                    Text("Command+\(key.uppercased())").tag(key)
                }
            }
            Text("在历史窗口内生效。Option+对应字母直接粘贴，Option+Shift+对应字母粘贴纯文本。常见编辑快捷键已保留。 ").font(.callout).foregroundStyle(.secondary)
            if let error = service.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { saving = true; Task { if await service.assignPinShortcut(id: entry.id, key: key) { dismiss() }; saving = false } }.disabled(saving).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440)
        .onAppear { key = service.pinShortcuts.first(where: { $0.entryId == entry.id })?.key ?? "" }
    }
}

@MainActor
private struct ClipboardAnnotationView: View {
    @ObservedObject var service: ClipboardHistoryService
    let entry: ClipboardEntry
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var tags: String
    @State private var saving = false
    init(service: ClipboardHistoryService, entry: ClipboardEntry) { self.service = service; self.entry = entry; _title = State(initialValue: entry.title); _tags = State(initialValue: entry.tags.joined(separator: ", ")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("名称和标签").font(.headline)
            TextField("名称（留空使用内容摘要）", text: $title)
            TextField("标签，用逗号分隔", text: $tags)
            Text("最多 20 个标签。名称和标签会参与搜索。 ").font(.caption).foregroundStyle(.secondary)
            if let error = service.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { let values = tags.split { $0 == "," || $0 == "，" }.map(String.init); saving = true
                    Task { if await service.rename(id: entry.id, title: title, tags: values) { dismiss() }; saving = false }
                }.disabled(saving).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420)
    }
}
@MainActor
private struct ClipboardClearView: View {
    @ObservedObject var service: ClipboardHistoryService
    @Environment(\.dismiss) private var dismiss
    @State private var includePinned = false
    @State private var preview: ClipboardClearPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("清理剪贴板历史").font(.headline)
            Toggle("同时删除收藏", isOn: $includePinned)
            if let preview { Text("当前预计删除 \(preview.items) 条，其中收藏 \(preview.pinnedItems) 条，内容约 \(ByteCountFormatter.string(fromByteCount: Int64(preview.bytes), countStyle: .file))。") }
            else { ProgressView() }
            Text("删除后无法恢复。系统当前剪贴板内容会保留。 ").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("删除", role: .destructive) { let include = includePinned; dismiss(); Task { await service.clear(includePinned: include) } }.disabled(preview == nil || preview?.items == 0)
            }
        }.padding(24).frame(width: 400)
        .task(id: includePinned) { let value = await service.clearPreview(includePinned: includePinned); if !Task.isCancelled { preview = value } }
    }
}
@MainActor
private struct ClipboardRestoreView: View {
    @ObservedObject var service: ClipboardHistoryService
    let selection: ClipboardBackupSelection
    @Environment(\.dismiss) private var dismiss
    @State private var mode = ClipboardRestoreMode.merge
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入剪贴板历史").font(.headline)
            Text("备份中有 \(selection.info.items) 条记录，包含 \(selection.info.pinnedItems) 条收藏。")
            if service.needsRecovery { Text("将恢复可读的历史，并保留当前损坏数据库的副本。 ") }
            else { Picker("导入方式", selection: $mode) { Text("合并到现有历史").tag(ClipboardRestoreMode.merge); Text("替换现有历史").tag(ClipboardRestoreMode.replace) }.pickerStyle(.radioGroup) }
            Text("合并会保留现有名称并合并标签；替换会删除现有历史。导入后仍按当前容量和保留时间清理非收藏记录。 ").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(service.needsRecovery || mode == .replace ? "确认替换并恢复" : "确认合并") {
                    let mode: ClipboardRestoreMode = service.needsRecovery ? .replace : self.mode
                    dismiss(); Task { await service.importBackup(from: selection.url, mode: mode) }
                }
            }
        }.padding(24).frame(width: 460)
    }
}
@MainActor
private struct ClipboardHistoryPreferencesView: View {
    @ObservedObject var service: ClipboardHistoryService
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ClipboardHistoryPreferences()
    @State private var ignoredApplications = ""
    @State private var ignoredTypes = ""
    @State private var ignoredPatterns = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView { VStack(alignment: .leading, spacing: 14) {
            Text("剪贴板历史设置").font(.headline)
            Toggle("在本机保存复制内容和文件引用", isOn: $draft.enabled)
            Text("内容不会自动上传。无敏感标记的密码仍可能被记录，请排除相关应用或暂停。关闭记录会保留已有历史。 ").font(.callout).foregroundStyle(.secondary)
            Toggle("为历史图片建立 OCR 搜索索引（本机识别）", isOn: $draft.ocrSearchEnabled)
            Text("开启后会逐张处理已有和新复制的图片。关闭后停止后台处理，已有索引保留。 ").font(.caption).foregroundStyle(.secondary)
            Stepper("最多 \(draft.maximumItems) 条（包含收藏）", value: $draft.maximumItems, in: 100...10000, step: 100)
            Stepper("内容容量 \(draft.maximumMegabytes) MB", value: $draft.maximumMegabytes, in: 16...2048, step: 16)
            Stepper("保留 \(draft.retentionDays) 天（0 为不限，收藏不过期）", value: $draft.retentionDays, in: 0...3650)
            Text("忽略的应用 Bundle ID，每行一个").font(.callout)
            TextEditor(text: $ignoredApplications).font(.system(.body, design: .monospaced)).frame(height: 70)
            Text("额外忽略的剪贴板类型，每行一个").font(.callout)
            TextEditor(text: $ignoredTypes).font(.system(.body, design: .monospaced)).frame(height: 45)
            Text("内容排除表达式，每行一条").font(.callout)
            TextEditor(text: $ignoredPatterns).font(.system(.body, design: .monospaced)).frame(height: 65)
            Text("最多 32 条。匹配任意文字项时忽略整次复制；规则只作用于新记录。支持中文原文，\\d / \\w 使用 ASCII 范围；不支持环视和回溯引用。 ").font(.caption).foregroundStyle(.secondary)
            Toggle("系统剪贴板清空时移除对应历史记录", isOn: $draft.purgeClearedContent)
            Text("适用于密码管理器定时清空，也适用于手动清空。仅移除最后一次对应记录，包括该记录的收藏；已编辑或重新复制的记录会保留。 ").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("打开历史时自动展开预览", isOn: $draft.autoPreview)
            Toggle("显示 HEX 颜色色块", isOn: $draft.showColorSwatches)
            Toggle("显示来源应用图标", isOn: $draft.showSourceIcons)
            Toggle("显示底部容量与数据菜单", isOn: $draft.showFooter)
            Divider()
            Toggle("按住呼出快捷键的修饰键循环选择，松开后确认", isOn: $draft.cycleSelectionEnabled)
            Toggle("Enter、数字选择和循环确认后自动粘贴", isOn: $draft.selectionPastesAutomatically)
            Text("Command+1…9 选择前九条；Option+1…9 粘贴，Option+Shift+1…9 粘贴纯文本。固定项可单独设置字母快捷键。自动粘贴需辅助功能权限。 ").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("记录新复制内容时发送通知", isOn: $draft.notifyCopies)
            Toggle("从历史复制内容时发送通知", isOn: $draft.notifySelections)
            Text("通知不显示原文，连续操作会合并提醒。 ").font(.caption).foregroundStyle(.secondary)
            ShortcutsLink()
            }}.frame(maxHeight: 570)
            if let error = service.errorMessage { Text(error).font(.callout).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    draft.ignoredApplications = ignoredApplications.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft.ignoredTypes = ignoredTypes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    draft.ignoredPatterns = ignoredPatterns.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    saving = true
                    Task { await service.savePreferences(draft); saving = false; if service.preferences == draft { dismiss() } }
                }.disabled(saving).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
        .onAppear { draft = service.preferences; ignoredApplications = draft.ignoredApplications.joined(separator: "\n"); ignoredTypes = draft.ignoredTypes.joined(separator: "\n"); ignoredPatterns = draft.ignoredPatterns.joined(separator: "\n") }
    }
}
