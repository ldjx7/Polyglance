import AppKit
import PolyglanceKit
import UniformTypeIdentifiers

struct PinWindowManagerState: Equatable {
    let activePinCount: Int
    let visiblePinCount: Int
    let hiddenPinCount: Int
    let historyCount: Int

    var canRestoreMostRecent: Bool { historyCount > 0 }
}

@MainActor
final class PinWindowManager: NSObject, NSWindowDelegate {
    private static let minimumOCRSelectionPinSize = CGSize(width: 240, height: 140)
    private var panels: [ObjectIdentifier: NSPanel] = [:]
    private var panelOrder: [ObjectIdentifier] = []
    private var destroyingPanels: Set<ObjectIdentifier> = []
    private let historyStore: PinHistoryStore

    override init() {
        historyStore = PinHistoryStore()
        super.init()
    }

    init(historyStore: PinHistoryStore) {
        self.historyStore = historyStore
        super.init()
    }

    var state: PinWindowManagerState {
        let visiblePinCount = panels.values.count(where: \.isVisible)
        return PinWindowManagerState(
            activePinCount: panels.count,
            visiblePinCount: visiblePinCount,
            hiddenPinCount: panels.count - visiblePinCount,
            historyCount: historyStore.count
        )
    }

    var canRestoreMostRecentPin: Bool { historyStore.canRestore }

    func pinClipboardImage() throws {
        guard let image = ImagePasteboard.read() else {
            throw PinImageError.clipboardHasNoImage
        }
        try validate(image)
        pin(image, sourceFrame: nil)
    }

    func pin(_ image: NSImage, sourceFrame: CGRect?) {
        guard let screen = targetScreen(for: sourceFrame) else {
            return
        }

        let maximumSize = CGSize(
            width: screen.visibleFrame.width * 0.72,
            height: screen.visibleFrame.height * 0.72
        )
        let fittedSize = CaptureGeometry.fittedPinSize(
            imageSize: image.size,
            maximumSize: maximumSize
        )
        let size = PinResizeGeometry.operableInitialSize(
            fittedSize,
            maximumSize: maximumSize
        )
        guard size.width > 0, size.height > 0 else {
            return
        }

        let origin = fittedOrigin(
            preferred: sourceFrame?.origin,
            size: size,
            visibleFrame: screen.visibleFrame
        )
        createPinWindow(
            image: image,
            initialSize: size,
            frame: CGRect(origin: origin, size: size),
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true
        )
    }

    @discardableResult
    func pinTranslation(
        image: NSImage,
        sourceText: String,
        translatedText: String,
        sourceFrame: CGRect?,
        isTranslating: Bool = false
    ) -> NSPanel? {
        guard image.size.width > 0,
              image.size.height > 0,
              let screen = targetScreen(for: sourceFrame) else {
            return nil
        }
        let maximumSize = CGSize(
            width: screen.visibleFrame.width * 0.72,
            height: screen.visibleFrame.height * 0.72
        )
        let fittedSize = CaptureGeometry.fittedPinSize(
            imageSize: image.size,
            maximumSize: maximumSize
        )
        let size = PinResizeGeometry.operableInitialSize(
            fittedSize,
            maximumSize: maximumSize
        )
        let resultCardSize = CGSize(
            width: min(
                maximumSize.width,
                max(OCRTranslationPinContentView.minimumResultCardSize.width, size.width)
            ),
            height: min(
                maximumSize.height,
                max(OCRTranslationPinContentView.minimumResultCardSize.height, size.height)
            )
        )
        guard resultCardSize.width > 0, resultCardSize.height > 0 else {
            return nil
        }
        let origin = Self.translationResultOrigin(
            sourceFrame: sourceFrame,
            cardSize: resultCardSize,
            visibleFrame: screen.visibleFrame
        )
        return createTranslationPinWindow(
            image: image,
            sourceText: sourceText,
            translatedText: translatedText,
            displayMode: .translation,
            initialSize: resultCardSize,
            frame: CGRect(origin: origin, size: resultCardSize),
            opacity: 1,
            isLocked: false,
            isAlwaysOnTop: true,
            isTranslating: isTranslating
        )
    }

    @discardableResult
    func pinOCRSelection(
        image: NSImage,
        document: OCRDocument,
        sourceFrame: CGRect?,
        translateHandler: @escaping @MainActor (String) -> Void
    ) -> NSPanel? {
        guard image.size.width > 0,
              image.size.height > 0,
              !document.items.isEmpty,
              let screen = targetScreen(for: sourceFrame) else {
            return nil
        }
        let maximumSize = CGSize(
            width: screen.visibleFrame.width * 0.9,
            height: screen.visibleFrame.height * 0.9
        )
        let standardizedSourceFrame = sourceFrame?.standardized
        let preferredSize = standardizedSourceFrame?.size ?? image.size
        let fittedSize = CaptureGeometry.fittedPinSize(
            imageSize: preferredSize,
            maximumSize: maximumSize
        )
        let aspectFittedSize = PinResizeGeometry.operableInitialSize(
            fittedSize,
            maximumSize: maximumSize
        )
        let size = CGSize(
            width: min(
                maximumSize.width,
                max(Self.minimumOCRSelectionPinSize.width, aspectFittedSize.width)
            ),
            height: min(
                maximumSize.height,
                max(Self.minimumOCRSelectionPinSize.height, aspectFittedSize.height)
            )
        )
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let preferredOrigin = standardizedSourceFrame.map { frame in
            CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        }
        let origin = fittedOrigin(
            preferred: preferredOrigin,
            size: size,
            visibleFrame: screen.visibleFrame
        )
        return createOCRSelectionPinWindow(
            image: image,
            document: document,
            translateHandler: translateHandler,
            initialSize: size,
            frame: CGRect(origin: origin, size: size),
            opacity: 1
        )
    }

    @discardableResult
    func createPinWindow(
        image: NSImage,
        initialSize: CGSize,
        frame: CGRect,
        opacity: CGFloat,
        isLocked: Bool,
        isAlwaysOnTop: Bool
    ) -> NSPanel {
        let panel = PinPanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = initialSize
        let sizeLimits = PinResizeGeometry.sizeLimits(for: initialSize)
        panel.contentMinSize = sizeLimits.minimum
        panel.contentMaxSize = sizeLimits.maximum
        panel.delegate = self

        let actions = makeActions(for: panel)
        panel.contentView = PinContentView(
            image: image,
            initialSize: initialSize,
            isLocked: isLocked,
            isAlwaysOnTop: isAlwaysOnTop,
            actions: actions
        )
        panel.alphaValue = min(1, max(0.1, opacity.isFinite ? opacity : 1))

        let identifier = ObjectIdentifier(panel)
        panels[identifier] = panel
        panelOrder.append(identifier)
        panel.orderFrontRegardless()
        return panel
    }

    @discardableResult
    func createTranslationPinWindow(
        image: NSImage,
        sourceText: String,
        translatedText: String,
        displayMode: OCRTranslationDisplayMode,
        initialSize: CGSize,
        frame: CGRect,
        opacity: CGFloat,
        isLocked: Bool,
        isAlwaysOnTop: Bool,
        isTranslating: Bool = false
    ) -> NSPanel {
        let usableSize = CGSize(
            width: max(frame.width, OCRTranslationPinContentView.minimumResultCardSize.width),
            height: max(frame.height, OCRTranslationPinContentView.minimumResultCardSize.height)
        )
        let usableFrame = CGRect(
            x: frame.midX - usableSize.width / 2,
            y: frame.midY - usableSize.height / 2,
            width: usableSize.width,
            height: usableSize.height
        )
        let panel = OCRTranslationPinPanel(
            contentRect: usableFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let sizeLimits = PinResizeGeometry.sizeLimits(for: initialSize)
        panel.contentMinSize = OCRTranslationPinContentView.minimumResultCardSize
        panel.contentMaxSize = sizeLimits.maximum
        panel.delegate = self
        panel.contentView = OCRTranslationPinContentView(
            image: image,
            sourceText: sourceText,
            translatedText: translatedText,
            displayMode: displayMode,
            initialSize: initialSize,
            isLocked: isLocked,
            isAlwaysOnTop: isAlwaysOnTop,
            isTranslating: isTranslating,
            actions: makeActions(for: panel)
        )
        panel.alphaValue = min(1, max(0.1, opacity.isFinite ? opacity : 1))

        let identifier = ObjectIdentifier(panel)
        panels[identifier] = panel
        panelOrder.append(identifier)
        panel.orderFrontRegardless()
        return panel
    }

    @discardableResult
    func createOCRSelectionPinWindow(
        image: NSImage,
        document: OCRDocument,
        translateHandler: @escaping @MainActor (String) -> Void,
        initialSize: CGSize,
        frame: CGRect,
        opacity: CGFloat
    ) -> NSPanel {
        let usableFrame = CGRect(
            x: frame.midX - max(frame.width, Self.minimumOCRSelectionPinSize.width) / 2,
            y: frame.midY - max(frame.height, Self.minimumOCRSelectionPinSize.height) / 2,
            width: max(frame.width, Self.minimumOCRSelectionPinSize.width),
            height: max(frame.height, Self.minimumOCRSelectionPinSize.height)
        )
        let panel = OCRSelectionPanel(
            contentRect: usableFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = usableFrame.size
        let sizeLimits = PinResizeGeometry.sizeLimits(for: usableFrame.size)
        panel.contentMinSize = Self.minimumOCRSelectionPinSize
        panel.contentMaxSize = sizeLimits.maximum
        panel.delegate = self

        let contentView = OCRSelectionResultView(
            image: image,
            document: document,
            translateHandler: translateHandler
        )
        contentView.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.closePin(panel)
        }
        panel.contentView = contentView
        panel.alphaValue = min(1, max(0.1, opacity.isFinite ? opacity : 1))

        let identifier = ObjectIdentifier(panel)
        panels[identifier] = panel
        panelOrder.append(identifier)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(contentView.canvasView)
        return panel
    }

    func closePin(_ panel: NSPanel) {
        guard panels[ObjectIdentifier(panel)] != nil else {
            return
        }
        panel.close()
    }

    func destroyPin(_ panel: NSPanel) {
        let identifier = ObjectIdentifier(panel)
        guard panels[identifier] != nil else {
            return
        }
        destroyingPanels.insert(identifier)
        panel.close()
    }

    func closeAllPins() {
        orderedPanels.forEach { $0.close() }
    }

    func destroyAllPins() {
        orderedPanels.forEach(destroyPin)
    }

    func hideAllPins() {
        orderedPanels.forEach { $0.orderOut(nil) }
    }

    func showAllPins() {
        orderedPanels.forEach { $0.orderFrontRegardless() }
    }

    func hideOtherPins(than selectedPanel: NSPanel) {
        orderedPanels
            .filter { $0 !== selectedPanel }
            .forEach { $0.orderOut(nil) }
        selectedPanel.orderFrontRegardless()
    }

    @discardableResult
    func restoreMostRecentPin() -> NSPanel? {
        guard let snapshot = historyStore.popMostRecent() else {
            return nil
        }
        let frame = frameForRestoration(snapshot.frame)
        switch snapshot.content {
        case let .image(image):
            return createPinWindow(
                image: image,
                initialSize: snapshot.initialSize,
                frame: frame,
                opacity: snapshot.opacity,
                isLocked: snapshot.isLocked,
                isAlwaysOnTop: snapshot.isAlwaysOnTop
            )
        case let .ocrSelection(content):
            return createOCRSelectionPinWindow(
                image: content.image,
                document: content.document,
                translateHandler: content.translateHandler,
                initialSize: snapshot.initialSize,
                frame: frame,
                opacity: snapshot.opacity
            )
        case let .ocrTranslation(content):
            return createTranslationPinWindow(
                image: content.image,
                sourceText: content.sourceText,
                translatedText: content.translatedText,
                displayMode: content.displayMode,
                initialSize: snapshot.initialSize,
                frame: frame,
                opacity: snapshot.opacity,
                isLocked: snapshot.isLocked,
                isAlwaysOnTop: snapshot.isAlwaysOnTop
            )
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel else {
            return
        }
        let identifier = ObjectIdentifier(panel)
        if destroyingPanels.remove(identifier) == nil {
            let snapshot: PinWindowSnapshot?
            if let contentView = panel.contentView as? PinContentView {
                snapshot = contentView.snapshot(frame: panel.frame, opacity: panel.alphaValue)
            } else if let contentView = panel.contentView as? OCRSelectionResultView {
                snapshot = contentView.snapshot(
                    frame: panel.frame,
                    initialSize: panel.contentAspectRatio,
                    opacity: panel.alphaValue
                )
            } else if let contentView = panel.contentView as? OCRTranslationPinContentView {
                snapshot = contentView.snapshot(frame: panel.frame, opacity: panel.alphaValue)
            } else {
                snapshot = nil
            }
            if let snapshot {
                historyStore.append(snapshot)
            }
        }
        panels.removeValue(forKey: identifier)
        panelOrder.removeAll { $0 == identifier }
    }

    private var orderedPanels: [NSPanel] {
        panelOrder.compactMap { panels[$0] }
    }

    private func makeActions(for panel: NSPanel) -> PinWindowActions {
        PinWindowActions(
            close: { [weak self, weak panel] in
                guard let panel else { return }
                self?.closePin(panel)
            },
            destroy: { [weak self, weak panel] in
                guard let panel else { return }
                self?.destroyPin(panel)
            },
            restoreMostRecent: { [weak self] in
                self?.restoreMostRecentPin()
            },
            closeAll: { [weak self] in self?.closeAllPins() },
            destroyAll: { [weak self] in self?.destroyAllPins() },
            hideOthers: { [weak self, weak panel] in
                guard let panel else { return }
                self?.hideOtherPins(than: panel)
            },
            hideAll: { [weak self] in self?.hideAllPins() },
            showAll: { [weak self] in self?.showAllPins() },
            currentState: { [weak self] in
                self?.state ?? PinWindowManagerState(
                    activePinCount: 0,
                    visiblePinCount: 0,
                    hiddenPinCount: 0,
                    historyCount: 0
                )
            }
        )
    }

    private func validate(_ image: NSImage) throws {
        let maximumPixelCount = 100_000_000
        let largestPixelCount = image.representations.map {
            max(0, $0.pixelsWide) * max(0, $0.pixelsHigh)
        }.max() ?? 0
        guard largestPixelCount <= maximumPixelCount else {
            throw PinImageError.imageTooLarge
        }
    }

    static func translationResultOrigin(
        sourceFrame: CGRect?,
        cardSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 12
    ) -> CGPoint {
        guard cardSize.width.isFinite,
              cardSize.height.isFinite,
              cardSize.width > 0,
              cardSize.height > 0 else {
            return visibleFrame.origin
        }
        guard let captureFrame = sourceFrame,
              captureFrame.origin.x.isFinite,
              captureFrame.origin.y.isFinite,
              captureFrame.width.isFinite,
              captureFrame.height.isFinite,
              captureFrame.width > 0,
              captureFrame.height > 0 else {
            return CGPoint(
                x: visibleFrame.midX - cardSize.width / 2,
                y: visibleFrame.midY - cardSize.height / 2
            )
        }

        let sourceFrame = captureFrame.standardized
        let x = min(
            max(sourceFrame.minX, visibleFrame.minX),
            visibleFrame.maxX - cardSize.width
        )
        let belowY = sourceFrame.minY - gap - cardSize.height
        if belowY >= visibleFrame.minY {
            return CGPoint(x: x, y: belowY)
        }
        let aboveY = sourceFrame.maxY + gap
        if aboveY + cardSize.height <= visibleFrame.maxY {
            return CGPoint(x: x, y: aboveY)
        }
        return CGPoint(
            x: x,
            y: min(
                max(sourceFrame.midY - cardSize.height / 2, visibleFrame.minY),
                visibleFrame.maxY - cardSize.height
            )
        )
    }

    private func targetScreen(for sourceFrame: CGRect?) -> NSScreen? {
        if let sourceFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) }) {
            return screen
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    private func fittedOrigin(
        preferred: CGPoint?,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let proposed = preferred ?? CGPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        return CGPoint(
            x: min(max(proposed.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposed.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    private func frameForRestoration(_ savedFrame: CGRect) -> CGRect {
        guard savedFrame.width.isFinite,
              savedFrame.height.isFinite,
              savedFrame.width > 0,
              savedFrame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(savedFrame) }) {
            return CGRect(
                origin: PinResizeGeometry.originKeepingWindowVisible(
                    proposedOrigin: savedFrame.origin,
                    windowSize: savedFrame.size,
                    visibleFrame: screen.visibleFrame
                ),
                size: savedFrame.size
            )
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return savedFrame
        }
        let size = CaptureGeometry.fittedPinSize(
            imageSize: savedFrame.size,
            maximumSize: CGSize(
                width: screen.visibleFrame.width * 0.9,
                height: screen.visibleFrame.height * 0.9
            )
        )
        return CGRect(
            origin: CGPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2
            ),
            size: size
        )
    }
}

enum ImagePasteboard {
    typealias ReplaceContents = (_ pasteboard: NSPasteboard, _ items: [NSPasteboardItem]) -> Bool

    static func read() -> NSImage? {
        let pasteboard = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data) {
                return image
            }
        }
        return NSImage(pasteboard: pasteboard)
    }

    static func write(
        _ image: NSImage,
        to pasteboard: NSPasteboard = .general,
        replaceContents: ReplaceContents? = nil
    ) throws {
        guard let data = pngData(for: image) else {
            throw PinImageError.imageEncodingFailed
        }
        let item = NSPasteboardItem()
        guard item.setData(data, forType: .png) else {
            throw PinImageError.clipboardWriteFailed
        }
        let previousItems = copiedItems(pasteboard.pasteboardItems)
        let replaceContents = replaceContents ?? { pasteboard, items in
            pasteboard.clearContents()
            return pasteboard.writeObjects(items)
        }
        guard replaceContents(pasteboard, [item]) else {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                _ = pasteboard.writeObjects(previousItems)
            }
            throw PinImageError.clipboardWriteFailed
        }
    }

    private static func copiedItems(_ items: [NSPasteboardItem]?) -> [NSPasteboardItem] {
        (items ?? []).map { source in
            let copy = NSPasteboardItem()
            for type in source.types {
                if let data = source.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private enum PinImageError: LocalizedError {
    case clipboardHasNoImage
    case imageTooLarge
    case imageEncodingFailed
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .clipboardHasNoImage:
            return "剪贴板中没有可贴出的图片"
        case .imageTooLarge:
            return "图片尺寸过大，无法安全贴图"
        case .imageEncodingFailed:
            return "无法将图片编码为 PNG"
        case .clipboardWriteFailed:
            return "无法将截图写入剪贴板"
        }
    }
}

struct PinWindowActions {
    typealias Action = @MainActor () -> Void
    typealias StateProvider = @MainActor () -> PinWindowManagerState

    let close: Action?
    let destroy: Action?
    let restoreMostRecent: Action?
    let closeAll: Action?
    let destroyAll: Action?
    let hideOthers: Action?
    let hideAll: Action?
    let showAll: Action?
    let currentState: StateProvider

    init(
        close: Action? = nil,
        destroy: Action? = nil,
        restoreMostRecent: Action? = nil,
        closeAll: Action? = nil,
        destroyAll: Action? = nil,
        hideOthers: Action? = nil,
        hideAll: Action? = nil,
        showAll: Action? = nil,
        currentState: @escaping StateProvider = {
            PinWindowManagerState(
                activePinCount: 1,
                visiblePinCount: 1,
                hiddenPinCount: 0,
                historyCount: 0
            )
        }
    ) {
        self.close = close
        self.destroy = destroy
        self.restoreMostRecent = restoreMostRecent
        self.closeAll = closeAll
        self.destroyAll = destroyAll
        self.hideOthers = hideOthers
        self.hideAll = hideAll
        self.showAll = showAll
        self.currentState = currentState
    }
}

@MainActor
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PinContentView: NSView {
    typealias CopyImage = @MainActor (NSImage) throws -> Void
    typealias SaveImage = @MainActor (NSImage) throws -> Bool
    typealias PresentError = @MainActor (Error) -> Void

    private let image: NSImage
    private let initialSize: CGSize
    private let copyImage: CopyImage
    private let saveImage: SaveImage
    private let presentError: PresentError
    private let actions: PinWindowActions
    private let colorPasteboard: NSPasteboard
    private let closeButton: NSButton
    private let colorMagnifierView: ScreenshotMagnifierView
    let annotationEditor: PinAnnotationOverlayView
    private var trackingAreaReference: NSTrackingArea?
    private var dragStartMouseLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var restoreResizableWhenUnlocked = true
    private var colorSampler: PixelSampler?
    private var colorDisplayFormat: ScreenshotColorDisplayFormat = .hex
    private(set) var isLocked: Bool
    private(set) var isAlwaysOnTop: Bool
    private(set) var isColorPicking = false
    private(set) var currentPixelSample: PixelSample?
    private(set) var magnifierPanel: NSPanel?

    init(
        image: NSImage,
        initialSize: CGSize? = nil,
        copyImage: @escaping CopyImage = { try ImagePasteboard.write($0) },
        saveImage: @escaping SaveImage = { try ScreenshotFileSaver().save($0) },
        presentError: @escaping PresentError = PinContentView.presentOperationError,
        colorPasteboard: NSPasteboard = .general,
        isLocked: Bool = false,
        isAlwaysOnTop: Bool = true,
        actions: PinWindowActions? = nil
    ) {
        self.image = image
        self.copyImage = copyImage
        self.saveImage = saveImage
        self.presentError = presentError
        self.actions = actions ?? PinWindowActions()
        self.colorPasteboard = colorPasteboard
        self.isLocked = isLocked
        self.isAlwaysOnTop = isAlwaysOnTop
        let proposedInitialSize = initialSize ?? image.size
        self.initialSize = proposedInitialSize.width > 0 && proposedInitialSize.height > 0
            ? proposedInitialSize
            : CGSize(width: 1, height: 1)
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭贴图")!,
            target: nil,
            action: nil
        )
        colorMagnifierView = ScreenshotMagnifierView(frame: CGRect(
            origin: .zero,
            size: ScreenshotMagnifierView.preferredSize
        ))
        annotationEditor = PinAnnotationOverlayView(sourceImage: image)
        super.init(frame: CGRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.masksToBounds = true

        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyUpOrDown
        closeButton.contentTintColor = .white
        closeButton.isHidden = true
        addSubview(closeButton)
        addSubview(annotationEditor)
        configureColorMagnifier()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let magnifierPanel, let window {
            window.removeChildWindow(magnifierPanel)
            magnifierPanel.orderOut(nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        let sizeLimits = PinResizeGeometry.sizeLimits(for: initialSize)
        window.contentAspectRatio = initialSize
        window.contentMinSize = sizeLimits.minimum
        window.contentMaxSize = sizeLimits.maximum
        applyAlwaysOnTopState()
        applyLockState()
        if isColorPicking {
            attachMagnifierPanelIfNeeded()
        }
    }

    private func configureColorMagnifier() {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: ScreenshotMagnifierView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = colorMagnifierView
        magnifierPanel = panel
    }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: bounds.maxX - 29, y: bounds.maxY - 29, width: 24, height: 24)
        annotationEditor.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = isColorPicking
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        hideColorMagnifier()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isColorPicking else {
            return
        }
        updateColorPicking(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if isColorPicking {
            clearDragState()
            updateColorPicking(at: convert(event.locationInWindow, from: nil))
            return
        }
        if event.clickCount >= 2 {
            clearDragState()
            closePin()
            return
        }
        guard !isLocked else {
            clearDragState()
            return
        }
        dragStartMouseLocation = screenLocation(for: event)
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              !isColorPicking,
              !isLocked,
              let dragStartMouseLocation,
              let dragStartWindowOrigin else {
            return
        }
        let currentLocation = screenLocation(for: event)
        let origin = CGPoint(
            x: dragStartWindowOrigin.x + currentLocation.x - dragStartMouseLocation.x,
            y: dragStartWindowOrigin.y + currentLocation.y - dragStartMouseLocation.y
        )
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(currentLocation) })?.visibleFrame
            ?? window.screen?.visibleFrame
        let constrainedOrigin = visibleFrame.map {
            PinResizeGeometry.originKeepingWindowVisible(
                proposedOrigin: origin,
                windowSize: window.frame.size,
                visibleFrame: $0
            )
        } ?? origin
        window.setFrameOrigin(constrainedOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        clearDragState()
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if isColorPicking {
            if event.keyCode == 53 {
                finishColorPicking()
                return
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.charactersIgnoringModifiers?.lowercased() == "c",
               modifiers.intersection([.command, .control, .option]).isEmpty {
                if modifiers.contains(.shift) {
                    colorDisplayFormat.toggle()
                    refreshColorMagnifier()
                } else {
                    copyCurrentColor()
                }
                return
            }
        }
        if event.characters == " " {
            toggleAnnotationEditing()
            return
        }
        super.keyDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        restoreInitialSize()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else {
            return
        }
        let anchor = event.window === window
            ? event.locationInWindow
            : window.convertPoint(fromScreen: event.locationInWindow)
        applyScroll(
            deltaY: event.scrollingDeltaY,
            modifiers: event.modifierFlags,
            anchorInWindow: anchor,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        )
    }

    override func magnify(with event: NSEvent) {
        applyMagnification(event.magnification)
    }

    func applyScroll(
        deltaY: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        anchorInWindow: CGPoint,
        hasPreciseScrollingDeltas: Bool = false
    ) {
        guard let window, deltaY.isFinite, deltaY != 0 else {
            return
        }
        let normalizedDelta = hasPreciseScrollingDeltas ? deltaY / 10 : deltaY
        if modifiers.contains(.command) {
            window.alphaValue = min(1, max(0.1, window.alphaValue + normalizedDelta * 0.05))
            return
        }
        guard !isLocked else {
            return
        }

        let sensitivity: CGFloat = modifiers.contains(.option) ? 0.025 : 0.1
        let boundedDelta = min(10, max(-10, normalizedDelta))
        resizeWindow(by: exp(boundedDelta * sensitivity), anchorInWindow: anchorInWindow)
    }

    func applyMagnification(_ magnification: CGFloat) {
        guard let window, !isLocked, magnification.isFinite else {
            return
        }
        let scale = max(0.5, min(1.5, 1 + magnification))
        resizeWindow(
            by: scale,
            anchorInWindow: CGPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        )
    }

    func updateColorPicking(at point: CGPoint) {
        guard isColorPicking,
              bounds.contains(point),
              let colorSampler,
              let sample = colorSampler.sample(atViewPoint: point, viewSize: bounds.size) else {
            hideColorMagnifier()
            return
        }
        currentPixelSample = sample
        colorMagnifierView.update(
            sampler: colorSampler,
            sample: sample,
            format: colorDisplayFormat
        )
        positionColorMagnifier(near: point)
    }

    private func beginColorPicking() {
        annotationEditor.finishEditing()
        let composedImage = annotationEditor.compositedImage()
        var proposedRect = CGRect(origin: .zero, size: composedImage.size)
        guard let image = composedImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ), let sampler = PixelSampler(image: image) else {
            NSSound.beep()
            return
        }
        colorSampler = sampler
        colorDisplayFormat = .hex
        currentPixelSample = nil
        isColorPicking = true
        closeButton.isHidden = true
        window?.makeKey()
        window?.makeFirstResponder(self)
        NSCursor.crosshair.set()
        attachMagnifierPanelIfNeeded()
    }

    private func finishColorPicking() {
        isColorPicking = false
        colorSampler = nil
        currentPixelSample = nil
        hideColorMagnifier()
        NSCursor.arrow.set()
    }

    private func refreshColorMagnifier() {
        guard let colorSampler, let currentPixelSample else { return }
        colorMagnifierView.update(
            sampler: colorSampler,
            sample: currentPixelSample,
            format: colorDisplayFormat
        )
    }

    private func copyCurrentColor() {
        guard let currentPixelSample else {
            NSSound.beep()
            return
        }
        let copied = currentPixelSample.text(format: colorDisplayFormat)
        colorPasteboard.clearContents()
        guard colorPasteboard.setString(copied, forType: .string) else {
            NSSound.beep()
            return
        }
        colorMagnifierView.showCopyConfirmation(copied)
    }

    private func attachMagnifierPanelIfNeeded() {
        guard let window, let magnifierPanel else { return }
        if !(window.childWindows?.contains(magnifierPanel) ?? false) {
            window.addChildWindow(magnifierPanel, ordered: .above)
        }
        magnifierPanel.level = window.level
    }

    private func positionColorMagnifier(near point: CGPoint) {
        guard let window, let magnifierPanel else { return }
        attachMagnifierPanelIfNeeded()
        let windowPoint = convert(point, to: nil)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let frame = ScreenshotMagnifierView.positionedFrame(
            near: screenPoint,
            in: visibleFrame
        )
        magnifierPanel.setFrame(frame, display: true)
        colorMagnifierView.frame = CGRect(origin: .zero, size: frame.size)
        colorMagnifierView.isHidden = false
        magnifierPanel.orderFrontRegardless()
    }

    private func hideColorMagnifier() {
        currentPixelSample = nil
        colorMagnifierView.isHidden = true
        magnifierPanel?.orderOut(nil)
    }

    @objc private func closePin() {
        finishColorPicking()
        if let close = actions.close {
            close()
        } else {
            window?.close()
        }
    }

    @objc private func destroyPin() {
        finishColorPicking()
        if let destroy = actions.destroy {
            destroy()
        } else {
            window?.close()
        }
    }

    @objc private func restoreMostRecentPin() {
        actions.restoreMostRecent?()
    }

    @objc private func closeAllPins() {
        actions.closeAll?()
    }

    @objc private func destroyAllPins() {
        actions.destroyAll?()
    }

    @objc private func hideOtherPins() {
        actions.hideOthers?()
    }

    @objc private func hideAllPins() {
        actions.hideAll?()
    }

    @objc private func showAllPins() {
        actions.showAll?()
    }

    private func clearDragState() {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    private func screenLocation(for event: NSEvent) -> CGPoint {
        guard let window, event.window === window else {
            return event.locationInWindow
        }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func resizeWindow(by scale: CGFloat, anchorInWindow: CGPoint) {
        guard let window else {
            return
        }
        let frame = PinResizeGeometry.scaledFrame(
            window.frame,
            requestedScale: scale,
            anchorInWindow: anchorInWindow,
            minimumSize: window.contentMinSize,
            maximumSize: window.contentMaxSize
        )
        window.setFrame(frame, display: true)
    }

    private func restoreInitialSize() {
        guard let window, !isLocked else {
            return
        }
        let oldFrame = window.frame
        let frame = CGRect(
            x: oldFrame.midX - initialSize.width / 2,
            y: oldFrame.midY - initialSize.height / 2,
            width: initialSize.width,
            height: initialSize.height
        )
        window.setFrame(frame, display: true)
    }

    @objc private func copyPin() {
        do {
            try copyImage(annotationEditor.compositedImage())
        } catch {
            presentError(error)
        }
    }

    @objc private func savePin() {
        do {
            _ = try saveImage(annotationEditor.compositedImage())
        } catch {
            presentError(error)
        }
    }

    private static func presentOperationError(_ error: Error) {
        OperationErrorPresenter().present(
            OperationErrorPresentation(
                title: "贴图操作失败",
                message: error.localizedDescription
            )
        )
    }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func toggleLock(_ sender: NSMenuItem) {
        isLocked.toggle()
        clearDragState()
        applyLockState()
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        isAlwaysOnTop.toggle()
        applyAlwaysOnTopState()
    }

    private func applyAlwaysOnTopState() {
        guard let window else {
            return
        }
        window.level = isAlwaysOnTop ? .floating : .normal
        (window as? NSPanel)?.isFloatingPanel = isAlwaysOnTop
    }

    private func applyLockState() {
        guard let window else {
            return
        }
        if isLocked {
            if window.styleMask.contains(.resizable) {
                restoreResizableWhenUnlocked = true
            }
            window.styleMask.remove(.resizable)
        } else if restoreResizableWhenUnlocked {
            window.styleMask.insert(.resizable)
        }
    }

    func snapshot(frame: CGRect, opacity: CGFloat) -> PinWindowSnapshot {
        PinWindowSnapshot(
            image: annotationEditor.compositedImage(),
            frame: frame,
            initialSize: initialSize,
            opacity: opacity,
            isLocked: isLocked,
            isAlwaysOnTop: isAlwaysOnTop
        )
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let annotationItem = menuItem(
            title: annotationEditor.isEditing ? "完成标注" : "标注",
            action: #selector(toggleAnnotationEditing),
            symbol: "pencil.tip.crop.circle",
            keyEquivalent: " ",
            modifiers: []
        )
        menu.addItem(annotationItem)

        let colorPickerItem = menuItem(
            title: isColorPicking ? "退出取色" : "取色",
            action: #selector(toggleColorPicking),
            symbol: "eyedropper"
        )
        colorPickerItem.state = isColorPicking ? .on : .off
        menu.addItem(colorPickerItem)
        menu.addItem(.separator())

        let lockItem = menuItem(
            title: isLocked ? "解锁贴图" : "锁定贴图",
            action: #selector(toggleLock(_:)),
            symbol: isLocked ? "lock.open" : "lock"
        )
        lockItem.state = isLocked ? .on : .off
        menu.addItem(lockItem)

        let alwaysOnTopItem = menuItem(
            title: isAlwaysOnTop ? "取消置顶" : "置顶贴图",
            action: #selector(toggleAlwaysOnTop(_:)),
            symbol: isAlwaysOnTop ? "pin.slash" : "pin"
        )
        alwaysOnTopItem.state = isAlwaysOnTop ? .on : .off
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "复制图片",
            action: #selector(copyPin),
            symbol: "doc.on.doc",
            keyEquivalent: "c"
        ))
        menu.addItem(menuItem(
            title: "另存为…",
            action: #selector(savePin),
            symbol: "square.and.arrow.down",
            keyEquivalent: "s"
        ))

        let opacityItem = menuItem(
            title: "透明度",
            action: nil,
            symbol: "slider.horizontal.3"
        )
        let opacityMenu = NSMenu()
        for value in [100, 80, 60, 40] {
            let item = NSMenuItem(
                title: "\(value)%",
                action: #selector(changeOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = value
            item.state = abs((window?.alphaValue ?? 1) - CGFloat(value) / 100) < 0.001
                ? .on
                : .off
            opacityMenu.addItem(item)
        }
        menu.setSubmenu(opacityMenu, for: opacityItem)
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let managerState = actions.currentState()

        // 批量管理子菜单
        let batchItem = menuItem(
            title: "批量管理",
            action: nil,
            symbol: "square.stack.3d.up"
        )
        let batchMenu = NSMenu()
        batchMenu.addItem(menuItem(
            title: "隐藏其他贴图",
            action: #selector(hideOtherPins),
            symbol: "eye.slash",
            isEnabled: actions.hideOthers != nil && managerState.activePinCount > 1
        ))
        batchMenu.addItem(menuItem(
            title: "隐藏全部贴图",
            action: #selector(hideAllPins),
            symbol: "eye.slash",
            isEnabled: actions.hideAll != nil && managerState.visiblePinCount > 0
        ))
        batchMenu.addItem(menuItem(
            title: "显示全部贴图",
            action: #selector(showAllPins),
            symbol: "eye",
            isEnabled: actions.showAll != nil && managerState.hiddenPinCount > 0
        ))
        batchMenu.addItem(.separator())
        batchMenu.addItem(menuItem(
            title: "关闭全部贴图",
            action: #selector(closeAllPins),
            symbol: "xmark.circle",
            isEnabled: actions.closeAll != nil && managerState.activePinCount > 0
        ))
        batchMenu.addItem(menuItem(
            title: "彻底销毁全部贴图",
            action: #selector(destroyAllPins),
            symbol: "trash",
            isEnabled: actions.destroyAll != nil && managerState.activePinCount > 0
        ))
        menu.setSubmenu(batchMenu, for: batchItem)
        menu.addItem(batchItem)

        menu.addItem(menuItem(
            title: "恢复最近关闭的贴图",
            action: #selector(restoreMostRecentPin),
            symbol: "arrow.uturn.backward",
            isEnabled: actions.restoreMostRecent != nil && managerState.canRestoreMostRecent
        ))
        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "关闭贴图",
            action: #selector(closePin),
            symbol: "xmark",
            keyEquivalent: "w",
            isEnabled: true
        ))
        menu.addItem(menuItem(
            title: "彻底销毁贴图",
            action: #selector(destroyPin),
            symbol: "trash",
            isEnabled: true
        ))

        menu.items.forEach { item in
            if item.target == nil && item.action != nil {
                item.target = self
            }
        }
        return menu
    }

    @objc private func toggleAnnotationEditing() {
        if isColorPicking {
            finishColorPicking()
        }
        annotationEditor.toggleEditing()
    }

    @objc private func toggleColorPicking() {
        isColorPicking ? finishColorPicking() : beginColorPicking()
    }

    private func menuItem(
        title: String,
        action: Selector?,
        symbol: String? = nil,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = isEnabled
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
        }
        return item
    }
}
