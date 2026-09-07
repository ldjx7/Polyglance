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
    @State private var saveCompletedScreenshotsToHistory = false
    @State private var draggingItemID: String? = nil
    @State private var statusMessage: String?
    @State private var isStatusError = false
    @State private var permissionsRefreshTrigger = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()
                .opacity(0.4)

            detailView
        }
        .frame(width: 840, height: 580)
        .task { load() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 38)

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1.5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(SettingsBranding.name)
                        .font(.system(size: 13, weight: .semibold))
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
            .padding(.bottom, 12)

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 10)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarNavItem(
                        tab: tab,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Spacer()

            HStack {
                Text("版本 \(AppVersionInfo.displayString)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 200)
        .background(VisualEffectBackground(material: .sidebar))
    }

    // MARK: - Detail View

    private var detailView: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .opacity(0.4)

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
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.primary)
                Text(selectedTab.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let statusMessage {
                HStack(spacing: 4) {
                    Image(systemName: isStatusError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(isStatusError ? Color.red : Color.green)
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isStatusError ? Color.red : Color.secondary)
                }
                .transition(.opacity)
            }

            Button("保存设置") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
                    Button("打开系统设置") {
                        launchAtLoginManager.openSystemSettings()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("常规与启动")
            }

            Section {
                HStack {
                    Label("辅助功能权限", systemImage: "hand.raised.fill")
                    Spacer()
                    PermissionBadge(isGranted: isAccessibilityGranted)
                    Button("检查/请求") {
                        SelectedTextReader().requestAccessibilityPermission()
                        permissionsRefreshTrigger += 1
                    }
                    .controlSize(.small)
                }

                HStack {
                    Label("屏幕录制权限", systemImage: "rectangle.inset.filled.and.cursorarrow")
                    Spacer()
                    PermissionBadge(isGranted: isScreenRecordingGranted)
                    Button("检查/请求") {
                        _ = CGRequestScreenCaptureAccess()
                        permissionsRefreshTrigger += 1
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("系统权限")
            } footer: {
                Text("划词读取需要辅助功能权限；区域截图与录屏需要屏幕录制权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("保存已完成截图到历史记录", isOn: $saveCompletedScreenshotsToHistory)
            } header: {
                Text("截图历史")
            } footer: {
                Text("开启后，成功复制或另存为的截图与长截图将自动存入历史记录。历史记录只保存在本机，最多保留 30 条 / 512 MiB。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                case .google, .microsoft:
                    HStack(spacing: 12) {
                        Image(systemName: provider == .google ? "globe" : "text.bubble")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 7))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(provider == .google
                                ? "使用 Google 翻译公共接口，开箱即用，无需配置 API Key。"
                                : "使用 Microsoft Edge 翻译公共接口，稳定高效，无需配置 API Key。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)

                case .freeAI:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.purple)
                                .frame(width: 32, height: 32)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 7))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                if BundledFreeAIConfiguration() == nil {
                                    Text("当前配置的免费 AI 服务地址不可用。")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("无需配置 API Key。使用内置分发的免费 AI 翻译服务。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 3)

                    Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)

                case .openAICompatible:
                    LabeledContent("服务地址 (Endpoint)") {
                        TextField("https://api.openai.com/v1", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("API 密钥 (API Key)") {
                        SecureField("sk-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("模型名称") {
                        TextField("例如 deepseek-chat, gpt-4o-mini", text: $model)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)
                }
            } header: {
                Text("服务详情配置")
            } footer: {
                if provider == .openAICompatible {
                    Text("支持 OpenAI、DeepSeek、SiliconFlow 等任何兼容 OpenAI 接口规范的服务。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            Section {
                ForEach(GlobalShortcutAction.allCases, id: \.self) { action in
                    let info = shortcutActionInfo(action)
                    LabeledContent {
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { shortcuts[action] },
                                set: { shortcuts[action] = $0 }
                            )
                        )
                        .frame(width: 140, height: 26)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: info.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(info.color)
                                .frame(width: 22, height: 22)
                                .background(info.color.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            Text(action.title)
                                .font(.system(size: 13))
                        }
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
                LabeledContent {
                    KeycapBadge("⌘ ↩︎")
                } label: {
                    Text("翻译输入内容")
                }

                LabeledContent {
                    KeycapBadge("⇧ ⌘ C")
                } label: {
                    Text("复制译文")
                }

                LabeledContent {
                    KeycapBadge("⌘ K")
                } label: {
                    Text("清空并聚焦原文")
                }
            } header: {
                Text("主窗口内快捷键（固定）")
            }
        }
        .formStyle(.grouped)
    }

    private var recordingTab: some View {
        Form {
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
            } header: {
                Text("视频与格式")
            }

            Section {
                Toggle("录制系统声音", isOn: $recordingSettings.capturesSystemAudio)
                    .disabled(!recordingSettings.format.supportsAudio)
                Toggle("录制麦克风", isOn: $recordingSettings.capturesMicrophone)
                    .disabled(!recordingSettings.format.supportsAudio)
                Toggle("显示鼠标指针", isOn: $recordingSettings.showsCursor)
            } header: {
                Text("音频与鼠标")
            } footer: {
                if !recordingSettings.format.supportsAudio {
                    Text("GIF 格式不支持录制音频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(
                    RecordingSettingsPresentation.saveLocationToggleTitle,
                    isOn: $recordingSettings.asksForSaveLocation
                )

                LabeledContent("保存目录") {
                    HStack(spacing: 8) {
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
            } header: {
                Text("存储与导出")
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
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Polyglance")
                                .font(.system(size: 17, weight: .bold))
                            let isBeta = AppVersionInfo.versionString.contains("-beta")
                            Text(isBeta ? "Beta 尝鲜" : "正式版")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(isBeta ? Color.purple.opacity(0.14) : Color.green.opacity(0.14))
                                .foregroundStyle(isBeta ? Color.purple : Color.green)
                                .clipShape(Capsule())
                        }

                        Text("版本 \(AppVersionInfo.displayString)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Text("原生跨平台翻译与截图工具")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button("检查更新") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("关于应用")
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

    // MARK: - Helpers

    private var isAccessibilityGranted: Bool {
        _ = permissionsRefreshTrigger
        return AXIsProcessTrusted()
    }

    private var isScreenRecordingGranted: Bool {
        _ = permissionsRefreshTrigger
        return CGPreflightScreenCaptureAccess()
    }

    private func shortcutActionInfo(_ action: GlobalShortcutAction) -> (icon: String, color: Color) {
        switch action {
        case .translateSelection: return ("character.book.closed", .blue)
        case .captureSelection: return ("text.viewfinder", .teal)
        case .screenshotAndPin: return ("viewfinder", .orange)
        case .pinClipboardImage: return ("doc.on.clipboard", .green)
        case .longScreenshot: return ("rectangle.stack.badge.plus", .purple)
        case .screenRecording: return ("record.circle", .red)
        case .restoreMostRecentPin: return ("arrow.uturn.backward", .indigo)
        case .screenTranslation: return ("character.bubble", .cyan)
        case .openTranslator: return ("character.cursor.ibeam", .mint)
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
            saveCompletedScreenshotsToHistory = configuration.saveCompletedScreenshotsToHistory
            shortcuts = shortcutStore.load()
            recordingSettings = recordingSettingsStore.load()
            launchAtLoginEnabled = launchAtLoginManager.isEnabled
            recordingSettings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
                recordingSettings.frameRate,
                for: recordingSettings.format
            )
        } catch {
            isStatusError = true
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
                screenshotToolbarItems: screenshotToolbarItems,
                saveCompletedScreenshotsToHistory: saveCompletedScreenshotsToHistory
            )
            try onSave(configuration, shortcuts, recordingSettings, launchAtLoginEnabled)
            isStatusError = false
            statusMessage = "设置已保存"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if statusMessage == "设置已保存" {
                    withAnimation {
                        statusMessage = nil
                    }
                }
            }
        } catch {
            isStatusError = true
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

// MARK: - Visual Effect View

private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Permission Badge

private struct PermissionBadge: View {
    let isGranted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isGranted ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(isGranted ? "已授权" : "未授权")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((isGranted ? Color.green : Color.orange).opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Keycap Badge

private struct KeycapBadge: View {
    let keys: [String]

    init(_ shortcutText: String) {
        self.keys = shortcutText.split(separator: " ").map(String.init)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
            }
        }
    }
}

// MARK: - Toolbar Item View

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
        case .general: return "系统权限、启动与基础偏好"
        case .services: return "翻译引擎配置与 API 密钥"
        case .shortcuts: return "全局快捷键自定义"
        case .recording: return "录屏格式、画质与存储目录"
        case .toolbar: return "截图工具栏按钮自定义与排序"
        case .about: return "版本信息与技术架构"
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
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tab.iconColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 5.5))

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
