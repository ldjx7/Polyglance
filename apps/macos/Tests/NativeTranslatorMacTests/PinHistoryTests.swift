import AppKit
import XCTest
@testable import NativeTranslatorMac

@MainActor
final class PinHistoryTests: XCTestCase {
    func testHistoryRestoresMostRecentlyClosedPinFirst() throws {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 1_000)
        )
        let first = makeSnapshot(marker: 1, estimatedBytes: 100)
        let second = makeSnapshot(marker: 2, estimatedBytes: 200)

        XCTAssertTrue(history.append(first))
        XCTAssertTrue(history.append(second))

        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 2)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 1)
        XCTAssertNil(history.popMostRecent())
    }

    func testHistoryEvictsOldestPinsWhenCountLimitIsExceeded() throws {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 2, maximumEstimatedBytes: 10_000)
        )

        XCTAssertTrue(history.append(makeSnapshot(marker: 1, estimatedBytes: 100)))
        XCTAssertTrue(history.append(makeSnapshot(marker: 2, estimatedBytes: 100)))
        XCTAssertTrue(history.append(makeSnapshot(marker: 3, estimatedBytes: 100)))

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 3)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 2)
        XCTAssertNil(history.popMostRecent())
    }

    func testHistoryEvictsOldestPinsUntilMemoryLimitIsSatisfied() throws {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 250)
        )

        XCTAssertTrue(history.append(makeSnapshot(marker: 1, estimatedBytes: 100)))
        XCTAssertTrue(history.append(makeSnapshot(marker: 2, estimatedBytes: 100)))
        XCTAssertTrue(history.append(makeSnapshot(marker: 3, estimatedBytes: 100)))

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.estimatedMemoryBytes, 200)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 3)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 2)
    }

    func testOversizedPinIsNotStoredOrAllowedToEvictExistingHistory() throws {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 250)
        )
        XCTAssertTrue(history.append(makeSnapshot(marker: 1, estimatedBytes: 100)))

        XCTAssertFalse(history.append(makeSnapshot(marker: 2, estimatedBytes: 251)))

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.estimatedMemoryBytes, 100)
        XCTAssertEqual(marker(of: try XCTUnwrap(history.popMostRecent())), 1)
    }

    func testInvalidLimitsDisableHistoryWithoutOverflowingAccounting() {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: -1, maximumEstimatedBytes: -1)
        )

        XCTAssertFalse(history.append(makeSnapshot(marker: 1, estimatedBytes: Int.max)))

        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.estimatedMemoryBytes, 0)
        XCTAssertFalse(history.canRestore)
    }

    func testRemoveAllReleasesSnapshotsAndMemoryAccounting() {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 1_000)
        )
        history.append(makeSnapshot(marker: 1, estimatedBytes: 100))
        history.append(makeSnapshot(marker: 2, estimatedBytes: 200))

        history.removeAll()

        XCTAssertEqual(history.count, 0)
        XCTAssertEqual(history.estimatedMemoryBytes, 0)
        XCTAssertFalse(history.canRestore)
    }

    func testMemoryEstimatorUsesBitmapPixelDimensionsInsteadOfLogicalPointSize() throws {
        let image = NSImage(size: CGSize(width: 2, height: 2))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 6,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        image.addRepresentation(bitmap)

        XCTAssertEqual(PinImageMemoryEstimator.estimatedBytes(for: image), 8 * 6 * 4)
    }

    func testSnapshotNormalizesInvalidOpacityAndNegativeInjectedCost() {
        let snapshot = PinWindowSnapshot(
            image: NSImage(size: CGSize(width: 20, height: 12)),
            frame: .zero,
            initialSize: CGSize(width: 20, height: 12),
            opacity: .nan,
            isLocked: false,
            isAlwaysOnTop: true,
            estimatedMemoryBytes: -100
        )

        XCTAssertEqual(snapshot.opacity, 1)
        XCTAssertEqual(snapshot.estimatedMemoryBytes, 0)
    }

    func testHistoryPreservesOCRTranslationPayloadAndDisplayMode() throws {
        let history = PinHistoryStore(
            limits: PinHistoryLimits(maximumCount: 10, maximumEstimatedBytes: 1_000_000)
        )
        let snapshot = PinWindowSnapshot(
            translationImage: NSImage(size: CGSize(width: 320, height: 180)),
            sourceText: "Hello world",
            translatedText: "你好，世界",
            displayMode: .original,
            frame: CGRect(x: 150, y: 180, width: 480, height: 270),
            initialSize: CGSize(width: 320, height: 180),
            opacity: 0.65,
            isLocked: true,
            isAlwaysOnTop: false,
            estimatedMemoryBytes: 1_024
        )

        XCTAssertTrue(history.append(snapshot))

        let restored = try XCTUnwrap(history.popMostRecent())
        guard case let .ocrTranslation(payload) = restored.content else {
            return XCTFail("Expected OCR translation history payload")
        }
        XCTAssertEqual(payload.sourceText, "Hello world")
        XCTAssertEqual(payload.translatedText, "你好，世界")
        XCTAssertEqual(payload.displayMode, .original)
        XCTAssertEqual(restored.frame, CGRect(x: 150, y: 180, width: 480, height: 270))
        XCTAssertEqual(restored.opacity, 0.65, accuracy: 0.001)
        XCTAssertTrue(restored.isLocked)
        XCTAssertFalse(restored.isAlwaysOnTop)
    }

    func testTranslationSnapshotMemoryCostIncludesSourceAndTranslatedText() {
        let image = NSImage(size: CGSize(width: 2, height: 3))
        let sourceText = "hello"
        let translatedText = "你好"

        let snapshot = PinWindowSnapshot(
            translationImage: image,
            sourceText: sourceText,
            translatedText: translatedText,
            displayMode: .translation,
            frame: .zero,
            initialSize: image.size,
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true
        )

        XCTAssertEqual(
            snapshot.estimatedMemoryBytes,
            2 * 3 * 4 + sourceText.utf8.count + translatedText.utf8.count
        )
    }

    private func makeSnapshot(marker: Int, estimatedBytes: Int) -> PinWindowSnapshot {
        PinWindowSnapshot(
            image: NSImage(size: CGSize(width: CGFloat(20 + marker), height: 12)),
            frame: CGRect(
                x: CGFloat(marker * 10),
                y: CGFloat(marker * 20),
                width: 200,
                height: 120
            ),
            initialSize: CGSize(width: 200, height: 120),
            opacity: 0.8,
            isLocked: false,
            isAlwaysOnTop: true,
            estimatedMemoryBytes: estimatedBytes
        )
    }

    private func marker(of snapshot: PinWindowSnapshot) -> Int {
        Int(snapshot.frame.minX / 10)
    }
}
