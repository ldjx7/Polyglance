import SwiftUI
import PolyglanceKit

struct TranslationHistorySheet: View {
    @ObservedObject var store: TranslationHistoryStore
    let onSelectRecord: (TranslationRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0 // 0: 历史, 1: 收藏
    @State private var searchText = ""

    private var filteredRecords: [TranslationRecord] {
        let base = selectedTab == 1 ? store.records.filter(\.isFavorite) : store.records
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return base
        }
        return base.filter {
            $0.sourceText.localizedCaseInsensitiveContains(searchText) ||
            $0.targetText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header
            HStack {
                Picker("", selection: $selectedTab) {
                    Text("历史记录 (\(store.records.count))").tag(0)
                    Text("收藏夹 (\(store.records.filter(\.isFavorite).count))").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                if !store.records.isEmpty && selectedTab == 0 {
                    Button("清空历史") {
                        store.clearAll()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索记录…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
            )
            .padding(.horizontal, 12)

            // List
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: selectedTab == 1 ? "star.slash" : "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(selectedTab == 1 ? "暂无收藏内容" : "暂无历史记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRecords) { record in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(record.sourceText)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    Button {
                                        store.toggleFavorite(id: record.id)
                                    } label: {
                                        Image(systemName: record.isFavorite ? "star.fill" : "star")
                                            .font(.system(size: 11))
                                            .foregroundStyle(record.isFavorite ? .yellow : .secondary)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        store.deleteRecord(id: record.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Text(record.targetText)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    if !record.provider.isEmpty {
                                        Text(record.provider)
                                            .font(.system(size: 9))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    Button("填入") {
                                        onSelectRecord(record)
                                        dismiss()
                                    }
                                    .font(.system(size: 10, weight: .medium))
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: 360, height: 420)
        .background(.regularMaterial)
    }
}
