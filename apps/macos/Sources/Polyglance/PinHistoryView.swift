import AppKit
import SwiftUI

@MainActor
final class PinHistoryViewModel: ObservableObject {
    @Published private(set) var items: [PinArchiveItem] = []
    @Published var selectedItemID: String?
    @Published var showClearConfirmation: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var thumbnailCache: [String: NSImage] = [:]

    let archiveStore: PinArchiveStore
    let onPinItem: (NSImage) -> Void
    var onPinContent: ((NSImage, String, String?) -> Void)?

    private var currentGeneration: Int = 0
    private var cachedBytes: Int64 = 0
    private var cacheKeysByAccess: [String] = []
    private let maxCacheBytes: Int64 = 32 * 1024 * 1024
    private var loadingItemIDs = Set<String>()

    init(
        archiveStore: PinArchiveStore,
        onPinItem: @escaping (NSImage) -> Void
    ) {
        self.archiveStore = archiveStore
        self.onPinItem = onPinItem
    }

    func reload() async {
        currentGeneration += 1
        let generation = currentGeneration
        let loaded = await archiveStore.perform { $0.list() }
        guard generation == currentGeneration else { return }
        items = loaded
        resetCache()
        if let selectedItemID, !items.contains(where: { $0.id == selectedItemID }) {
            self.selectedItemID = items.first?.id
        } else if selectedItemID == nil {
            self.selectedItemID = items.first?.id
        }
        errorMessage = nil
    }

    func resetCache() {
        currentGeneration += 1
        thumbnailCache.removeAll(keepingCapacity: false)
        cachedBytes = 0
        cacheKeysByAccess.removeAll()
        loadingItemIDs.removeAll()
    }

    func select(_ id: String) {
        selectedItemID = id
    }

    func thumbnail(for item: PinArchiveItem) -> NSImage? {
        if let cached = thumbnailCache[item.id] {
            // Touch access order
            if let idx = cacheKeysByAccess.firstIndex(of: item.id) {
                cacheKeysByAccess.remove(at: idx)
            }
            cacheKeysByAccess.append(item.id)
            return cached
        }

        requestThumbnailLoad(for: item)
        return nil
    }

    private func requestThumbnailLoad(for item: PinArchiveItem) {
        guard !loadingItemIDs.contains(item.id) else { return }
        loadingItemIDs.insert(item.id)
        let generation = currentGeneration
        let store = archiveStore

        Task.detached(priority: .userInitiated) {
            let thumb = await store.perform { $0.loadThumbnail(id: item.id, maxPixelDimension: 480) }
            await MainActor.run { [weak self] in
                guard let self, self.currentGeneration == generation else { return }
                self.loadingItemIDs.remove(item.id)
                guard let thumb else { return }
                self.storeThumbnail(thumb, for: item.id)
            }
        }
    }

    private func storeThumbnail(_ image: NSImage, for id: String) {
        let rep = image.representations.first
        let width = rep?.pixelsWide ?? Int(image.size.width)
        let height = rep?.pixelsHigh ?? Int(image.size.height)
        let bytes = Int64(max(1, width) * max(1, height) * 4)

        thumbnailCache[id] = image
        cacheKeysByAccess.append(id)
        cachedBytes += bytes

        // Evict oldest until within budget
        while cachedBytes > maxCacheBytes, !cacheKeysByAccess.isEmpty {
            let oldestKey = cacheKeysByAccess.removeFirst()
            if oldestKey != id, let evicted = thumbnailCache.removeValue(forKey: oldestKey) {
                let eRep = evicted.representations.first
                let eW = eRep?.pixelsWide ?? Int(evicted.size.width)
                let eH = eRep?.pixelsHigh ?? Int(evicted.size.height)
                cachedBytes -= Int64(max(1, eW) * max(1, eH) * 4)
            }
        }
    }

    func pinSelected() async {
        guard let id = selectedItemID else { return }
        await pinItem(id: id)
    }

    func pinItem(id: String) async {
        guard let image = await archiveStore.perform({ $0.loadImage(id: id) }) else {
            errorMessage = "未能读取贴图图片文件"
            return
        }
        if let onPinContent {
            let text = await archiveStore.perform { $0.loadSessions().first(where: { $0.archiveID == id })?.text }
            onPinContent(image, id, text)
        } else { onPinItem(image) }
    }

    func deleteSelected() async {
        guard let id = selectedItemID else { return }
        let result = await archiveStore.perform { $0.delete(id: id) }
        if case let .failed(msg) = result {
            errorMessage = msg
            return
        }
        thumbnailCache.removeValue(forKey: id)
        await reload()
    }

    func clearAll() async {
        let result = await archiveStore.perform { $0.deleteAll() }
        await reload()
        errorMessage = result.errorMessage
    }
}

struct PinHistoryView: View {
    @ObservedObject var viewModel: PinHistoryViewModel

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if viewModel.items.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(viewModel.items) { item in
                            PinHistoryCard(
                                item: item,
                                isSelected: viewModel.selectedItemID == item.id,
                                image: viewModel.thumbnail(for: item),
                                dateString: Self.dateFormatter.string(from: item.createdAt),
                                onSelect: { viewModel.select(item.id) },
                                onDoubleTap: { Task { await viewModel.pinItem(id: item.id) } }
                            )
                        }
                    }
                    .padding(16)
                }
            }

            Divider()
            footerBar
        }
        .frame(minWidth: 640, minHeight: 460)
        .confirmationDialog(
            "确定要清空全部贴图历史吗？",
            isPresented: $viewModel.showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空全部", role: .destructive) {
                Task { await viewModel.clearAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作将删除本地历史图片、文本原文和恢复记录，无法撤销。已打开的窗口可继续显示，但关闭后不能恢复。")
        }
        .onDisappear {
            viewModel.resetCache()
        }
    }

    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("贴图历史")
                    .font(.headline)
                Text("(\(viewModel.items.count))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("暂无贴图历史")
                .font(.headline)
                .foregroundColor(.primary)
            Text("贴图始终自动入库；截图复制与保存自动记录可在设置中开启")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    viewModel.showClearConfirmation = true
                } label: {
                    Text("清空全部…")
                }
            // Keep clear available when only quarantined or failed-to-delete files remain.

                Spacer()

                Button {
                    Task { await viewModel.deleteSelected() }
                } label: {
                    Text("删除")
                }
                .disabled(viewModel.selectedItemID == nil)

                Button {
                    Task { await viewModel.pinSelected() }
                } label: {
                    Text("贴出")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedItemID == nil)
                .keyboardShortcut(.defaultAction)
            }

            HStack {
                Text("历史仅保存在本机（图片最多 30 条 / 512 MiB）。删除历史会清除关联原文和恢复记录，已打开的窗口可继续显示。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct PinHistoryCard: View {
    let item: PinArchiveItem
    let isSelected: Bool
    let image: NSImage?
    let dateString: String
    let onSelect: () -> Void
    let onDoubleTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 120)
            .clipped()
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.source.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(4)
                    Spacer()
                    Text("\(item.pixelWidth) × \(item.pixelHeight)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text(dateString)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onDoubleTap()
            }
        )
    }
}
