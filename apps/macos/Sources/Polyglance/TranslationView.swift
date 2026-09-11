import AppKit
import AVFoundation
import PolyglanceKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    @ObservedObject private var historyStore = TranslationHistoryStore.shared
    @FocusState private var isSourceFocused: Bool
    @State private var copiedTargetProviderID: String? = nil
    @State private var hasCopiedSource = false
    @State private var isPinned = true
    @State private var isSourceCollapsed = false
    @State private var isHistoryPresented = false
    private let speechSynthesizer = AVSpeechSynthesizer()

    private let languages = [
        ("简体中文", "zh-CN"),
        ("英语", "en"),
        ("日语", "ja"),
        ("韩语", "ko"),
        ("法语", "fr"),
        ("德语", "de"),
        ("西班牙语", "es"),
        ("俄语", "ru"),
    ]

    @AppStorage("translation.provider") private var currentProviderRaw = TranslationProvider.freeAI.rawValue

    private var currentProvider: TranslationProvider {
        get { TranslationProvider(rawValue: currentProviderRaw) ?? .freeAI }
        set { currentProviderRaw = newValue.rawValue }
    }

    private let sourceLanguages = [
        ("自动检测", ""),
        ("英语 (EN)", "en"),
        ("中文 (ZH)", "zh-CN"),
        ("日语 (JA)", "ja"),
        ("韩语 (KO)", "ko"),
        ("法语 (FR)", "fr"),
        ("德语 (DE)", "de"),
        ("西班牙语", "es"),
        ("俄语 (RU)", "ru"),
    ]

    private var currentSourceLanguageDisplayName: String {
        if let code = viewModel.sourceLanguage, !code.isEmpty {
            return sourceLanguages.first(where: { $0.1 == code })?.0 ?? "自动检测"
        }
        return "自动检测"
    }

    private var isCurrentFavorite: Bool {
        historyStore.isFavorite(sourceText: viewModel.sourceText)
    }

    var body: some View {
        VStack(spacing: 8) {
            // 1. 顶部操作栏 (对齐 Bob: 紧凑无顶隙，左侧置顶，右侧工具，悬浮说明效果)
            HStack(spacing: 4) {
                // 1 钉住/取消钉住窗口
                TopBarIconButton(
                    icon: "pin",
                    tooltip: isPinned ? "取消固定窗口" : "固定窗口（失焦不自动关闭）",
                    isActive: isPinned,
                    activeColor: .accentColor,
                    isFilled: isPinned,
                    tooltipAlignment: .leading
                ) {
                    isPinned.toggle()
                    if let panel = (NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is NSPanel })) as? NSPanel {
                        panel.hidesOnDeactivate = !isPinned
                    }
                }

                Spacer()

                // 2 收藏相关
                TopBarMenuButton(
                    icon: "star",
                    tooltip: "收藏相关 (⌘S 收藏/取消收藏)",
                    isFilled: isCurrentFavorite,
                    activeColor: isCurrentFavorite ? .yellow : .secondary
                ) {
                    let menu = NSMenu()
                    menu.addItem(CallbackMenuItem(
                        title: isCurrentFavorite ? "取消收藏" : "收藏当前翻译 (⌘S)",
                        keyEquivalent: "s",
                        modifierMask: [.command]
                    ) {
                        historyStore.toggleFavoriteForCurrent(
                            sourceText: viewModel.sourceText,
                            targetText: viewModel.translatedText
                        )
                    })
                    menu.addItem(NSMenuItem.separator())
                    menu.addItem(CallbackMenuItem(title: "前往收藏夹") {
                        isHistoryPresented = true
                    })
                    return menu
                }

                // 3 历史记录
                TopBarIconButton(
                    icon: "clock",
                    tooltip: "翻译历史记录与收藏夹"
                ) {
                    isHistoryPresented = true
                }

                // 4 截图翻译
                TopBarIconButton(
                    icon: "scissors",
                    tooltip: "截图翻译"
                ) {
                    if let panel = (NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is NSPanel })) as? NSPanel {
                        panel.close()
                    }
                    (AppDelegate.shared ?? (NSApp.delegate as? AppDelegate))?.captureScreenTranslation()
                }

                // 5 剪贴板翻译
                TopBarIconButton(
                    icon: "doc.on.clipboard",
                    tooltip: "翻译剪贴板内容"
                ) {
                    if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                        viewModel.sourceText = clip
                        Task { await viewModel.translate() }
                    }
                }

                // 6 隐藏/显示输入框
                TopBarIconButton(
                    icon: isSourceCollapsed ? "eye.slash" : "eye",
                    tooltip: isSourceCollapsed ? "显示输入框" : "隐藏输入框",
                    isActive: isSourceCollapsed,
                    activeColor: .accentColor
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSourceCollapsed.toggle()
                    }
                }

                // 7 调整服务
                TopBarMenuButton(
                    icon: "checklist",
                    tooltip: "选择启用的翻译服务"
                ) {
                    let menu = NSMenu()
                    for raw in viewModel.providerOrder {
                        let isChecked = viewModel.enabledProviders.contains(raw)
                        let displayName = viewModel.displayName(for: raw)
                        menu.addItem(CallbackMenuItem(title: displayName, isChecked: isChecked) {
                            let wasChecked = viewModel.enabledProviders.contains(raw)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if wasChecked {
                                    viewModel.setProviderMode(provider: raw, mode: .closed)
                                } else {
                                    viewModel.setProviderMode(provider: raw, mode: .normal)
                                }
                            }
                            if var cfg = try? AppConfigurationStore().load() {
                                cfg.enabledProviders = viewModel.enabledProviders
                                cfg.providerDisplayModes = viewModel.providerModes
                                try? AppConfigurationStore().save(cfg)
                            }
                            if !wasChecked && !viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Task { await viewModel.translateNewlyAddedProvider(raw) }
                            }
                        })
                    }
                    return menu
                }

                // 8 快捷设置
                TopBarIconButton(
                    icon: "gearshape",
                    tooltip: "偏好设置",
                    tooltipAlignment: .trailing
                ) {
                    (AppDelegate.shared ?? (NSApp.delegate as? AppDelegate))?.showSettings()
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 28)

            // 2. 原文卡片 (Source Card) - 支持折叠收起 (6)
            if !isSourceCollapsed {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if viewModel.isOcrLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在识别屏幕文字…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.top, 6)
                            .padding(.leading, 6)
                        } else if viewModel.sourceText.isEmpty {
                            Text("输入或在此粘贴需要翻译的内容…")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.top, 4)
                                .padding(.leading, 4)
                        }

                        TextEditor(text: $viewModel.sourceText)
                            .font(.system(size: 13.5))
                            .scrollContentBackground(.hidden)
                            .focused($isSourceFocused)
                            .frame(minHeight: 60, maxHeight: 110)
                            .opacity(viewModel.isOcrLoading ? 0 : 1)
                    }

                    // 原文底部工具栏 (13, 14, 9)
                    HStack(spacing: 8) {
                        // 13 朗读原文
                        Button {
                            speakText(viewModel.sourceText)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("朗读文本")

                        // 14 复制原文
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewModel.sourceText, forType: .string)
                            hasCopiedSource = true
                            Task {
                                try? await Task.sleep(for: .milliseconds(1200))
                                hasCopiedSource = false
                            }
                        } label: {
                            Image(systemName: hasCopiedSource ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(hasCopiedSource ? Color.accentColor : Color.secondary)
                        .disabled(viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("复制文本")

                        Spacer()

                        // 9 自动检测原文语言，点击可切换语言 (对齐 Bob)
                        if let detected = viewModel.detectedLanguageDisplayName, !viewModel.sourceText.isEmpty {
                            Menu {
                                ForEach(sourceLanguages, id: \.1) { lang in
                                    Button(lang.0) {
                                        viewModel.sourceLanguage = lang.1.isEmpty ? nil : lang.1
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    (Text("识别为 ")
                                        .foregroundStyle(.secondary) +
                                    Text(detected)
                                        .foregroundStyle(Color.accentColor)
                                        .bold())
                                        .font(.system(size: 10))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.08)))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("自动检测原文语言，点击可切换语言")
                        }

                        // 清空原文
                        if !viewModel.sourceText.isEmpty {
                            Button {
                                viewModel.clear()
                                isSourceFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help("清空原文")
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }

            // 3. 中置语言与钉住服务工具栏 (10, 11, 12)
            HStack(spacing: 6) {
                // 10 原文语言
                Menu {
                    ForEach(sourceLanguages, id: \.1) { language in
                        Button {
                            viewModel.sourceLanguage = language.1.isEmpty ? nil : language.1
                        } label: {
                            HStack {
                                Text(language.0)
                                if (viewModel.sourceLanguage ?? "") == language.1 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(currentSourceLanguageDisplayName)
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.8)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("原文语言，即输入框内的语言")

                // 语言交换
                Button {
                    swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("交换语言")

                // 11 目标语言
                Menu {
                    ForEach(languages, id: \.1) { language in
                        Button {
                            viewModel.targetLanguage = language.1
                        } label: {
                            HStack {
                                Text(language.0)
                                if viewModel.targetLanguage == language.1 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(currentLanguageDisplayName)
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.8)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("目标语言，即译文语言")

                Spacer()

                // 12 钉住的服务，点击时触发 (对齐 Bob)
                HStack(spacing: 5) {
                    ForEach(viewModel.pinnedBarProviders, id: \.self) { prov in
                        Button {
                            Task { await viewModel.triggerPinnedProvider(prov) }
                        } label: {
                            ProviderBrandIcon(provider: prov, size: 14)
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        .help("钉住的服务：点击使用 \(viewModel.displayName(for: prov)) 翻译")
                    }
                }
            }
            .padding(.horizontal, 2)

            // 4. 多引擎结果卡片列表 (对齐 Bob: 垂直折叠多卡片 + 13朗读 + 14复制 + 15回填替换)
            ScrollView {
                VStack(spacing: 8) {
                    let states = viewModel.providerStates

                    ForEach(states) { state in
                        VStack(alignment: .leading, spacing: 6) {
                            // 卡片头部：引擎标识、转圈指示、折叠摘要、设置菜单、折叠按钮
                            HStack(spacing: 6) {
                                ProviderBrandIcon(provider: state.provider, size: 15)

                                Text(state.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary)

                                if state.isTranslating {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .padding(.leading, 2)
                                }

                                if state.isCollapsed && !state.text.isEmpty {
                                    Text(state.text.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }

                                Spacer()

                                // 设置菜单 (Image 2: 🎚️)
                                Menu {
                                    ForEach(ProviderDisplayMode.allCases, id: \.self) { mode in
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                viewModel.setProviderMode(provider: state.provider, mode: mode)
                                            }
                                            if var cfg = try? AppConfigurationStore().load() {
                                                cfg.providerDisplayModes = viewModel.providerModes
                                                cfg.enabledProviders = viewModel.enabledProviders
                                                try? AppConfigurationStore().save(cfg)
                                            }
                                        } label: {
                                            HStack {
                                                Text(mode.title)
                                                if (viewModel.providerModes[state.provider] ?? "normal") == mode.rawValue {
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .padding(4)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("设置服务显示与折叠模式")

                                // 折叠/展开按钮
                                Button {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                        viewModel.toggleProviderCollapse(provider: state.provider)
                                    }
                                } label: {
                                    Image(systemName: state.isCollapsed ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                                .help(state.isCollapsed ? "展开此卡片" : "折叠此卡片")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                    viewModel.toggleProviderCollapse(provider: state.provider)
                                }
                            }

                            if !state.isCollapsed {
                                Divider()
                                    .opacity(0.3)

                                // 卡片主体：译文内容
                                VStack(alignment: .leading, spacing: 4) {
                                    if state.text.isEmpty {
                                        Text(state.isTranslating ? "正在思考与翻译…" : "翻译结果将在这里呈现…")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.tertiary)
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                            .padding(.vertical, 3)
                                    } else {
                                        Text(state.text)
                                            .font(.system(size: 13.5))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .topLeading)
                                            .padding(.vertical, 2)
                                    }

                                    if let errorMessage = state.errorMessage {
                                        HStack(alignment: .top, spacing: 4) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.red)
                                            Text(errorMessage)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.red)
                                        }
                                        .padding(.top, 2)
                                    }
                                }

                                // 卡片底部操作栏 (13朗读、14复制、15回填替换)
                                HStack(spacing: 8) {
                                    // 13 朗读文本
                                    Button {
                                        speakText(state.text)
                                    } label: {
                                        Image(systemName: "speaker.wave.2")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .disabled(state.text.isEmpty)
                                    .help("朗读文本")

                                    // 14 复制文本
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(state.text, forType: .string)
                                        copiedTargetProviderID = state.provider
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(1200))
                                            if copiedTargetProviderID == state.provider {
                                                copiedTargetProviderID = nil
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: copiedTargetProviderID == state.provider ? "checkmark" : "doc.on.doc")
                                                .font(.system(size: 11))
                                            if copiedTargetProviderID == state.provider {
                                                Text("已复制")
                                                    .font(.system(size: 10, weight: .medium))
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(copiedTargetProviderID == state.provider ? Color.accentColor : Color.secondary)
                                    .disabled(state.text.isEmpty)
                                    .help("复制文本")

                                    // 15 将译文插入到原文的位置，替换掉原文，仅划词翻译时可用 (对齐 Bob)
                                    Button {
                                        TextReplacementService.replaceSelection(with: state.text)
                                    } label: {
                                        Image(systemName: "arrow.turn.down.left")
                                            .font(.system(size: 11, weight: .medium))
                                            .padding(3)
                                            .background(Circle().fill(Color.primary.opacity(0.04)))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color.accentColor)
                                    .disabled(state.text.isEmpty)
                                    .help("将译文插入到原文的位置，替换掉原文，仅划词翻译时可用")

                                    Spacer()
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .frame(minWidth: 380, idealWidth: 440, minHeight: 300)
        .onAppear {
            resizePanelForProviders()
        }
        .onChange(of: viewModel.providerStates.count) { _, _ in
            resizePanelForProviders()
        }
        .sheet(isPresented: $isHistoryPresented) {
            TranslationHistorySheet(store: historyStore) { record in
                viewModel.sourceText = record.sourceText
                Task {
                    await viewModel.translate()
                }
            }
        }
        .onChange(of: viewModel.translatedText) { _, newText in
            if !newText.isEmpty && !viewModel.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                historyStore.addRecord(
                    sourceText: viewModel.sourceText,
                    targetText: newText,
                    sourceLang: viewModel.sourceLanguage ?? "auto",
                    targetLang: viewModel.targetLanguage,
                    provider: viewModel.primaryProvider
                )
            }
        }
        .onAppear {
            if let config = try? AppConfigurationStore().load() {
                var customNames: [String: String] = [:]
                for c in config.customAIConfigs {
                    customNames[c.id] = c.name
                }
                viewModel.customAIDisplayNames = customNames
                viewModel.enabledProviders = config.enabledProviders.isEmpty ? ["free-ai"] : config.enabledProviders
                viewModel.primaryProvider = viewModel.enabledProviders.first ?? "free-ai"
            }
        }
    }

    private func resizePanelForProviders() {
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel }) as? NSPanel else { return }
        let count = max(1, viewModel.providerStates.count)
        let baseHeight: CGFloat = 340
        let perProvider: CGFloat = 110
        let idealHeight = baseHeight + CGFloat(count - 1) * perProvider
        let screen = panel.screen ?? NSScreen.main
        let maxH = (screen?.visibleFrame.height ?? 900) * 0.85
        let targetHeight = min(idealHeight, maxH)
        var frame = panel.frame
        let delta = targetHeight - frame.height
        if abs(delta) > 10 {
            frame.origin.y -= delta
            frame.size.height = targetHeight
            panel.setFrame(frame, display: true, animate: true)
        }
    }

    private func providerIconName(for provider: String) -> String {
        switch provider.lowercased() {
        case "freeai", "free-ai", "official-ai", "polyglance-ai": return "sparkles"
        case "microsoft": return "globe.americas.fill"
        case "google": return "g.circle.fill"
        case "deepl": return "d.circle.fill"
        case "baidu": return "pawprint.fill"
        case "youdao": return "character.book.closed.fill"
        case "volcano", "volcengine": return "flame.fill"
        case "openaicompatible", "openai-compatible": return "cpu"
        default: return "character.bubble"
        }
    }

    private func providerColor(for provider: String) -> Color {
        switch provider.lowercased() {
        case "freeai", "free-ai", "official-ai", "polyglance-ai": return .purple
        case "microsoft": return .blue
        case "google": return .teal
        case "deepl": return .indigo
        case "baidu": return .blue
        case "youdao": return .red
        case "volcano", "volcengine": return .orange
        case "openaicompatible", "openai-compatible": return .green
        default: return .accentColor
        }
    }

    private func providerBadgeLabel(for provider: String) -> String {
        switch provider.lowercased() {
        case "freeai", "free-ai", "official-ai", "polyglance-ai": return "官方 AI"
        case "microsoft": return "MS"
        case "google": return "Google"
        case "deepl": return "DeepL"
        case "baidu": return "百度"
        case "youdao": return "有道"
        case "volcano", "volcengine": return "火山"
        case "openaicompatible", "openai-compatible": return "OpenAI"
        default: return provider.prefix(3).uppercased()
        }
    }

    private func swapLanguages() {
        let currentTarget = viewModel.targetLanguage
        if let currentSource = viewModel.sourceLanguage, !currentSource.isEmpty {
            viewModel.sourceLanguage = currentTarget
            viewModel.targetLanguage = currentSource
        } else {
            viewModel.sourceLanguage = currentTarget
            viewModel.targetLanguage = "en"
        }
        let currentTargetText = viewModel.translatedText
        if !currentTargetText.isEmpty {
            viewModel.sourceText = currentTargetText
            Task {
                await viewModel.translate()
            }
        }
    }

    private var currentLanguageDisplayName: String {
        languages.first(where: { $0.1 == viewModel.targetLanguage })?.0 ?? "简体中文"
    }

    private func speakText(_ text: String) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        speechSynthesizer.speak(utterance)
    }
}

private enum TranslationColumnSide {
    case source
    case target
}

private struct LinkedTranslationColumn: View {
    let segments: [TranslationSegmentPair]
    let side: TranslationColumnSide
    @Binding var hoveredSegmentID: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(segments) { segment in
                    let text = side == .source ? segment.sourceText : segment.targetText
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(segment.id == hoveredSegmentID
                                          ? Color.accentColor.opacity(0.14)
                                          : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(segment.id == hoveredSegmentID
                                            ? Color.accentColor.opacity(0.4)
                                            : Color.clear, lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredSegmentID = segment.id
                                } else if hoveredSegmentID == segment.id {
                                    hoveredSegmentID = nil
                                }
                            }
                    }
                }
            }
            .padding(2)
        }
    }
}

// MARK: - Top Bar Icon Buttons (Bob Style with Instant Hover & Fast Tooltip)

private struct TopBarTooltipModifier: ViewModifier {
    let tooltip: String
    @Binding var isHovered: Bool
    var alignment: HorizontalAlignment = .center
    @State private var isVisible: Bool = false
    @State private var showTask: Task<Void, Never>? = nil

    func body(content: Content) -> some View {
        content
            .onChange(of: isHovered) { _, hovering in
                showTask?.cancel()
                if hovering {
                    showTask = Task {
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            isVisible = true
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.08)) {
                        isVisible = false
                    }
                }
            }
            .overlay(alignment: alignment == .leading ? .topLeading : (alignment == .trailing ? .topTrailing : .top)) {
                if isVisible {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1.5)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .fixedSize()
                        .offset(y: 30)
                        .allowsHitTesting(false)
                        .zIndex(999)
                }
            }
    }
}

private struct TopBarIconButton: View {
    let icon: String
    let tooltip: String
    var isActive: Bool = false
    var activeColor: Color = .accentColor
    var isFilled: Bool = false
    var tooltipAlignment: HorizontalAlignment = .center
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isFilled ? "\(icon).fill" : icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isActive ? activeColor : (isHovered ? Color.primary : Color.secondary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? activeColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .modifier(TopBarTooltipModifier(tooltip: tooltip, isHovered: $isHovered, alignment: tooltipAlignment))
    }
}

private final class MenuAnchorHolder {
    weak var view: NSView?

    func showMenu(_ menu: NSMenu) {
        guard let view else { return }
        let location = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: view)
    }
}

private struct MenuAnchorViewRepresentable: NSViewRepresentable {
    let holder: MenuAnchorHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}

private final class CallbackMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, isChecked: Bool = false, keyEquivalent: String = "", modifierMask: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(didSelect), keyEquivalent: keyEquivalent)
        self.target = self
        self.keyEquivalentModifierMask = modifierMask
        if isChecked {
            self.state = .on
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func didSelect() {
        handler()
    }
}

private struct TopBarMenuButton: View {
    let icon: String
    let tooltip: String
    var isFilled: Bool = false
    var activeColor: Color = .secondary
    var tooltipAlignment: HorizontalAlignment = .center
    let makeMenu: () -> NSMenu

    @State private var isHovered = false
    @State private var anchorHolder = MenuAnchorHolder()

    var body: some View {
        Button {
            anchorHolder.showMenu(makeMenu())
        } label: {
            Image(systemName: isFilled ? "\(icon).fill" : icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : activeColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorViewRepresentable(holder: anchorHolder))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .modifier(TopBarTooltipModifier(tooltip: tooltip, isHovered: $isHovered, alignment: tooltipAlignment))
    }
}
