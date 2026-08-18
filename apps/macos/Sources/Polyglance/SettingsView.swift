import ApplicationServices
import CoreGraphics
import PolyglanceKit
import SwiftUI

struct SettingsView: View {
    let store: AppConfigurationStore
    let shortcutStore: GlobalShortcutConfigurationStore
    let recordingSettingsStore: RecordingSettingsStore
    let onSave: (
        AppConfiguration,
        GlobalShortcutConfiguration,
        RecordingSettings
    ) throws -> Void

    @State private var selectedTab = "services"
    @State private var endpoint = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var provider = TranslationProvider.microsoft
    @State private var aiStreamingEnabled = true
    @State private var targetLanguage = "zh-CN"
    @State private var shortcuts = GlobalShortcutConfiguration.default
    @State private var recordingSettings = RecordingSettings.default
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                translationServicesTab
                    .tabItem {
                        Label("翻译服务", systemImage: "character.book.closed")
                    }
                    .tag("services")

                shortcutsTab
                    .tabItem {
                        Label("快捷键", systemImage: "keyboard")
                    }
                    .tag("shortcuts")

                recordingTab
                    .tabItem {
                        Label("截图与录屏", systemImage: "camera")
                    }
                    .tag("recording")

                aboutTab
                    .tabItem {
                        Label("关于", systemImage: "info.circle")
                    }
                    .tag("about")
            }
            .padding(16)

            Divider()

            // 底部操作栏
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
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 560, height: 480)
        .task { load() }
    }

    // MARK: - Tabs

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
                        Text("当前构建没有注入免费 AI 服务配置，暂不可用。")
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

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(spacing: 4) {
                Text("Polyglance")
                    .font(.system(size: 16, weight: .bold))
                Text("多语言内容，一眼看懂")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("基于 Rust 共享内核的原生跨平台翻译与截图工具")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            shortcuts = shortcutStore.load()
            recordingSettings = recordingSettingsStore.load()
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
                aiStreamingEnabled: aiStreamingEnabled
            )
            try onSave(configuration, shortcuts, recordingSettings)
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

