import AppKit
import PolyglanceKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    @FocusState private var isSourceFocused: Bool
    @State private var hoveredSegmentID: Int?
    @State private var isEditingSource = false

    private let languages = [
        ("简体中文", "zh-CN"),
        ("英语", "en"),
        ("日语", "ja"),
        ("韩语", "ko"),
        ("法语", "fr"),
        ("德语", "de"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Polyglance")
                Text("Polyglance")
                    .font(.headline)
                Spacer()
                Picker("目标语言", selection: $viewModel.targetLanguage) {
                    ForEach(languages, id: \.1) { language in
                        Text(language.0).tag(language.1)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            GroupBox {
                if viewModel.translatedText.isEmpty || isEditingSource {
                    TextEditor(text: $viewModel.sourceText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($isSourceFocused)
                        .frame(minHeight: 120)
                        .padding(6)
                } else {
                    LinkedTranslationColumn(
                        segments: viewModel.alignedSegments,
                        side: .source,
                        hoveredSegmentID: $hoveredSegmentID
                    )
                    .frame(minHeight: 120)
                }
            } label: {
                HStack {
                    Text("原文")
                    Spacer()
                    if !viewModel.translatedText.isEmpty {
                        Button(isEditingSource ? "完成" : "编辑") {
                            isEditingSource.toggle()
                            if isEditingSource { isSourceFocused = true }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Text("全局快捷键可在设置中修改 · ⌘↩︎ 翻译")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("翻译") {
                    isEditingSource = false
                    Task { await viewModel.translate() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(viewModel.isTranslating)
            }

            GroupBox("译文") {
                ZStack(alignment: .topLeading) {
                    if viewModel.translatedText.isEmpty {
                        Text(viewModel.isTranslating ? "正在等待翻译内容…" : "翻译结果将在这里显示")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        LinkedTranslationColumn(
                            segments: viewModel.alignedSegments,
                            side: .target,
                            hoveredSegmentID: $hoveredSegmentID
                        )
                    }

                    if viewModel.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(minHeight: 120)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("清空") {
                    viewModel.clear()
                    isEditingSource = false
                    hoveredSegmentID = nil
                    isSourceFocused = true
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(viewModel.isTranslating)

                Spacer()
                Button("复制译文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.translatedText, forType: .string)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(viewModel.translatedText.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 470)
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
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(segments) { segment in
                    let text = side == .source ? segment.sourceText : segment.targetText
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(segment.id == hoveredSegmentID
                                          ? Color.accentColor.opacity(0.13)
                                          : Color.clear)
                            )
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.accentColor)
                                    .frame(height: segment.id == hoveredSegmentID ? 2 : 0)
                                    .padding(.horizontal, 7)
                            }
                            .contentShape(Rectangle())
                            .onHover { isHovering in
                                if isHovering {
                                    hoveredSegmentID = segment.id
                                } else if hoveredSegmentID == segment.id {
                                    hoveredSegmentID = nil
                                }
                            }
                            .accessibilityHint("悬停时高亮对应的原文和译文")
                    }
                }
            }
            .padding(2)
        }
    }
}
