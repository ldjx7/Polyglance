import AppKit
import CoreGraphics

struct LongScreenshotConfiguration: Equatable, Sendable {
    var captureInterval: TimeInterval
    var maximumFrameCount: Int
    var maximumOutputWidth: Int
    var maximumOutputHeight: Int
    var maximumPixelCount: Int
    var maximumWorkingBytes: Int
    var minimumOverlapRows: Int
    var maximumScrollFraction: Double
    var matchThreshold: Double

    static let `default` = Self(
        captureInterval: 0.18,
        maximumFrameCount: 240,
        maximumOutputWidth: 32_768,
        maximumOutputHeight: 32_768,
        maximumPixelCount: 80_000_000,
        maximumWorkingBytes: 384 * 1_024 * 1_024,
        minimumOverlapRows: 32,
        maximumScrollFraction: 0.8,
        matchThreshold: 0.035
    )
}

enum LongScreenshotDirection: Int, CaseIterable, Equatable, Sendable {
    case vertical
    case horizontal

    var title: String {
        switch self {
        case .vertical: return "纵向"
        case .horizontal: return "横向"
        }
    }
}

struct LongScreenshotCaptureRegion: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let globalRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    static func make(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        selection: CGRect,
        backingScaleFactor: CGFloat
    ) -> Self? {
        guard screenFrame.width > 0,
              screenFrame.height > 0,
              backingScaleFactor.isFinite,
              backingScaleFactor > 0 else {
            return nil
        }
        let clippedSelection = selection.standardized.intersection(screenFrame.standardized)
        guard !clippedSelection.isNull,
              clippedSelection.width > 0,
              clippedSelection.height > 0 else {
            return nil
        }

        let sourceRect = CGRect(
            x: clippedSelection.minX - screenFrame.minX,
            y: screenFrame.maxY - clippedSelection.maxY,
            width: clippedSelection.width,
            height: clippedSelection.height
        )
        let pixelWidth = Int((sourceRect.width * backingScaleFactor).rounded())
        let pixelHeight = Int((sourceRect.height * backingScaleFactor).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        return Self(
            displayID: displayID,
            sourceRect: sourceRect,
            globalRect: clippedSelection,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    @MainActor
    static func make(selection: CGRect, on screen: NSScreen) -> Self? {
        guard let displayNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return make(
            displayID: CGDirectDisplayID(displayNumber.uint32Value),
            screenFrame: screen.frame,
            selection: selection,
            backingScaleFactor: screen.backingScaleFactor
        )
    }
}

struct LongScreenshotPreview {
    let image: NSImage
    let direction: LongScreenshotDirection
    let frameCount: Int
    let totalPixelWidth: Int
    let totalPixelHeight: Int
    let viewportPixelWidth: Int
    let viewportPixelHeight: Int
    let viewportPixelOffset: Int
}
