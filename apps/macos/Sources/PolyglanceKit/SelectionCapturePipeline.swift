import Foundation

public struct SelectionCapturePipeline {
    private let directReader: () -> String?
    private let copyReader: () async -> String?

    public init(
        directReader: @escaping () -> String?,
        copyReader: @escaping () async -> String?
    ) {
        self.directReader = directReader
        self.copyReader = copyReader
    }

    public func read() async -> String? {
        if let directText = normalized(directReader()) {
            return directText
        }
        return normalized(await copyReader())
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }
}
