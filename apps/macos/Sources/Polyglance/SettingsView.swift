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
        Form {
            Section("翻译服务") {
                Picker("默认服务", selection: $provider) {
                    ForEach(TranslationProvider.allCases, id: \.self) { provider in
                        Text(providerLabel(provider))
                            .tag(provider)
                            .disabled(!isProviderAvailable(provider))
                    }
                }

                Picker("默认目标语言", selection: $targetLanguage) {
                    Text("简体中文").tag("zh-CN")
                    Text("英语").tag("en")
                    Text("日语").tag("ja")
                    Text("韩语").tag("ko")
                }

                switch provider {
                case .google:
                    Text("无需配置 API Key。使用 Google 的免费旧版翻译接口，原文会发送给 Google；该接口可能受网络、限流和服务变更影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .microsoft:
                    Text("无需配置 API Key。使用 Microsoft Edge 的免费翻译接口，原文会发送给 Microsoft；该接口可能受网络、限流和服务变更影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .freeAI:
                    if BundledFreeAIConfiguration() == nil {
                        Text("当前构建没有注入免费 AI 服务配置，因此暂不可用。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("无需用户填写 API Key。发布者在构建阶段提供免费 AI 服务配置；原文会发送给第三方 AI 服务，免费模型可能有较低的速率和可用性限制。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .openAICompatible:
                    TextField("Endpoint", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("模型", text: $model)
                        .textFieldStyle(.roundedBorder)
                    Text("可接入 DeepSeek、OpenAI 或其他 OpenAI-compatible 服务。AI 是可选项，不会被自动启用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if provider == .freeAI || provider == .openAICompatible {
                    Toggle("流式输出译文", isOn: $aiStreamingEnabled)
                    Text("开启后 AI 译文逐字显示；关闭后等待完整译文一次性显示。Google 与 Microsoft 翻译始终一次性返回，不受此开关影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("系统权限") {
                HStack {
                    Text("读取其他应用的选中文字需要辅助功能权限。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("请求权限") {
                        SelectedTextReader().requestAccessibilityPermission()
                    }
                }

                HStack {
                    Text("截图、长截图和录屏需要屏幕录制权限；录制麦克风时还需要麦克风权限。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("请求屏幕权限") {
                        _ = CGRequestScreenCaptureAccess()
                    }
                }
            }

            Section("全局快捷键") {
                ForEach(GlobalShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { shortcuts[action] },
                                set: { shortcuts[action] = $0 }
                            )
                        )
                        .frame(width: 150, height: 28)
                    }
                }

                HStack {
                    Text("点击右侧按键框后输入新组合；至少包含 ⌘、⌥ 或 ⌃。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") {
                        shortcuts = .default
                        statusMessage = nil
                    }
                }
            }

            Section("区域录屏") {
                Picker("默认格式", selection: recordingFormatBinding) {
                    ForEach(ScreenRecordingFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Text(recordingSettings.format.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("默认质量", selection: $recordingSettings.quality) {
                    ForEach(ScreenRecordingQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text(recordingQualitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("默认帧率", selection: recordingFrameRateBinding) {
                    ForEach(
                        ScreenRecordingFrameRatePolicy.choices(for: recordingSettings.format),
                        id: \.self
                    ) { frameRate in
                        Text("\(frameRate) FPS").tag(frameRate)
                    }
                }

                Picker("默认录制延时", selection: $recordingSettings.countdownDelay) {
                    ForEach(ScreenRecordingDelay.allCases, id: \.self) { delay in
                        Text(delay.displayName).tag(delay)
                    }
                }

                Toggle(
                    RecordingSettingsPresentation.saveLocationToggleTitle,
                    isOn: $recordingSettings.asksForSaveLocation
                )

                LabeledContent("默认保存目录") {
                    HStack(spacing: 8) {
                        Text(recordingDirectoryDisplayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…") {
                            chooseRecordingDirectory()
                        }
                    }
                    .frame(maxWidth: 330, alignment: .trailing)
                }

                Toggle(
                    "默认录制系统声音",
                    isOn: $recordingSettings.capturesSystemAudio
                )
                .disabled(!recordingSettings.format.supportsAudio)
                Toggle(
                    "默认录制麦克风",
                    isOn: $recordingSettings.capturesMicrophone
                )
                .disabled(!recordingSettings.format.supportsAudio)
                Toggle("默认显示鼠标指针", isOn: $recordingSettings.showsCursor)

                if recordingSettings.format == .gif {
                    Text("GIF 不包含音轨，并会限制帧率、最长边和录制时长；适合短操作演示。长录制或需要声音时请选择 MP4。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("窗口内快捷键（固定）") {
                LabeledContent("翻译输入内容", value: "⌘↩︎")
                LabeledContent("复制译文", value: "⇧⌘C")
                LabeledContent("清空并聚焦原文", value: "⌘K")
            }

            HStack {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 620, height: 780)
        .task { load() }
    }

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

    private var recordingQualitySummary: String {
        RecordingSettingsPresentation.qualitySummary(recordingSettings)
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
