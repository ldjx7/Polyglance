import AppKit

struct PinHistoryLimits: Equatable {
    static let `default` = PinHistoryLimits(
        maximumCount: 20,
        maximumEstimatedBytes: 256 * 1_024 * 1_024
    )

    let maximumCount: Int
    let maximumEstimatedBytes: Int

    init(maximumCount: Int, maximumEstimatedBytes: Int) {
        self.maximumCount = max(0, maximumCount)
        self.maximumEstimatedBytes = max(0, maximumEstimatedBytes)
    }
}

struct OCRTranslationPinSnapshotContent {
    let image: NSImage
    let sourceText: String
    let translatedText: String
    let displayMode: OCRTranslationDisplayMode
}

struct OCRSelectionPinSnapshotContent {
    let image: NSImage
    let document: OCRDocument
    let translateHandler: @MainActor (String) -> Void
}

enum PinWindowSnapshotContent {
    case image(NSImage)
    case ocrSelection(OCRSelectionPinSnapshotContent)
    case ocrTranslation(OCRTranslationPinSnapshotContent)

    var image: NSImage {
        switch self {
        case let .image(image):
            return image
        case let .ocrSelection(content):
            return content.image
        case let .ocrTranslation(content):
            return content.image
        }
    }
}

struct PinWindowSnapshot {
    let content: PinWindowSnapshotContent
    let frame: CGRect
    let initialSize: CGSize
    let opacity: CGFloat
    let isLocked: Bool
    let isAlwaysOnTop: Bool
    let estimatedMemoryBytes: Int

    var image: NSImage { content.image }

    init(
        image: NSImage,
        frame: CGRect,
        initialSize: CGSize,
        opacity: CGFloat,
        isLocked: Bool,
        isAlwaysOnTop: Bool,
        estimatedMemoryBytes: Int? = nil
    ) {
        content = .image(image)
        self.frame = frame
        self.initialSize = initialSize
        self.opacity = min(1, max(0.1, opacity.isFinite ? opacity : 1))
        self.isLocked = isLocked
        self.isAlwaysOnTop = isAlwaysOnTop
        self.estimatedMemoryBytes = max(
            0,
            estimatedMemoryBytes ?? PinImageMemoryEstimator.estimatedBytes(for: image)
        )
    }

    init(
        ocrSelectionImage image: NSImage,
        document: OCRDocument,
        translateHandler: @escaping @MainActor (String) -> Void,
        frame: CGRect,
        initialSize: CGSize,
        opacity: CGFloat,
        estimatedMemoryBytes: Int? = nil
    ) {
        content = .ocrSelection(OCRSelectionPinSnapshotContent(
            image: image,
            document: document,
            translateHandler: translateHandler
        ))
        self.frame = frame
        self.initialSize = initialSize
        self.opacity = min(1, max(0.1, opacity.isFinite ? opacity : 1))
        isLocked = false
        isAlwaysOnTop = true
        let imageBytes = PinImageMemoryEstimator.estimatedBytes(for: image)
        let (calculatedBytes, overflow) = imageBytes.addingReportingOverflow(
            document.plainText.utf8.count
        )
        self.estimatedMemoryBytes = max(
            0,
            estimatedMemoryBytes ?? (overflow ? Int.max : calculatedBytes)
        )
    }

    init(
        translationImage image: NSImage,
        sourceText: String,
        translatedText: String,
        displayMode: OCRTranslationDisplayMode,
        frame: CGRect,
        initialSize: CGSize,
        opacity: CGFloat,
        isLocked: Bool,
        isAlwaysOnTop: Bool,
        estimatedMemoryBytes: Int? = nil
    ) {
        content = .ocrTranslation(OCRTranslationPinSnapshotContent(
            image: image,
            sourceText: sourceText,
            translatedText: translatedText,
            displayMode: displayMode
        ))
        self.frame = frame
        self.initialSize = initialSize
        self.opacity = min(1, max(0.1, opacity.isFinite ? opacity : 1))
        self.isLocked = isLocked
        self.isAlwaysOnTop = isAlwaysOnTop
        let calculatedMemoryBytes = PinImageMemoryEstimator.estimatedBytes(for: image)
        let (withSourceText, sourceOverflow) = calculatedMemoryBytes.addingReportingOverflow(
            sourceText.utf8.count
        )
        let (withTranslatedText, translationOverflow) = withSourceText.addingReportingOverflow(
            translatedText.utf8.count
        )
        self.estimatedMemoryBytes = max(
            0,
            estimatedMemoryBytes ?? (sourceOverflow || translationOverflow ? Int.max : withTranslatedText)
        )
    }
}

@MainActor
final class PinHistoryStore {
    private let limits: PinHistoryLimits
    private var snapshots: [PinWindowSnapshot] = []
    private(set) var estimatedMemoryBytes = 0

    init(limits: PinHistoryLimits = .default) {
        self.limits = limits
    }

    var count: Int { snapshots.count }
    var canRestore: Bool { !snapshots.isEmpty }

    @discardableResult
    func append(_ snapshot: PinWindowSnapshot) -> Bool {
        let cost = snapshot.estimatedMemoryBytes
        guard limits.maximumCount > 0,
              limits.maximumEstimatedBytes > 0,
              cost <= limits.maximumEstimatedBytes else {
            return false
        }

        while !snapshots.isEmpty,
              (snapshots.count >= limits.maximumCount
                  || estimatedMemoryBytes > limits.maximumEstimatedBytes - cost) {
            removeOldest()
        }
        guard snapshots.count < limits.maximumCount,
              estimatedMemoryBytes <= limits.maximumEstimatedBytes - cost else {
            return false
        }

        snapshots.append(snapshot)
        estimatedMemoryBytes += cost
        return true
    }

    func popMostRecent() -> PinWindowSnapshot? {
        guard let snapshot = snapshots.popLast() else {
            return nil
        }
        estimatedMemoryBytes = max(0, estimatedMemoryBytes - snapshot.estimatedMemoryBytes)
        return snapshot
    }

    func removeAll() {
        snapshots.removeAll(keepingCapacity: false)
        estimatedMemoryBytes = 0
    }

    private func removeOldest() {
        guard !snapshots.isEmpty else {
            return
        }
        let snapshot = snapshots.removeFirst()
        estimatedMemoryBytes = max(0, estimatedMemoryBytes - snapshot.estimatedMemoryBytes)
    }
}

enum PinImageMemoryEstimator {
    static func estimatedBytes(for image: NSImage) -> Int {
        let representationBytes = image.representations.reduce(into: 0) { total, representation in
            let width = max(0, representation.pixelsWide)
            let height = max(0, representation.pixelsHigh)
            let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
            guard !pixelOverflow, !byteOverflow else {
                total = Int.max
                return
            }
            let (sum, sumOverflow) = total.addingReportingOverflow(byteCount)
            total = sumOverflow ? Int.max : sum
        }
        if representationBytes > 0 {
            return representationBytes
        }

        let width = max(0, Int(image.size.width.rounded(.up)))
        let height = max(0, Int(image.size.height.rounded(.up)))
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow ? Int.max : byteCount
    }
}
