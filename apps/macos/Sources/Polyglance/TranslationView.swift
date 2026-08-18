import AppKit
import AVFoundation
import PolyglanceKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    @FocusState private var isSourceFocused: Bool
    @State private var hoveredSegmentID: Int?
    @State private var isEditingSource = false
    @State private var hasCopied = false
    @State private var isPinned = false
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

    var body: some View {
        VStack(spacing: 8) {
            // 1. 顶部单行整合栏（紧贴窗口顶部，与系统红绿灯垂直居中对齐）
            HStack(spacing: 8) {
                // 左侧安全边距避开系统红绿灯
                Spacer()
                    .frame(width: 52)

                Spacer()

                // 居中语言切换胶囊
                HStack(spacing: 6) {
                    Text("自动检测 / 英语")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                        )

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)

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
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
                        )
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(2)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

                Spacer()

                // 右侧置顶按钮
                Button {
                    isPinned.toggle()
                    if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0 is NSPanel }) {
                        window.level = isPinned ? .floating : .normal
                    }
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                        .padding(5)
                        .background(Circle().fill(Color.primary.opacity(isPinned ? 0.1 : 0.04)))
                }
                .buttonStyle(.plain)
                .help(isPinned ? "取消置顶" : "置顶窗口")
            }
            .padding(.top, 0)
            .padding(.horizontal, 4)

            // 2. 左右双栏对照卡片（Side-by-Side Dual-Column Cards）
            HStack(spacing: 12) {
                // 左栏：原文卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("原文", systemImage: "doc.text")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        if !viewModel.sourceText.isEmpty {
                            Text("(\(viewModel.sourceText.count) 字)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        if !viewModel.sourceText.isEmpty {
                            Button {
                                speakText(viewModel.sourceText)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("朗读原文")

                            Button {
                                viewModel.clear()
                                isEditingSource = false
                                hoveredSegmentID = nil
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
                    .padding(.horizontal, 6)

                    ZStack(alignment: .topLeading) {
                        if viewModel.sourceText.isEmpty {
                            Text("输入或粘贴要翻译的内容…")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(6)
                        }

                        if viewModel.translatedText.isEmpty || isEditingSource {
                            TextEditor(text: $viewModel.sourceText)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .focused($isSourceFocused)
                                .padding(2)
                        } else {
                            LinkedTranslationColumn(
                                segments: viewModel.alignedSegments,
                                side: .source,
                                hoveredSegmentID: $hoveredSegmentID
                            )
                            .padding(2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )

                // 右栏：译文卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("译文", systemImage: "character.book.closed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if viewModel.isTranslating {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        if !viewModel.translatedText.isEmpty {
                            Button {
                                speakText(viewModel.translatedText)
                            } label: {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("朗读译文")
                        }
                    }
                    .padding(.horizontal, 6)

                    ZStack(alignment: .topLeading) {
                        if viewModel.translatedText.isEmpty {
                            Text(viewModel.isTranslating ? "正在思考与翻译…" : "翻译结果将在这里呈现")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(6)
                        } else {
                            LinkedTranslationColumn(
                                segments: viewModel.alignedSegments,
                                side: .target,
                                hoveredSegmentID: $hoveredSegmentID
                            )
                            .padding(2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(hoveredSegmentID != nil ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.1), lineWidth: 0.5)
                )
            }
            .frame(minHeight: 180)

            if let errorMessage = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 6)
            }

            // 3. 底部居中悬浮胶囊动作条（清空、朗读、复制、翻译）
            HStack(spacing: 8) {
                // 撤销快捷支持
                Button {
                    viewModel.undo()
                } label: {
                    EmptyView()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .opacity(0)
                .frame(width: 0, height: 0)

                // 清空
                Button {
                    viewModel.clear()
                    isEditingSource = false
                    hoveredSegmentID = nil
                    isSourceFocused = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("清空全部 (⌘K)")
                .disabled(viewModel.sourceText.isEmpty && viewModel.translatedText.isEmpty)

                // 朗读
                Button {
                    let textToSpeak = viewModel.translatedText.isEmpty ? viewModel.sourceText : viewModel.translatedText
                    speakText(textToSpeak)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("朗读译文/原文")
                .disabled(viewModel.sourceText.isEmpty && viewModel.translatedText.isEmpty)

                Divider()
                    .frame(height: 14)

                // 复制译文
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.translatedText, forType: .string)
                    hasCopied = true
                    Task {
                        try? await Task.sleep(for: .milliseconds(1200))
                        hasCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(hasCopied ? "已复制" : "复制")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("复制译文 (⇧⌘C)")
                .disabled(viewModel.translatedText.isEmpty)

                // 翻译按钮
                Button {
                    isEditingSource = false
                    Task { await viewModel.translate() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .bold))
                        Text("翻译")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("发起翻译 (⌘↩︎)")
                .disabled(viewModel.isTranslating)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 4, y: 2)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .background(.ultraThinMaterial)
        .frame(minWidth: 580, minHeight: 350)
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

