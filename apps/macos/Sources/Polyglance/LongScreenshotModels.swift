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
        captureInterval: 0.033,
        maximumFrameCount: 10_000,
        maximumOutputWidth: 32_768,
        maximumOutputHeight: 32_768,
        maximumPixelCount: defaultWorkingBytes / 4,
        maximumWorkingBytes: defaultWorkingBytes,
        minimumOverlapRows: 32,
        maximumScrollFraction: 0.8,
        matchThreshold: 0.035
    )

    /// An eighth of physical memory, kept between 384 MB and 1.5 GB: enough
    /// for a 5K-wide capture many screens tall without starving the rest of
    /// the system. The pixel budget is what fits in it at four bytes a pixel.
    static let defaultWorkingBytes: Int = {
        let megabyte: UInt64 = 1_048_576
        let physical = ProcessInfo.processInfo.physicalMemory
        return Int(min(1_536 * megabyte, max(384 * megabyte, physical / 8)))
    }()
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
    /// The selection overlay draws a 3pt border and 8pt handles on the outer
    /// edge of the selection, so those pixels belong to the chrome and not to
    /// the page. ScreenCaptureKit is asked to exclude this application, but
    /// that exclusion is not guaranteed on every path (an unbundled build has
    /// no bundle identifier to match on), and a border baked into every frame
    /// is both ugly and constant texture the stitcher has to work around.
    /// Capturing just inside the chrome removes the failure mode entirely.
    static let overlayChromeGuard: CGFloat = 4
    static let trackingContextPadding: CGFloat = 400

    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let globalRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let cropTop: Int
    let cropBottom: Int
    let cropLeft: Int
    let cropRight: Int
    let selectionPixelWidth: Int
    let selectionPixelHeight: Int

    init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        globalRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int,
        cropTop: Int = 0,
        cropBottom: Int = 0,
        cropLeft: Int = 0,
        cropRight: Int = 0,
        selectionPixelWidth: Int? = nil,
        selectionPixelHeight: Int? = nil
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.globalRect = globalRect
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cropTop = cropTop
        self.cropBottom = cropBottom
        self.cropLeft = cropLeft
        self.cropRight = cropRight
        self.selectionPixelWidth = selectionPixelWidth ?? max(0, pixelWidth - cropLeft - cropRight)
        self.selectionPixelHeight = selectionPixelHeight ?? max(0, pixelHeight - cropTop - cropBottom)
    }

    static func make(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        selection: CGRect,
        backingScaleFactor: CGFloat,
        contextPadding: CGFloat = trackingContextPadding
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
        // A selection barely larger than the chrome would inset to nothing, so
        // the guard shrinks rather than inverting the rectangle.
        let guardInset = min(
            overlayChromeGuard,
            min(clippedSelection.width, clippedSelection.height) / 4
        )
        let capturedSelection = clippedSelection.insetBy(dx: guardInset, dy: guardInset)
        guard capturedSelection.width > 0, capturedSelection.height > 0 else {
            return nil
        }

        let selX = capturedSelection.minX - screenFrame.minX
        let selY = screenFrame.maxY - capturedSelection.maxY
        let selW = capturedSelection.width
        let selH = capturedSelection.height

        let trackTop = max(0, selY - contextPadding)
        let trackBottom = min(screenFrame.height, selY + selH + contextPadding)
        let sourceRect = CGRect(
            x: selX,
            y: trackTop,
            width: selW,
            height: trackBottom - trackTop
        )

        let trackTopPx = Int((trackTop * backingScaleFactor).rounded())
        let trackBottomPx = Int((trackBottom * backingScaleFactor).rounded())
        let selTopPx = Int((selY * backingScaleFactor).rounded())
        let selBottomPx = Int(((selY + selH) * backingScaleFactor).rounded())

        let pixelWidth = Int((selW * backingScaleFactor).rounded())
        let pixelHeight = trackBottomPx - trackTopPx
        let cropTop = max(0, selTopPx - trackTopPx)
        let cropBottom = max(0, trackBottomPx - selBottomPx)
        let selectionPixelHeight = selBottomPx - selTopPx

        guard pixelWidth > 0, pixelHeight > 0, selectionPixelHeight > 0 else {
            return nil
        }
        return Self(
            displayID: displayID,
            sourceRect: sourceRect,
            globalRect: clippedSelection,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            cropTop: cropTop,
            cropBottom: cropBottom,
            cropLeft: 0,
            cropRight: 0,
            selectionPixelWidth: pixelWidth,
            selectionPixelHeight: selectionPixelHeight
        )
    }

    @MainActor
    static func make(selection: CGRect, on screen: NSScreen, contextPadding: CGFloat = trackingContextPadding) -> Self? {
        guard let displayNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return make(
            displayID: CGDirectDisplayID(displayNumber.uint32Value),
            screenFrame: screen.frame,
            selection: selection,
            backingScaleFactor: screen.backingScaleFactor,
            contextPadding: contextPadding
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
