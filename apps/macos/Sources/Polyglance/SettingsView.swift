import ApplicationServices
import CoreGraphics
import PolyglanceKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let store: AppConfigurationStore
    let shortcutStore: GlobalShortcutConfigurationStore
    let recordingSettingsStore: RecordingSettingsStore
    let launchAtLoginManager: LaunchAtLoginManager
    let onSave: (
        AppConfiguration,
        GlobalShortcutConfiguration,
        RecordingSettings,
        Bool
    ) throws -> Void

    @State private var selectedTab: SettingsTab = .general
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var provider = TranslationProvider.microsoft
    @State private var aiStreamingEnabled = true
    @State private var targetLanguage = "zh-CN"
    @State private var shortcuts = GlobalShortcutConfiguration.default
    @State private var recordingSettings = RecordingSettings.default
    @State private var launchAtLoginEnabled = false
    @State private var includeBetaUpdates = false
    @State private var autoCheckUpdates = true
    @State private var screenshotToolbarItems = ScreenshotToolbarItemConfig.defaultItems
    @State private var draggingItemID: String? = nil
    @State private var statusMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            detailView
        }
        .frame(width: 840, height: 580)
        .task { load() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 34)

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.14), radius: 3, x: 0, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(SettingsBranding.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(SettingsBranding.tagline)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(SettingsBranding.name)，\(SettingsBranding.tagline)")
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .padding(.horizontal, 12)

            VStack(spacing: 3) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarNavItem(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)

            Spacer()
        }
        .frame(width: 190)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var detailView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTab.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.primary)
                    Text(selectedTab.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .services:
                    translationServicesTab
                case .shortcuts:
                    shortcutsTab
                case .recording:
                    recordingTab
                case .toolbar:
                    toolbarTab
                case .about:
                    aboutTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存设置") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Tabs

    private var generalTab: some View {
        Form {
            Section {
                Toggle("登录时自动启动 Polyglance", isOn: $launchAtLoginEnabled)

                HStack {
                    Text("由 macOS 系统登录项管理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开登录项设置") {
                        launchAtLoginManager.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("启动")
            }
        }
        .formStyle(.grouped)
    }

    private var translationServicesTab: some View {
        Form {
            Section {
                Picker("默认翻译服务", selection: $provider) {
                    ForEach(TranslationProvider.allCases, id: \.self) { p in
                        Text(providerLabel(p))
                            .tag(p)
                            .disabled(!isProviderAvailable(p))
                    }
                }
                .pickerStyle(.menu)

                Picker("默认目标语言", selection: $targetLanguage) {
                    Text("简体中文").tag("zh-CN")
                    Text("英语").tag("en")
                    Text("日语").tag("ja")
                    Text("韩语").tag("ko")
                    Text("法语").tag("fr")
                    Text("德语").tag("de")
                }
                .pickerStyle(.menu)
            } header: {
                Text("基础偏好")
            }

            Section {
                switch provider {
                case .google:
                    Text("无需配置 API Key。使用 Google 免费接口，直接发起翻译。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .microsoft:
                    Text("无需配置 API Key。使用 Microsoft Edge 免费翻译接口，稳定可靠。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .freeAI:
                    if BundledFreeAIConfiguration() == nil {
                        Text("当前配置的免费 AI 服务地址不可用。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("无需配置 API Key。使用内置分发的免费 AI 翻译服务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .openAICompatible:
                    TextField("Endpoint", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("模型名称 (如 deepseek-chat)", text: $model)
                        .textFieldStyle(.roundedBorder)
                }

                if provider == .freeAI || provider == .openAICompatible {
                    Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)
                }
            } header: {
                Text("服务详情配置")
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            Section {
                ForEach(GlobalShortcutAction.allCases, id: \.self) { action in
                    LabeledContent {
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { shortcuts[action] },
                                set: { shortcuts[action] = $0 }
                            )
                        )
                        .frame(width: 140, height: 26)
                    } label: {
                        Label(action.title, systemImage: iconForShortcutAction(action))
                    }
                }
            } header: {
                HStack {
                    Text("全局快捷键")
                    Spacer()
                    Button("恢复默认") {
                        shortcuts = .default
                        statusMessage = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }

            Section {
                LabeledContent("翻译输入内容", value: "⌘ ↩︎")
                LabeledContent("复制译文", value: "⇧ ⌘ C")
                LabeledContent("清空并聚焦原文", value: "⌘ K")
            } header: {
                Text("主窗口内快捷键（固定）")
            }
        }
        .formStyle(.grouped)
    }

    private var recordingTab: some View {
        Form {
            Section {
                HStack {
                    Label("辅助功能权限", systemImage: "hand.raised")
                    Spacer()
                    Button("检查/请求权限") {
                        SelectedTextReader().requestAccessibilityPermission()
                    }
                    .controlSize(.small)
                }

                HStack {
                    Label("屏幕录制权限", systemImage: "rectangle.inset.filled.and.cursorarrow")
                    Spacer()
                    Button("检查/请求权限") {
                        _ = CGRequestScreenCaptureAccess()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("系统权限")
            }

            Section {
                Picker("默认格式", selection: recordingFormatBinding) {
                    ForEach(ScreenRecordingFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Picker("默认质量", selection: $recordingSettings.quality) {
                    ForEach(ScreenRecordingQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }

                Picker("默认帧率", selection: recordingFrameRateBinding) {
                    ForEach(
                        ScreenRecordingFrameRatePolicy.choices(for: recordingSettings.format),
                        id: \.self
                    ) { frameRate in
                        Text("\(frameRate) FPS").tag(frameRate)
                    }
                }

                Picker("录制倒计时", selection: $recordingSettings.countdownDelay) {
                    ForEach(ScreenRecordingDelay.allCases, id: \.self) { delay in
                        Text(delay.displayName).tag(delay)
                    }
                }

                Toggle(
                    RecordingSettingsPresentation.saveLocationToggleTitle,
                    isOn: $recordingSettings.asksForSaveLocation
                )

                LabeledContent("保存目录") {
                    HStack(spacing: 6) {
                        Text(recordingDirectoryDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…") {
                            chooseRecordingDirectory()
                        }
                        .controlSize(.small)
                    }
                }

                Toggle("录制系统声音", isOn: $recordingSettings.capturesSystemAudio)
                    .disabled(!recordingSettings.format.supportsAudio)
                Toggle("录制麦克风", isOn: $recordingSettings.capturesMicrophone)
                    .disabled(!recordingSettings.format.supportsAudio)
                Toggle("显示鼠标指针", isOn: $recordingSettings.showsCursor)
            } header: {
                Text("录屏参数")
            }
        }
        .formStyle(.grouped)
    }

    private var toolbarTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("生效工具栏")
                                .font(.headline)
                            Text("实时展示当前截图工具栏排布。支持直接拖拽图标排序，点击可快速移除。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复默认设置") {
                            screenshotToolbarItems = ScreenshotToolbarItemConfig.defaultItems
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }

                    HStack {
                        Spacer()
                        let visibleItems = screenshotToolbarItems.filter(\.isVisible)
                        if visibleItems.isEmpty {
                            Text("未启用任何工具（截图时将自动回退为默认全量工具栏）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        } else {
                            HStack(spacing: 3) {
                                ForEach(visibleItems, id: \.id) { item in
                                    let info = toolbarItemInfos[item.id] ?? (item.id, "circle")
                                    ToolbarCapsuleItemView(
                                        item: item,
                                        info: info,
                                        isDragging: draggingItemID == item.id
                                    ) {
                                        if let idx = screenshotToolbarItems.firstIndex(where: { $0.id == item.id }) {
                                            screenshotToolbarItems[idx].isVisible = false
                                        }
                                    }
                                    .onDrag {
                                        self.draggingItemID = item.id
                                        return NSItemProvider(object: item.id as NSString)
                                    } preview: {
                                        Image(systemName: info.icon)
                                            .font(.system(size: 12.5, weight: .medium))
                                            .frame(width: 26, height: 26)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                            )
                                            .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                                    }
                                    .onDrop(of: [.text], delegate: ToolbarDropDelegate(
                                        targetItem: item,
                                        items: $screenshotToolbarItems,
                                        draggingItem: $draggingItemID
                                    ))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color(NSColor.controlBackgroundColor))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
                        }
                        Spacer()
                    }
                    .frame(height: 46)
                    .padding(.vertical, 4)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("功能储备池")
                        .font(.headline)
                    Text("点击卡片快速启用或停用工具栏按钮。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ], spacing: 8) {
                        ForEach(screenshotToolbarItems, id: \.id) { item in
                            let info = toolbarItemInfos[item.id] ?? (item.id, "circle")
                            let isEnabled = item.isVisible
                            Button {
                                if let idx = screenshotToolbarItems.firstIndex(where: { $0.id == item.id }) {
                                    screenshotToolbarItems[idx].isVisible.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: info.icon)
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)

                                    Text(info.title)
                                        .font(.system(size: 12, weight: isEnabled ? .medium : .regular))
                                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                                        .lineLimit(1)

                                    Spacer(minLength: 2)

                                    if isEnabled {
                                        Image(systemName: "checkmark.square.fill")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Image(systemName: "square")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.secondary.opacity(0.4))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isEnabled ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.03))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isEnabled ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onDrop(of: [.text], isTargeted: nil) { _ in
            draggingItemID = nil
            return false
        }
    }

    private var aboutTab: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 52, height: 52)
                        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Polyglance")
                                .font(.system(size: 16, weight: .bold))
                            let isBeta = AppVersionInfo.versionString.contains("-beta")
                            Text(isBeta ? "Beta 尝鲜" : "正式版")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isBeta ? Color.purple.opacity(0.15) : Color.green.opacity(0.15))
                                .foregroundStyle(isBeta ? Color.purple : Color.green)
                                .clipShape(Capsule())
                        }

                        Text("版本 \(AppVersionInfo.displayString)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("检查更新") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("版本信息")
            }

            Section {
                Toggle("启动时自动检查更新", isOn: $autoCheckUpdates)
                Toggle("接收测试版更新 (Beta Channel)", isOn: $includeBetaUpdates)
                Text("开启后优先接收包含实验性新特性的测试版本；关闭后仅接收经过充分测试的正式版本。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("更新设置")
            }

            Section {
                LabeledContent("核心架构", value: "Rust (UniFFI)")
                LabeledContent("用户界面", value: "Native SwiftUI")
                LabeledContent("项目主页") {
                    Link("GitHub 仓库", destination: URL(string: "https://github.com/ldjx7/Polyglance")!)
                        .font(.system(size: 12))
                }
            } header: {
                Text("技术架构")
            } footer: {
                Text("多语言内容，一眼看懂。基于 Rust 共享内核的原生跨平台翻译与截图工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func iconForShortcutAction(_ action: GlobalShortcutAction) -> String {
        switch action {
        case .translateSelection: return "character.book.closed"
        case .captureSelection: return "text.viewfinder"
        case .screenshotAndPin: return "viewfinder"
        case .pinClipboardImage: return "doc.on.clipboard"
        case .longScreenshot: return "rectangle.stack.badge.plus"
        case .screenRecording: return "record.circle"
        case .restoreMostRecentPin: return "arrow.uturn.backward"
        case .screenTranslation: return "text.viewfinder"
        case .openTranslator: return "character.cursor.ibeam"
        }
    }

    // MARK: - Logic

    private func load() {
        do {
            let configuration = try store.load()
            provider = configuration.provider
            endpoint = configuration.endpoint
            apiKey = configuration.apiKey
            model = configuration.model
            targetLanguage = configuration.targetLanguage
            aiStreamingEnabled = configuration.aiStreamingEnabled
            includeBetaUpdates = configuration.includeBetaUpdates
            autoCheckUpdates = configuration.autoCheckUpdates
            screenshotToolbarItems = configuration.screenshotToolbarItems
            shortcuts = shortcutStore.load()
            recordingSettings = recordingSettingsStore.load()
            launchAtLoginEnabled = launchAtLoginManager.isEnabled
            recordingSettings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
                recordingSettings.frameRate,
                for: recordingSettings.format
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let configuration = AppConfiguration(
                provider: provider,
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                targetLanguage: targetLanguage,
                aiStreamingEnabled: aiStreamingEnabled,
                includeBetaUpdates: includeBetaUpdates,
                autoCheckUpdates: autoCheckUpdates,
                screenshotToolbarItems: screenshotToolbarItems
            )
            try onSave(configuration, shortcuts, recordingSettings, launchAtLoginEnabled)
            statusMessage = "设置已保存"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func isProviderAvailable(_ provider: TranslationProvider) -> Bool {
        switch provider {
        case .freeAI:
            return BundledFreeAIConfiguration() != nil
        case .google, .microsoft, .openAICompatible:
            return true
        }
    }

    private func providerLabel(_ provider: TranslationProvider) -> String {
        isProviderAvailable(provider)
            ? provider.displayName
            : "\(provider.displayName)（当前构建未配置）"
    }

    private var recordingFormatBinding: Binding<ScreenRecordingFormat> {
        Binding(
            get: { recordingSettings.format },
            set: { newFormat in
                recordingSettings.format = newFormat
                recordingSettings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
                    recordingSettings.frameRate,
                    for: newFormat
                )
            }
        )
    }

    private var recordingFrameRateBinding: Binding<Int> {
        Binding(
            get: { recordingSettings.frameRate },
            set: { requested in
                recordingSettings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
                    requested,
                    for: recordingSettings.format
                )
            }
        )
    }

    private var recordingDirectoryDisplayName: String {
        recordingSettings.saveDirectoryPath ?? "影片文件夹"
    }

    private func chooseRecordingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择区域录屏的默认保存目录"
        if let path = recordingSettings.saveDirectoryPath {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        recordingSettings.saveDirectoryPath = url.path
    }
}

private struct ToolbarCapsuleItemView: View {
    let item: ScreenshotToolbarItemConfig
    let info: (title: String, icon: String)
    let isDragging: Bool
    let onRemove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onRemove()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: info.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(isHovered && !isDragging ? 0.12 : 0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if isHovered && !isDragging {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.red)
                        .background(Color.white.clipShape(Circle()))
                        .offset(x: 3, y: -3)
                }
            }
            .opacity(isDragging ? 0.2 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(info.title)（点击移除，拖拽调整顺序）")
    }
}

private struct ToolbarDropDelegate: DropDelegate {
    let targetItem: ScreenshotToolbarItemConfig
    @Binding var items: [ScreenshotToolbarItemConfig]
    @Binding var draggingItem: String?

    func dropEntered(info: DropInfo) {
        guard let draggingItem, draggingItem != targetItem.id else { return }
        guard let fromIndex = items.firstIndex(where: { $0.id == draggingItem }),
              let toIndex = items.firstIndex(where: { $0.id == targetItem.id }) else { return }
        if fromIndex != toIndex {
            items.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingItem = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private let toolbarItemInfos: [String: (title: String, icon: String)] = [
    "pen": ("画笔", "pencil"),
    "rect": ("矩形", "rectangle"),
    "ellipse": ("椭圆", "circle"),
    "line": ("线条", "line.diagonal"),
    "arrow": ("箭头", "arrow.right"),
    "text": ("文字", "t.square"),
    "mosaic": ("马赛克", "checkerboard.rectangle"),
    "number": ("序号", "1.circle"),
    "undo": ("撤销", "arrow.uturn.backward"),
    "redo": ("重做", "arrow.uturn.forward"),
    "ocr": ("文字识别", "text.viewfinder"),
    "translate": ("识别并翻译", "character.bubble"),
    "barcode": ("二维码", "qrcode"),
    "pin": ("贴图", "pin.fill"),
    "longScreenshot": ("长截图", "arrow.up.and.down.square"),
    "screenRecording": ("录屏", "video"),
    "save": ("保存", "square.and.arrow.down"),
    "cancel": ("取消", "xmark.circle"),
    "copy": ("复制", "doc.on.doc")
]

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case services
    case shortcuts
    case recording
    case toolbar
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .services: return "翻译服务"
        case .shortcuts: return "快捷键"
        case .recording: return "截图与录屏"
        case .toolbar: return "工具栏"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "系统启动与基础偏好设置"
        case .services: return "翻译引擎配置与 API 密钥"
        case .shortcuts: return "全局快捷键自定义"
        case .recording: return "录屏格式、帧率与存储目录"
        case .toolbar: return "截图工具栏按钮及排序"
        case .about: return "版本信息与关于软件"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .services: return "character.book.closed"
        case .shortcuts: return "keyboard"
        case .recording: return "camera"
        case .toolbar: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: return .gray
        case .services: return .blue
        case .shortcuts: return .indigo
        case .recording: return .orange
        case .toolbar: return .teal
        case .about: return .purple
        }
    }
}

private struct SidebarNavItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tab.iconColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
