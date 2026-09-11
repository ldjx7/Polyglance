import Foundation

public struct TranslationRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var sourceText: String
    public var targetText: String
    public var sourceLang: String
    public var targetLang: String
    public var provider: String
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceText: String,
        targetText: String,
        sourceLang: String,
        targetLang: String,
        provider: String,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceText = sourceText
        self.targetText = targetText
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.provider = provider
        self.isFavorite = isFavorite
    }
}

@MainActor
public final class TranslationHistoryStore: ObservableObject {
    @Published public private(set) var records: [TranslationRecord] = []

    private let fileURL: URL

    public static let shared = TranslationHistoryStore()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Polyglance", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("translation_history.json")
        }
        load()
    }

    public func addRecord(
        sourceText: String,
        targetText: String,
        sourceLang: String,
        targetLang: String,
        provider: String
    ) {
        let trimmedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else { return }

        // Remove identical duplicate if at the very top
        if let first = records.first, first.sourceText == trimmedSource && first.targetText == trimmedTarget {
            return
        }

        let record = TranslationRecord(
            sourceText: trimmedSource,
            targetText: trimmedTarget,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: provider
        )
        records.insert(record, at: 0)
        if records.count > 100 {
            records = Array(records.prefix(100))
        }
        save()
    }

    public func toggleFavorite(id: UUID) {
        if let idx = records.firstIndex(where: { $0.id == id }) {
            records[idx].isFavorite.toggle()
            save()
        }
    }

    public func toggleFavoriteForCurrent(sourceText: String, targetText: String) {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = records.firstIndex(where: { $0.sourceText == trimmed }) {
            records[idx].isFavorite.toggle()
            save()
        } else if !trimmed.isEmpty && !targetText.isEmpty {
            let record = TranslationRecord(
                sourceText: trimmed,
                targetText: targetText,
                sourceLang: "",
                targetLang: "",
                provider: "",
                isFavorite: true
            )
            records.insert(record, at: 0)
            save()
        }
    }

    public func isFavorite(sourceText: String) -> Bool {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.first(where: { $0.sourceText == trimmed })?.isFavorite ?? false
    }

    public func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    public func clearAll() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([TranslationRecord].self, from: data) else {
            return
        }
        self.records = list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
