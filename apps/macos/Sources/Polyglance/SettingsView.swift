import ApplicationServices
import AVFoundation
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
    @State private var serviceCategory = 0
    @State private var historySearchText = ""
    @State private var selectedHistoryRecordID: UUID?
    @ObservedObject private var historyStore = TranslationHistoryStore.shared
    private let speechSynthesizer = AVSpeechSynthesizer()

    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var provider = TranslationProvider.freeAI
    @State private var deeplAuthKey = ""
    @State private var deeplEndpoint = ""
    @State private var baiduAppId = ""
    @State private var baiduSecretKey = ""
    @State private var youdaoAppKey = ""
    @State private var youdaoSecret = ""
    @State private var volcanoAccessKey = ""
    @State private var volcanoSecretKey = ""
    @State private var enabledProviders: [String] = ["free-ai"]
    @State private var screenshotTranslationStyle = "bob"
    @State private var configuringProviderId: String = TranslationProvider.freeAI.rawValue
    @State private var customAIConfigs: [CustomAIServiceConfig] = []
    @State private var aiStreamingEnabled = true
    @State private var targetLanguage = "zh-CN"
    @State private var secondTargetLanguage = "en"
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
    @State private var ocrAutoCopyNextTime = false
    @State private var ocrDefaultFormatting = 0
    @State private var providerOrder: [String] = AppConfiguration.defaultProviderOrder
    @State private var draggedProviderId: String? = nil
    @State private var providerDragOffset: CGFloat = 0
    @State private var lastDragLocationY: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()
                .opacity(0.4)

            detailView
        }
        .frame(width: 860, height: 600)
        .task { load() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 32)

            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6.5))
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
            .padding(.bottom, 10)

            Divider()
                .opacity(0.4)
                .padding(.horizontal, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SettingsTabSection.allCases) { sec in
                        VStack(alignment: .leading, spacing: 1.5) {
                            Text(sec.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 4)

                            ForEach(sec.tabs) { tab in
                                SidebarNavItem(
                                    tab: tab,
                                    isSelected: selectedTab == tab
                                ) {
                                    selectedTab = tab
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            Spacer()

            HStack {
                Text("版本 \(AppVersionInfo.displayString)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 175)
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
                case .translationSettings:
                    translationSettingsTab
                case .favorites:
                    historyDetailView(onlyFavorites: true)
                case .history:
                    historyDetailView(onlyFavorites: false)
                case .ocrSettings:
                    ocrSettingsTab
                case .general:
                    generalTab
                case .shortcuts:
                    shortcutsTab
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

    // MARK: - Translation Tabs

    private var translationSettingsTab: some View {
        VStack(spacing: 0) {
            Picker("", selection: $serviceCategory) {
                Text("文本翻译").tag(0)
                Text("文本识别").tag(1)
                Text("语音合成").tag(2)
                Text("偏好设置").tag(3)
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            if serviceCategory == 0 {
                // 文本翻译: 双栏布局
                HStack(spacing: 0) {
                    // 左侧服务列表 (支持实体卡片随手势实时位移与平滑交互排序)
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(currentServiceItems) { item in
                                    HStack(spacing: 6) {
                                        ProviderBrandIcon(provider: item.iconProvider, size: 18)

                                        Text(item.displayName)
                                            .font(.system(size: 12))
                                            .lineLimit(1)

                                        Spacer()

                                        if item.isBuiltin {
                                            Text("内置")
                                                .font(.system(size: 9.5))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.green.opacity(0.12))
                                                .foregroundStyle(.green)
                                                .clipShape(Capsule())
                                        } else {
                                            Text("秘钥")
                                                .font(.system(size: 9.5))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.blue.opacity(0.12))
                                                .foregroundStyle(.blue)
                                                .clipShape(Capsule())
                                        }

                                        Toggle("", isOn: Binding(
                                            get: { enabledProviders.contains(item.id) },
                                            set: { isChecked in
                                                if isChecked {
                                                    if !enabledProviders.contains(item.id) {
                                                        enabledProviders.append(item.id)
                                                    }
                                                } else {
                                                    enabledProviders.removeAll { $0 == item.id }
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                        .toggleStyle(.switch)
                                        .controlSize(.mini)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(configuringProviderId == item.id ? Color.accentColor.opacity(0.15) : (draggedProviderId == item.id ? Color.gray.opacity(0.12) : Color.clear))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(configuringProviderId == item.id ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        configuringProviderId = item.id
                                    }
                                    .offset(y: draggedProviderId == item.id ? providerDragOffset : 0)
                                    .zIndex(draggedProviderId == item.id ? 10 : 1)
                                    .simultaneousGesture(
                                        DragGesture(coordinateSpace: .global)
                                            .onChanged { value in
                                                if draggedProviderId == nil {
                                                    draggedProviderId = item.id
                                                    configuringProviderId = item.id
                                                    lastDragLocationY = value.location.y
                                                    providerDragOffset = 0
                                                }
                                                guard draggedProviderId == item.id else { return }
                                                let deltaY = value.location.y - lastDragLocationY
                                                lastDragLocationY = value.location.y
                                                providerDragOffset += deltaY

                                                let itemHeight: CGFloat = 34
                                                guard let currentIdx = providerOrder.firstIndex(of: item.id) else { return }

                                                if providerDragOffset > itemHeight / 2 && currentIdx < providerOrder.count - 1 {
                                                    withAnimation(.easeInOut(duration: 0.15)) {
                                                        providerOrder.swapAt(currentIdx, currentIdx + 1)
                                                    }
                                                    providerDragOffset -= itemHeight
                                                } else if providerDragOffset < -itemHeight / 2 && currentIdx > 0 {
                                                    withAnimation(.easeInOut(duration: 0.15)) {
                                                        providerOrder.swapAt(currentIdx, currentIdx - 1)
                                                    }
                                                    providerDragOffset += itemHeight
                                                }
                                            }
                                            .onEnded { _ in
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    draggedProviderId = nil
                                                    providerDragOffset = 0
                                                    lastDragLocationY = 0
                                                }
                                            }
                                    )
                                }
                            }
                            .padding(6)
                        }

                        Divider().opacity(0.3)

                        // 底部 + - 工具栏与重置排序
                        HStack(spacing: 10) {
                            Menu {
                                Button {
                                    addCustomAIService()
                                } label: {
                                    Label("添加自定义 AI 服务...", systemImage: "sparkles")
                                }

                                Divider()

                                ForEach(TranslationProvider.allCases, id: \.self) { p in
                                    Button {
                                        if !enabledProviders.contains(p.rawValue) {
                                            enabledProviders.append(p.rawValue)
                                        }
                                        configuringProviderId = p.rawValue
                                    } label: {
                                        HStack {
                                            Text(p.displayName)
                                            if enabledProviders.contains(p.rawValue) {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("添加自定义 AI 或启用内置服务")

                            Button {
                                deleteSelectedService()
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .help("删除自定义服务或禁用选中内置服务")

                            Spacer()

                            Button("默认排序") {
                                withAnimation {
                                    var newOrder = AppConfiguration.defaultProviderOrder
                                    for custom in customAIConfigs where !newOrder.contains(custom.id) {
                                        newOrder.append(custom.id)
                                    }
                                    providerOrder = newOrder
                                }
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .help("恢复默认顺序（官方 AI 在首位）")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .frame(width: 270)

                    Divider().opacity(0.4)

                    // 右侧服务详情配置
                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 8) {
                                    if let custom = customAIConfigs.first(where: { $0.id == configuringProviderId }) {
                                        ProviderBrandIcon(provider: "openai-compatible", size: 22)
                                        Text(custom.name.isEmpty ? "自定义 AI 服务" : custom.name)
                                            .font(.system(size: 14, weight: .semibold))
                                    } else if let p = TranslationProvider(rawValue: configuringProviderId) {
                                        ProviderBrandIcon(provider: p.rawValue, size: 22)
                                        Text(p.displayName)
                                            .font(.system(size: 14, weight: .semibold))
                                    }
                                    Spacer()
                                }
                                .padding(.bottom, 4)

                                if let customIdx = customAIConfigs.firstIndex(where: { $0.id == configuringProviderId }) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        let isNameDuplicate = customAIConfigs.enumerated().contains { i, c in
                                            i != customIdx && !c.name.isEmpty && c.name.trimmingCharacters(in: .whitespacesAndNewlines) == customAIConfigs[customIdx].name.trimmingCharacters(in: .whitespacesAndNewlines)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("服务名称")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("例如 DeepSeek, Claude, Moonshot 等", text: $customAIConfigs[customIdx].name)
                                                .textFieldStyle(.roundedBorder)
                                            if isNameDuplicate {
                                                Text("服务名称已存在，请保持唯一")
                                                    .font(.caption)
                                                    .foregroundStyle(Color.red)
                                            }
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("服务地址 (Endpoint)")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("https://api.openai.com/v1", text: $customAIConfigs[customIdx].endpoint)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("API 密钥 (API Key)")
                                                .font(.system(size: 12, weight: .medium))
                                            SecureField("sk-...", text: $customAIConfigs[customIdx].apiKey)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("模型名称")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("例如 deepseek-chat, gpt-4o-mini", text: $customAIConfigs[customIdx].model)
                                                .textFieldStyle(.roundedBorder)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("自定义 Prompt (可选)")
                                                .font(.system(size: 12, weight: .medium))
                                            TextEditor(text: $customAIConfigs[customIdx].prompt)
                                                .font(.system(size: 12, design: .monospaced))
                                                .frame(minHeight: 80, maxHeight: 120)
                                                .padding(4)
                                                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                                            Text("支持变量替换：{target_language}、{source_language}。留空则使用默认翻译系统提示词。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)
                                            .font(.system(size: 12.5))
                                            .padding(.top, 4)

                                        Divider().padding(.vertical, 4)

                                        Button(role: .destructive) {
                                            deleteSelectedService()
                                        } label: {
                                            HStack {
                                                Image(systemName: "trash")
                                                Text("删除该自定义 AI 服务")
                                            }
                                            .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } else if let p = TranslationProvider(rawValue: configuringProviderId) {
                                    switch p {
                                    case .freeAI:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("无需配置 API Key，使用内置分发的免费 AI 翻译服务。")
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                            Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)
                                                .font(.system(size: 12.5))
                                                .padding(.top, 4)
                                        }

                                    case .deepl:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("DeepL 授权密钥 (Auth Key)")
                                                .font(.system(size: 12, weight: .medium))
                                            SecureField("例如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx:fx", text: $deeplAuthKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("API 接入地址 (可选，留空则自动根据 Key 识别 Free/Pro)")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.top, 4)
                                            TextField("https://api-free.deepl.com/v2/translate", text: $deeplEndpoint)
                                                .textFieldStyle(.roundedBorder)

                                            Text("前往 DeepL 官网 (deepl.com) 注册开通 API 账户获取 Auth Key。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)
                                        }

                                    case .baidu:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("APP ID")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("百度翻译开放平台 APP ID", text: $baiduAppId)
                                                .textFieldStyle(.roundedBorder)

                                            Text("密钥 (Secret Key)")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.top, 4)
                                            SecureField("百度翻译密钥", text: $baiduSecretKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("前往百度翻译开放平台 (api.fanyi.baidu.com) 申请通用翻译 API 获取。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)
                                        }

                                    case .youdao:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("应用 ID (AppKey)")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("有道智云 AppKey", text: $youdaoAppKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("应用密钥 (AppSecret)")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.top, 4)
                                            SecureField("平台生成的密钥", text: $youdaoSecret)
                                                .textFieldStyle(.roundedBorder)

                                            Text("前往有道智云平台 (ai.youdao.com) 注册开通自然语言翻译服务获取。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)
                                        }

                                    case .volcano:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("AccessKey ID")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("火山引擎 AccessKey ID", text: $volcanoAccessKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("Secret AccessKey")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.top, 4)
                                            SecureField("火山引擎 Secret AccessKey (或 Bearer Token)", text: $volcanoSecretKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("前往火山引擎控制台 (volcengine.com) 申请机器翻译 API 密钥。")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 2)
                                        }

                                    case .openAICompatible:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("服务地址 (Endpoint)")
                                                .font(.system(size: 12, weight: .medium))
                                            TextField("https://api.openai.com/v1", text: $endpoint)
                                                .textFieldStyle(.roundedBorder)

                                            Text("API 密钥 (API Key)")
                                                .font(.system(size: 12, weight: .medium))
                                            SecureField("sk-...", text: $apiKey)
                                                .textFieldStyle(.roundedBorder)

                                            Text("模型名称")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.top, 4)
                                            TextField("例如 deepseek-chat, gpt-4o-mini", text: $model)
                                                .textFieldStyle(.roundedBorder)

                                            Toggle("开启 AI 流式逐字输出", isOn: $aiStreamingEnabled)
                                                .font(.system(size: 12.5))
                                                .padding(.top, 4)
                                        }

                                    default:
                                        Text("该服务内置系统网络协议，无需额外参数。")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()
                            }
                            .padding(16)
                        }

                        Divider().opacity(0.3)

                        // 底部撤销与保存按钮
                        HStack(spacing: 10) {
                            Spacer()

                            Button("撤销") {
                                load()
                            }
                            .controlSize(.regular)

                            Button("保存") {
                                save()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            } else if serviceCategory == 1 {
                // 文本识别 (OCR)
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.teal)
                    Text("Apple Vision 离线文字识别")
                        .font(.system(size: 14, weight: .semibold))
                    Text("由 macOS 系统原生 Neural Engine 提供支持，支持多语言离线高精度识别，免配置开箱即用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if serviceCategory == 2 {
                // 语音合成 (TTS)
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "speaker.wave.3")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.indigo)
                    Text("Apple Speech 离线语音合成")
                        .font(.system(size: 14, weight: .semibold))
                    Text("由 macOS 系统 AVSpeechSynthesizer 提供支持，内置高品质多国语言发音人，免配置开箱即用。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 偏好设置
                Form {
                    Section {
                        Picker("默认目标语言", selection: $targetLanguage) {
                            Text("简体中文").tag("zh-CN")
                            Text("英语").tag("en")
                            Text("日语").tag("ja")
                            Text("韩语").tag("ko")
                            Text("法语").tag("fr")
                            Text("德语").tag("de")
                            Text("西班牙语").tag("es")
                            Text("俄语").tag("ru")
                        }
                        .pickerStyle(.menu)

                        Picker("第二目标语言", selection: $secondTargetLanguage) {
                            Text("英语").tag("en")
                            Text("简体中文").tag("zh-CN")
                            Text("日语").tag("ja")
                            Text("韩语").tag("ko")
                        }
                        .pickerStyle(.menu)

                        Picker("截图翻译展示风格", selection: $screenshotTranslationStyle) {
                            Text("Bob 风格（左右/上下对照气泡）").tag("bob")
                            Text("译文替换原图（原位覆盖）").tag("replace")
                        }
                        .pickerStyle(.menu)
                    } header: {
                        Text("语言与交互偏好")
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    // MARK: - History / Favorites Tab (Image 4)

    private func historyDetailView(onlyFavorites: Bool) -> some View {
        let allRecords = onlyFavorites ? historyStore.records.filter(\.isFavorite) : historyStore.records
        let filteredRecords = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? allRecords
            : allRecords.filter {
                $0.sourceText.localizedCaseInsensitiveContains(historySearchText) ||
                $0.targetText.localizedCaseInsensitiveContains(historySearchText)
            }

        let selectedRecord = filteredRecords.first(where: { $0.id == selectedHistoryRecordID }) ?? filteredRecords.first

        return HStack(spacing: 0) {
            // Left list (width 250)
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索记录…", text: $historySearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !historySearchText.isEmpty {
                        Button {
                            historySearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .padding(8)

                Divider().opacity(0.3)

                // Records list
                if filteredRecords.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: onlyFavorites ? "star.slash" : "clock.arrow.circlepath")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(onlyFavorites ? "暂无收藏内容" : "暂无历史记录")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedHistoryRecordID) {
                        ForEach(filteredRecords) { record in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.sourceText)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)

                                Text(record.targetText)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(record.id)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }

                Divider().opacity(0.3)

                // Bottom count bar
                HStack {
                    Text("\(filteredRecords.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Menu {
                        Button("清空全部记录", role: .destructive) {
                            historyStore.clearAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(width: 250)

            Divider().opacity(0.4)

            // Right detail pane (Image 4)
            if let record = selectedRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Top meta row
                        HStack {
                            Text(formatHistoryDate(record.timestamp))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                historyStore.deleteRecord(id: record.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("删除记录")

                            Button {
                                historyStore.toggleFavorite(id: record.id)
                            } label: {
                                Image(systemName: record.isFavorite ? "star.fill" : "star")
                                    .font(.system(size: 12))
                                    .foregroundStyle(record.isFavorite ? .yellow : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(record.isFavorite ? "取消收藏" : "收藏")
                        }

                        // Source Card
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.sourceText)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            HStack(spacing: 8) {
                                Button {
                                    speakText(record.sourceText)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(record.sourceText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Spacer()
                            }
                            .padding(.top, 2)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        )

                        // Language pills
                        HStack(spacing: 8) {
                            Text(record.sourceLang.isEmpty ? "自动检测" : record.sourceLang)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))

                            Image(systemName: "chevron.right.2")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)

                            Text(record.targetLang)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))

                            Spacer()
                        }

                        // Translation result card
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.targetText)
                                .font(.system(size: 13.5))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)

                            HStack(spacing: 8) {
                                Button {
                                    speakText(record.targetText)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(record.targetText, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)

                                Spacer()

                                Text(TranslatorViewModel.displayName(for: record.provider))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)

                                ProviderBrandIcon(provider: record.provider, size: 14)
                            }
                            .padding(.top, 4)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        )
                    }
                    .padding(16)
                }
            } else {
                VStack {
                    Spacer()
                    Text("请在左侧选择一条记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - OCR Tabs

    private var ocrSettingsTab: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.teal)
                        .frame(width: 32, height: 32)
                        .background(Color.teal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Vision 文本识别")
                            .font(.system(size: 13, weight: .semibold))
                        Text("系统原生离线模型，支持中英日韩等多国语言，开箱即用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("内置生效")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
            } header: {
                Text("OCR 识别引擎")
            }

            Section {
                Picker("默认文字排版", selection: $ocrDefaultFormatting) {
                    Text("保留段落换行").tag(0)
                    Text("合并所有换行（单行）").tag(1)
                    Text("严格保留原有换行").tag(2)
                }

                Toggle("文字识别完成后自动复制到剪贴板", isOn: $ocrAutoCopyNextTime)
            } header: {
                Text("文字排版与快捷操作")
            }
        }
        .formStyle(.grouped)
    }

    private var ocrServicesTab: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.teal)
                        .frame(width: 32, height: 32)
                        .background(Color.teal.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Vision 文本识别")
                            .font(.system(size: 13, weight: .semibold))
                        Text("系统原生离线模型，支持中英日韩等多国语言，开箱即用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("内置生效")
                        .font(.system(size: 10.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 2)
            } header: {
                Text("OCR 识别引擎")
            }
        }
        .formStyle(.grouped)
    }

    private let visibleShortcutActions: [GlobalShortcutAction] = [
        .screenTranslation,
        .screenshotAndCopy,
        .screenshotAndPin,
        .translateSelection,
        .translateAndReplace,
        .openTranslator,
        .pinClipboardImage,
        .longScreenshot,
        .screenRecording,
        .restoreMostRecentPin,
        .ocrWorkspace
    ]

    private var shortcutsTab: some View {
        Form {
            Section {
                ForEach(visibleShortcutActions, id: \.self) { action in
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
        case .translateAndReplace: return ("arrow.turn.down.left", .blue)
        case .captureSelection: return ("text.viewfinder", .teal)
        case .screenshotAndPin: return ("viewfinder", .orange)
        case .screenshotAndCopy: return ("doc.on.doc", .green)
        case .pinClipboardImage: return ("doc.on.clipboard", .green)
        case .longScreenshot: return ("rectangle.stack.badge.plus", .purple)
        case .screenRecording: return ("record.circle", .red)
        case .restoreMostRecentPin: return ("arrow.uturn.backward", .indigo)
        case .screenTranslation: return ("photo.badge.checkmark", .cyan)
        case .openTranslator: return ("character.cursor.ibeam", .mint)
        case .ocrTranslate: return ("character.bubble", .blue)
        case .ocrWorkspace: return ("text.viewfinder", .teal)
        case .ocrTranslationCard: return ("menucard", .orange)
        }
    }

    private func hasKeyConfigured(_ p: TranslationProvider) -> Bool {
        switch p {
        case .freeAI, .microsoft, .google:
            return true
        case .deepl:
            return !deeplAuthKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .baidu:
            return !baiduAppId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !baiduSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .youdao:
            return !youdaoAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !youdaoSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .volcano:
            return !volcanoSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .openAICompatible:
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func providerIconName(_ p: TranslationProvider) -> String {
        switch p {
        case .freeAI: return "sparkles"
        case .microsoft: return "text.bubble"
        case .google: return "globe"
        case .deepl: return "d.circle.fill"
        case .baidu: return "b.circle.fill"
        case .youdao: return "y.circle.fill"
        case .volcano: return "flame.fill"
        case .openAICompatible: return "cpu"
        }
    }

    private func providerIconColor(_ p: TranslationProvider) -> Color {
        switch p {
        case .freeAI: return .purple
        case .microsoft: return .blue
        case .google: return .teal
        case .deepl: return .indigo
        case .baidu: return .blue
        case .youdao: return .red
        case .volcano: return .orange
        case .openAICompatible: return .green
        }
    }

    private func providerDescription(_ p: TranslationProvider) -> String {
        switch p {
        case .freeAI:
            return "官方内置 AI 翻译服务，无需配置密钥"
        case .microsoft:
            return "微软必应翻译服务，免密钥直接调用"
        case .google:
            return "Google 网页翻译服务，免密钥直接调用"
        case .deepl:
            return "DeepL 高质量翻译，需要配置 Authentication Key"
        case .baidu:
            return "百度翻译开放平台，需要配置 APP ID 与密钥"
        case .youdao:
            return "网易有道智云翻译平台，需要配置应用 ID 与应用密钥"
        case .volcano:
            return "字节跳动火山引擎翻译，需要配置 AccessKey 与 SecretKey"
        case .openAICompatible:
            return "支持自定义兼容 OpenAI 接口标准的 API 服务与模型"
        }
    }

    private static let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func formatHistoryDate(_ date: Date) -> String {
        Self.historyDateFormatter.string(from: date)
    }

    private func speakText(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        speechSynthesizer.speak(utterance)
    }

    private func providerIconName(_ rawProvider: String) -> String {
        if let p = TranslationProvider(rawValue: rawProvider) {
            return providerIconName(p)
        }
        return "character.bubble"
    }

    private func providerColor(_ rawProvider: String) -> Color {
        if let p = TranslationProvider(rawValue: rawProvider) {
            return providerIconColor(p)
        }
        return .blue
    }

    private struct ServiceListItem: Identifiable, Equatable {
        let id: String
        let displayName: String
        let isBuiltin: Bool
        let requiresKey: Bool
        let iconProvider: String
    }

    private var currentServiceItems: [ServiceListItem] {
        var items: [ServiceListItem] = []
        var seen = Set<String>()

        for id in providerOrder {
            if let p = TranslationProvider(rawValue: id) {
                items.append(ServiceListItem(
                    id: id,
                    displayName: p.displayName,
                    isBuiltin: !p.requiresUserAPIKey,
                    requiresKey: p.requiresUserAPIKey,
                    iconProvider: p.rawValue
                ))
                seen.insert(id)
            } else if let custom = customAIConfigs.first(where: { $0.id == id }) {
                items.append(ServiceListItem(
                    id: id,
                    displayName: custom.name.isEmpty ? "未命名 AI" : custom.name,
                    isBuiltin: false,
                    requiresKey: true,
                    iconProvider: "openai-compatible"
                ))
                seen.insert(id)
            }
        }

        for custom in customAIConfigs where !seen.contains(custom.id) {
            items.append(ServiceListItem(
                id: custom.id,
                displayName: custom.name.isEmpty ? "未命名 AI" : custom.name,
                isBuiltin: false,
                requiresKey: true,
                iconProvider: "openai-compatible"
            ))
        }

        return items
    }

    private func addCustomAIService() {
        var counter = 1
        var candidateName = "自定义 AI \(counter)"
        let existingNames = Set(customAIConfigs.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        while existingNames.contains(candidateName) {
            counter += 1
            candidateName = "自定义 AI \(counter)"
        }
        let newId = "custom_\(UUID().uuidString.prefix(8).lowercased())"
        let newConfig = CustomAIServiceConfig(
            id: newId,
            name: candidateName,
            endpoint: "https://api.openai.com/v1",
            apiKey: "",
            model: "gpt-4o-mini",
            prompt: "",
            isEnabled: true
        )
        customAIConfigs.append(newConfig)
        if !providerOrder.contains(newId) {
            providerOrder.append(newId)
        }
        if !enabledProviders.contains(newId) {
            enabledProviders.append(newId)
        }
        configuringProviderId = newId
    }

    private func deleteSelectedService() {
        if let idx = customAIConfigs.firstIndex(where: { $0.id == configuringProviderId }) {
            let removedId = customAIConfigs[idx].id
            customAIConfigs.remove(at: idx)
            enabledProviders.removeAll { $0 == removedId }
            providerOrder.removeAll { $0 == removedId }
            configuringProviderId = providerOrder.first ?? TranslationProvider.freeAI.rawValue
        } else {
            enabledProviders.removeAll { $0 == configuringProviderId }
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
            secondTargetLanguage = configuration.secondTargetLanguage
            aiStreamingEnabled = configuration.aiStreamingEnabled
            includeBetaUpdates = configuration.includeBetaUpdates
            autoCheckUpdates = configuration.autoCheckUpdates
            screenshotToolbarItems = configuration.screenshotToolbarItems
            saveCompletedScreenshotsToHistory = configuration.saveCompletedScreenshotsToHistory
            shortcuts = shortcutStore.load()
            recordingSettings = recordingSettingsStore.load()
            launchAtLoginEnabled = launchAtLoginManager.isEnabled
            enabledProviders = configuration.enabledProviders
            screenshotTranslationStyle = configuration.screenshotTranslationStyle
            deeplAuthKey = configuration.deeplAuthKey
            deeplEndpoint = configuration.deeplEndpoint
            baiduAppId = configuration.baiduAppId
            baiduSecretKey = configuration.baiduSecretKey
            youdaoAppKey = configuration.youdaoAppKey
            youdaoSecret = configuration.youdaoSecret
            volcanoAccessKey = configuration.volcanoAccessKey
            volcanoSecretKey = configuration.volcanoSecretKey
            providerOrder = configuration.providerOrder
            customAIConfigs = configuration.customAIConfigs
            for custom in customAIConfigs where !providerOrder.contains(custom.id) {
                providerOrder.append(custom.id)
            }
            if !providerOrder.contains(configuringProviderId) {
                configuringProviderId = providerOrder.first ?? TranslationProvider.freeAI.rawValue
            }
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
        let trimmedNames = customAIConfigs.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmedNames.contains(where: { $0.isEmpty }) {
            isStatusError = true
            statusMessage = "自定义 AI 服务名称不能为空"
            return
        }
        if Set(trimmedNames).count != trimmedNames.count {
            isStatusError = true
            statusMessage = "自定义 AI 服务名称不能重复"
            return
        }

        do {
            let configuration = AppConfiguration(
                provider: provider,
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                targetLanguage: targetLanguage,
                secondTargetLanguage: secondTargetLanguage,
                aiStreamingEnabled: aiStreamingEnabled,
                includeBetaUpdates: includeBetaUpdates,
                autoCheckUpdates: autoCheckUpdates,
                screenshotToolbarItems: screenshotToolbarItems,
                saveCompletedScreenshotsToHistory: saveCompletedScreenshotsToHistory,
                enabledProviders: enabledProviders.isEmpty ? ["free-ai"] : enabledProviders,
                deeplAuthKey: deeplAuthKey,
                deeplEndpoint: deeplEndpoint,
                baiduAppId: baiduAppId,
                baiduSecretKey: baiduSecretKey,
                youdaoAppKey: youdaoAppKey,
                youdaoSecret: youdaoSecret,
                volcanoAccessKey: volcanoAccessKey,
                volcanoSecretKey: volcanoSecretKey,
                screenshotTranslationStyle: screenshotTranslationStyle,
                providerOrder: providerOrder,
                customAIConfigs: customAIConfigs
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
        default:
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

private enum SettingsTabSection: String, CaseIterable, Identifiable {
    case translation = "翻译"
    case ocr = "OCR"
    case general = "通用"

    var id: String { rawValue }

    var tabs: [SettingsTab] {
        switch self {
        case .translation:
            return [.translationSettings, .favorites, .history]
        case .ocr:
            return [.ocrSettings]
        case .general:
            return [.general, .shortcuts, .toolbar, .about]
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case translationSettings = "translation_settings"
    case favorites = "favorites"
    case history = "history"
    case ocrSettings = "ocr_settings"
    case general = "general"
    case shortcuts = "shortcuts"
    case toolbar = "toolbar"
    case about = "about"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translationSettings: return "翻译设置"
        case .favorites: return "收藏夹"
        case .history: return "历史记录"
        case .ocrSettings: return "OCR 设置"
        case .general: return "通用设置"
        case .shortcuts: return "快捷键"
        case .toolbar: return "录屏与工具栏"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .translationSettings: return "服务列表、密钥配置与翻译交互偏好"
        case .favorites: return "已收藏的高频词句与常用译文"
        case .history: return "本地翻译历史查询与管理"
        case .ocrSettings: return "文字识别引擎、格式与自动复制偏好"
        case .general: return "系统权限、启动项与基础偏好"
        case .shortcuts: return "全局快捷键自定义"
        case .toolbar: return "截图工具栏定制与录屏参数配置"
        case .about: return "版本信息与技术架构"
        }
    }

    var icon: String {
        switch self {
        case .translationSettings: return "gearshape.2"
        case .favorites: return "star"
        case .history: return "clock"
        case .ocrSettings: return "text.viewfinder"
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .toolbar: return "camera"
        case .about: return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .translationSettings: return .blue
        case .favorites: return .yellow
        case .history: return .orange
        case .ocrSettings: return .teal
        case .general: return .gray
        case .shortcuts: return .indigo
        case .toolbar: return .purple
        case .about: return .secondary
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tab.iconColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6.5)
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
