import XCTest
@testable import PolyglanceKit

final class TranslationMemoryCacheTests: XCTestCase {
    func testCacheSeparatesProvidersAndNeverNeedsAnAPIKeyInItsKey() async {
        let cache = TranslationMemoryCache(capacity: 4)
        let request = AppTranslationRequest(
            text: "Hello",
            sourceLanguage: "en",
            targetLanguage: "zh-CN"
        )
        let microsoft = TranslationCacheKey(
            provider: "microsoft",
            endpoint: "",
            model: "",
            request: request
        )
        let google = TranslationCacheKey(
            provider: "google",
            endpoint: "",
            model: "",
            request: request
        )
        let result = AppTranslationResult(
            text: "你好",
            provider: "microsoft",
            elapsedMilliseconds: 18
        )

        await cache.insert(result, for: microsoft)

        let microsoftValue = await cache.value(for: microsoft)
        let googleValue = await cache.value(for: google)
        XCTAssertEqual(microsoftValue, result)
        XCTAssertNil(googleValue)
    }

    func testCacheUsesLeastRecentlyUsedEviction() async {
        let cache = TranslationMemoryCache(capacity: 2)
        let first = key(text: "one")
        let second = key(text: "two")
        let third = key(text: "three")
        await cache.insert(result(text: "一"), for: first)
        await cache.insert(result(text: "二"), for: second)
        _ = await cache.value(for: first)

        await cache.insert(result(text: "三"), for: third)

        let firstValue = await cache.value(for: first)
        let secondValue = await cache.value(for: second)
        let thirdValue = await cache.value(for: third)
        XCTAssertNotNil(firstValue)
        XCTAssertNil(secondValue)
        XCTAssertNotNil(thirdValue)
    }

    func testZeroCapacityCacheStoresNothing() async {
        let cache = TranslationMemoryCache(capacity: 0)
        let key = key(text: "private text")

        await cache.insert(result(text: "私密文本"), for: key)

        let value = await cache.value(for: key)
        XCTAssertNil(value)
    }

    private func key(text: String) -> TranslationCacheKey {
        TranslationCacheKey(
            provider: "microsoft",
            endpoint: "",
            model: "",
            request: AppTranslationRequest(
                text: text,
                sourceLanguage: nil,
                targetLanguage: "zh-CN"
            )
        )
    }

    private func result(text: String) -> AppTranslationResult {
        AppTranslationResult(text: text, provider: "microsoft", elapsedMilliseconds: 1)
    }
}
