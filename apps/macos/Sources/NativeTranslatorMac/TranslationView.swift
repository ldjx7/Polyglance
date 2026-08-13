import AppKit
import NativeTranslatorMacKit
import SwiftUI

struct TranslationView: View {
    @ObservedObject var viewModel: TranslatorViewModel
    @FocusState private var isSourceFocused: Bool

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
                Label("Polyglance", systemImage: "character.book.closed")
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

            GroupBox("原文") {
                TextEditor(text: $viewModel.sourceText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($isSourceFocused)
                    .frame(minHeight: 120)
                    .padding(6)
            }

            HStack {
                Text("全局快捷键可在设置中修改 · ⌘↩︎ 翻译")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("翻译") {
                    Task { await viewModel.translate() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(viewModel.isTranslating)
            }

            GroupBox("译文") {
                ZStack(alignment: .topLeading) {
                    ScrollView {
                        Text(viewModel.translatedText.isEmpty ? "翻译结果将在这里显示" : viewModel.translatedText)
                            .foregroundStyle(viewModel.translatedText.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 120)

                    if viewModel.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("清空") {
                    viewModel.clear()
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
