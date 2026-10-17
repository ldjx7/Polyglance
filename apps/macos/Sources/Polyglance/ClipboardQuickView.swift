import AppKit
import SwiftUI
import TranslatorCore

/// Keep the list under the pointer while opening details toward the available space.
@MainActor
final class ClipboardQuickLayout: ObservableObject {
    static let listWidth: CGFloat = 450
    @Published private(set) var previewOnLeft = false
    @Published private(set) var previewWidth: CGFloat = 320
    private var previewIsVisible = false

    func reset() { previewIsVisible = false; previewOnLeft = false; previewWidth = 320 }

    func frame(showingPreview: Bool, current: NSRect, screen: NSRect) -> NSRect {
        let listX = current.minX + (previewIsVisible && previewOnLeft ? previewWidth : 0)
        if showingPreview && !previewIsVisible {
            previewWidth = min(320, max(0, screen.width - Self.listWidth))
            let rightSpace = screen.maxX - (listX + Self.listWidth)
            let leftSpace = listX - screen.minX
            previewOnLeft = rightSpace < previewWidth && leftSpace > rightSpace
        }
        let width = Self.listWidth + (showingPreview ? previewWidth : 0)
        let x = listX - (showingPreview && previewOnLeft ? previewWidth : 0)
        previewIsVisible = showingPreview
        return NSRect(x: min(max(x, screen.minX), max(screen.minX, screen.maxX - width)),
                      y: min(max(current.minY, screen.minY), max(screen.minY, screen.maxY - current.height)),
                      width: width, height: min(current.height, screen.height))
    }
}

@MainActor
struct ClipboardQuickView: View {
    @ObservedObject var service: ClipboardHistoryService
    @ObservedObject var layout: ClipboardQuickLayout
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if service.previewVisible && layout.previewOnLeft { details.overlay(alignment: .trailing) { Divider() } }
            list.frame(width: ClipboardQuickLayout.listWidth)
            if service.previewVisible && !layout.previewOnLeft { details.overlay(alignment: .leading) { Divider() } }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .ignoresSafeArea()
        .onAppear { searchFocused = true }
        .onChange(of: service.searchFocusRequest) { _, _ in searchFocused = true }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Color.accentColor)
                Text("剪贴板").font(.headline)
                Spacer()
                Button { service.togglePreview() } label: { Image(systemName: "sidebar.right") }
                    .help("显示或收起详情（Control+Space）").accessibilityLabel("显示或收起详情")
                Button { service.openManagement() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("管理历史（Command+M）").accessibilityLabel("管理历史")
            }
            .buttonStyle(.borderless).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索剪贴板历史", text: $service.query)
                    .textFieldStyle(.plain).focused($searchFocused).font(.body)
                if !service.query.isEmpty {
                    Button { service.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空搜索")
                }
            }
            .padding(11).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
            .padding(.horizontal, 12)
            status
            HStack {
                Text(service.query.isEmpty ? "最近记录" : "搜索结果")
                Spacer()
                Text("\(service.entries.count)\(service.hasMore ? "+" : "") 条")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(service.entries, id: \.id) { entry in row(entry) }
                        if service.hasMore {
                            Button("加载更多") { Task { await service.reload(loadMore: true) } }.buttonStyle(.borderless).padding(10)
                        }
                        if service.entries.isEmpty {
                            ContentUnavailableView("暂无匹配记录", systemImage: "doc.on.clipboard",
                                                   description: Text("复制新内容，或尝试其他搜索词。"))
                        }
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                }
                // Hover changes the highlight without scrolling the row under the pointer.
                .onChange(of: service.selectionScrollRequest) { _, _ in
                    if let id = service.selectedID { proxy.scrollTo(id) }
                }
            }
            if let error = service.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).frame(maxWidth: .infinity, alignment: .leading)
                    Button { service.errorMessage = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
                }.font(.caption).foregroundStyle(.red).buttonStyle(.plain).padding(12)
            }
            Divider().padding(.horizontal, 12)
            HStack {
                Text(ClipboardSelectionAction.hint(automaticPaste: service.preferences.selectionPastesAutomatically))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 6)
                Button("管理历史") { service.openManagement() }.buttonStyle(.borderless).font(.caption)
            }.padding(.horizontal, 14).padding(.vertical, 11)
        }
    }

    @ViewBuilder private var status: some View {
        if !service.preferences.enabled {
            HStack {
                Label("历史记录尚未开启", systemImage: "pause.circle")
                Spacer()
                Button("前往通用设置") { service.onOpenGeneralSettings?() }.buttonStyle(.borderless)
            }.font(.caption).padding(.horizontal, 16).padding(.top, 10)
        } else if service.paused {
            Text("记录已暂停，已有历史仍可使用").font(.caption).foregroundStyle(.secondary).padding(.top, 10)
        }
        if service.needsRecovery {
            Button("历史暂不可读，前往管理窗口恢复") { service.openManagement() }.padding(10)
        }
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = service.selectedID == entry.id
        return Button {
            let modifiers = NSEvent.modifierFlags
            Task { await service.activateEntry(entry.id, modifiers: modifiers) }
        } label: {
            HStack(spacing: 11) {
                ClipboardEntryThumbnail(service: service, entry: entry,
                                        fallbackSymbol: entry.kind.clipboardSymbol,
                                        sourceIcon: service.preferences.showSourceIcons ? service.sourceIcon(entry.sourceApplication) : nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.clipboardDisplayTitle).font(.system(size: 13, weight: selected ? .medium : .regular))
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 5) {
                        if entry.pinned { Image(systemName: "pin.fill") }
                        Text(service.sourceName(entry.sourceApplication)).lineLimit(1)
                        Text("·")
                        Text(entry.kind.clipboardLabel)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let shortcut = service.shortcutLabel(for: entry) {
                    Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor.opacity(0.2) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).id(entry.id).disabled(service.dataBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onContinuousHover { phase in
            switch phase {
            case .active: service.hoverEntry(entry.id, at: NSEvent.mouseLocation)
            case .ended: service.endHover(entry.id)
            }
        }
    }

    private var details: some View {
        ClipboardQuickDetailsView(service: service).frame(width: layout.previewWidth)
    }
}

@MainActor
struct ClipboardEntryThumbnail: View {
    let service: ClipboardHistoryService
    let entry: ClipboardEntry
    let fallbackSymbol: String
    let sourceIcon: NSImage?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.7))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            } else if let sourceIcon {
                Image(nsImage: sourceIcon).resizable().scaledToFit().padding(6)
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.06)))
        .accessibilityHidden(true)
        .task(id: "\(entry.id):\(entry.copiedAtMs)") {
            image = nil
            let loaded = await service.thumbnail(for: entry)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .onDisappear { image = nil }
    }
}

@MainActor
private struct ClipboardQuickDetailsView: View {
    @ObservedObject var service: ClipboardHistoryService
    private var selected: ClipboardEntry? { service.entries.first { $0.id == service.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("记录详情").font(.headline)
                Spacer()
                Button { service.togglePreview() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("收起详情")
            }
            if let entry = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !entry.title.isEmpty { Text(entry.title).font(.headline).textSelection(.enabled) }
                        if service.previewLoading {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        } else {
                            if let image = service.previewImage {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            if !service.previewText.isEmpty {
                                Text(service.previewText).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if service.selectionHasFiles {
                                Label("文件需保留在原位置", systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.id(entry.id)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    metadata("来源", service.sourceName(entry.sourceApplication))
                    metadata("类型", entry.kind.clipboardLabel)
                    metadata("复制于", Date(timeIntervalSince1970: Double(entry.copiedAtMs) / 1000)
                        .formatted(date: .abbreviated, time: .shortened))
                    metadata("大小", ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.byteCount), countStyle: .file))
                    if !entry.tags.isEmpty { metadata("标签", entry.tags.joined(separator: " · ")) }
                }.font(.caption)
                if entry.ocrIndexed { Label("可搜索图片中的文字", systemImage: "text.viewfinder").font(.caption).foregroundStyle(.secondary) }
            } else {
                ContentUnavailableView("选择一条记录", systemImage: "doc.text.magnifyingglass")
            }
        }.padding(18).frame(maxHeight: .infinity, alignment: .top).background(.background.opacity(0.45))
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
}

private extension ClipboardEntry {
    var clipboardDisplayTitle: String {
        if !title.isEmpty { return title }
        switch kind {
        case .image: return "图片"
        case .multiple: return "\(itemCount) 项：\(preview)"
        default: return preview
        }
    }
}

private extension ClipboardKind {
    var clipboardSymbol: String {
        switch self { case .text: return "text.alignleft"; case .image: return "photo"; case .file: return "doc"; case .multiple: return "square.stack" }
    }
    var clipboardLabel: String {
        switch self { case .text: return "文字"; case .image: return "图片"; case .file: return "文件"; case .multiple: return "多项内容" }
    }
}
