import Foundation

public struct TranslationCacheKey: Hashable, Sendable {
    public let provider: String
    public let endpoint: String
    public let model: String
    public let request: AppTranslationRequest

    public init(
        provider: String,
        endpoint: String,
        model: String,
        request: AppTranslationRequest
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.model = model
        self.request = request
    }
}

public actor TranslationMemoryCache {
    private let capacity: Int
    private var values: [TranslationCacheKey: AppTranslationResult] = [:]
    private var recency: [TranslationCacheKey] = []

    public init(capacity: Int = 256) {
        self.capacity = max(0, capacity)
    }

    public func value(for key: TranslationCacheKey) -> AppTranslationResult? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    public func insert(_ value: AppTranslationResult, for key: TranslationCacheKey) {
        guard capacity > 0 else { return }
        values[key] = value
        touch(key)
        while values.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            values.removeValue(forKey: oldest)
        }
    }

    public func removeAll() {
        values.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
    }

    private func touch(_ key: TranslationCacheKey) {
        recency.removeAll(where: { $0 == key })
        recency.append(key)
    }
}
