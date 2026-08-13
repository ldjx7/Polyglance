import AppKit
import CoreGraphics

struct OCRSelectionLayout: Equatable, @unchecked Sendable {
    let imagePixelSize: CGSize
    let viewport: CGRect

    var imageRect: CGRect {
        guard Self.isUsable(imagePixelSize), Self.isUsable(viewport.size) else {
            return .zero
        }
        let scale = min(
            viewport.width / imagePixelSize.width,
            viewport.height / imagePixelSize.height
        )
        let size = CGSize(
            width: imagePixelSize.width * scale,
            height: imagePixelSize.height * scale
        )
        return CGRect(
            x: viewport.midX - size.width / 2,
            y: viewport.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Converts a Vision normalized lower-left rectangle into an unflipped
    /// AppKit view rectangle. Pixel scale does not enter the conversion after
    /// the aspect-fit rectangle has been calculated.
    func viewRect(forNormalizedRect normalizedRect: CGRect) -> CGRect {
        let imageRect = imageRect
        guard imageRect.width > 0, imageRect.height > 0 else {
            return .zero
        }
        let normalizedRect = normalizedRect.standardized
        return CGRect(
            x: imageRect.minX + normalizedRect.minX * imageRect.width,
            y: imageRect.minY + normalizedRect.minY * imageRect.height,
            width: normalizedRect.width * imageRect.width,
            height: normalizedRect.height * imageRect.height
        ).standardized
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }
}

struct OCRSelectionModel: Equatable, @unchecked Sendable {
    let document: OCRDocument
    private(set) var selectedItemIDs: Set<Int> = []

    var selectedText: String? {
        guard !selectedItemIDs.isEmpty else { return nil }
        return document.text(forItemIDs: selectedItemIDs)
    }

    var allText: String { document.plainText }

    mutating func select(
        from start: CGPoint,
        to end: CGPoint,
        layout: OCRSelectionLayout
    ) {
        guard Self.isFinite(start), Self.isFinite(end) else {
            selectedItemIDs = []
            return
        }

        let items = document.items
        if Self.isClick(start, end) {
            selectedItemIDs = Set(items.first(where: { item in
                layout.viewRect(forNormalizedRect: item.boundingBox).contains(end)
            }).map { [$0.id] } ?? [])
            return
        }

        guard let startIndex = anchorItemIndex(at: start, items: items, layout: layout),
              let endIndex = anchorItemIndex(at: end, items: items, layout: layout) else {
            selectedItemIDs = []
            return
        }
        let lower = min(startIndex, endIndex)
        let upper = max(startIndex, endIndex)
        selectedItemIDs = Set(items[lower...upper].map(\.id))
    }

    mutating func clearSelection() {
        selectedItemIDs = []
    }

    func selectedDragText(at point: CGPoint, layout: OCRSelectionLayout) -> String? {
        guard let selectedText else { return nil }
        let isInsideSelection = document.items.contains { item in
            selectedItemIDs.contains(item.id)
                && layout.viewRect(forNormalizedRect: item.boundingBox)
                    .insetBy(dx: -2, dy: -2)
                    .contains(point)
        }
        return isInsideSelection ? selectedText : nil
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isClick(_ start: CGPoint, _ end: CGPoint) -> Bool {
        abs(start.x - end.x) < 1 && abs(start.y - end.y) < 1
    }

    private func anchorItemIndex(
        at point: CGPoint,
        items: [OCRTextItem],
        layout: OCRSelectionLayout
    ) -> Int? {
        let maximumSquaredDistance: CGFloat = 32 * 32
        return items.indices
            .map { index in
                (
                    index: index,
                    distance: Self.squaredDistance(
                        from: point,
                        to: layout.viewRect(forNormalizedRect: items[index].boundingBox)
                    )
                )
            }
            .filter { $0.distance <= maximumSquaredDistance }
            .min { left, right in
                if left.distance != right.distance {
                    return left.distance < right.distance
                }
                return left.index < right.index
            }?.index
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

@MainActor
final class OCRSelectionCanvasView: NSView, NSDraggingSource {
    let image: NSImage

    private(set) var selectionModel: OCRSelectionModel
    var selectedItemIDs: Set<Int> {
        selectionModel.selectedItemIDs
    }

    var onCopy: ((String) -> Void)?
    var onSelectionChanged: ((String?) -> Void)?
    var onSelectionModeChanged: ((Bool) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onContextMenuRequested: ((NSEvent) -> Void)?
    var onAnnotationRequested: (() -> Void)?

    private var selectionStart: CGPoint?
    private var selectionEnd: CGPoint?
    private var dragStartMouseLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var pendingTextDrag: (start: CGPoint, text: String)?
    private let imagePixelSize: CGSize
    private(set) var isSelectionEnabled = true
    let showsIdleRecognitionGuides = false

    init(image: NSImage, document: OCRDocument) {
        self.image = image
        selectionModel = OCRSelectionModel(document: document)
        imagePixelSize = Self.pixelSize(of: image)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2, !isSelectionEnabled {
            onCloseRequested?()
            return
        }
        if event.modifierFlags.contains(.option) || !isSelectionEnabled {
            dragStartMouseLocation = window?.convertPoint(toScreen: event.locationInWindow)
            dragStartWindowOrigin = window?.frame.origin
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let text = selectionModel.selectedDragText(at: point, layout: selectionLayout) {
            pendingTextDrag = (point, text)
            return
        }
        selectionStart = point
        selectionEnd = point
        selectionModel.select(from: point, to: point, layout: selectionLayout)
        onSelectionChanged?(selectionModel.selectedText)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let window,
           let dragStartMouseLocation,
           let dragStartWindowOrigin {
            let current = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(CGPoint(
                x: dragStartWindowOrigin.x + current.x - dragStartMouseLocation.x,
                y: dragStartWindowOrigin.y + current.y - dragStartMouseLocation.y
            ))
            return
        }
        if let pendingTextDrag {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - pendingTextDrag.start.x, point.y - pendingTextDrag.start.y) >= 4 else {
                return
            }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(pendingTextDrag.text, forType: .string)
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let symbol = NSImage(
                systemSymbolName: "text.quote",
                accessibilityDescription: "拖出 OCR 文字"
            )
            draggingItem.setDraggingFrame(
                CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24),
                contents: symbol
            )
            self.pendingTextDrag = nil
            beginDraggingSession(with: [draggingItem], event: event, source: self)
            return
        }
        guard let selectionStart else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = point
        selectionModel.select(from: selectionStart, to: point, layout: selectionLayout)
        onSelectionChanged?(selectionModel.selectedText)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if pendingTextDrag != nil {
            pendingTextDrag = nil
            return
        }
        if dragStartMouseLocation != nil {
            clearDragState()
            return
        }
        guard let selectionStart else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        selectionEnd = point
        selectionModel.select(from: selectionStart, to: point, layout: selectionLayout)
        self.selectionStart = nil
        selectionEnd = nil
        onSelectionChanged?(selectionModel.selectedText)
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "w",
           modifiers == .command {
            onCloseRequested?()
            return true
        }
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            if modifiers == .command {
                copySelectedText()
                return true
            }
            if modifiers == .shift || modifiers == [.shift, .command] {
                copyAllText()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenuRequested?(event)
    }

    func copySelectedText() {
        guard let selectedText = selectionModel.selectedText else {
            NSSound.beep()
            return
        }
        onCopy?(selectedText)
    }

    func copyAllText() {
        onCopy?(selectionModel.allText)
    }

    func setSelectionEnabled(_ isEnabled: Bool) {
        isSelectionEnabled = isEnabled
        clearDragState()
        pendingTextDrag = nil
        if !isEnabled {
            selectionModel.clearSelection()
            selectionStart = nil
            selectionEnd = nil
            onSelectionChanged?(nil)
            needsDisplay = true
        }
        onSelectionModeChanged?(isEnabled)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if isSelectionEnabled {
                setSelectionEnabled(false)
            } else {
                onCloseRequested?()
            }
            return
        }
        if event.characters == " " {
            onAnnotationRequested?()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers == .shift {
            copyAllText()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let layout = selectionLayout
        image.draw(
            in: layout.imageRect,
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setLineWidth(1)
        for item in selectionModel.document.items where selectedItemIDs.contains(item.id) {
            let itemRect = layout.viewRect(forNormalizedRect: item.boundingBox)
            context?.setFillColor(NSColor.systemBlue.withAlphaComponent(0.28).cgColor)
            context?.fill(itemRect)
            context?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.95).cgColor)
            context?.stroke(itemRect)
        }
        if let selectionStart, let selectionEnd, !Self.isClick(selectionStart, selectionEnd) {
            context?.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context?.setLineDash(phase: 0, lengths: [4, 3])
            context?.stroke(Self.standardizedRect(from: selectionStart, to: selectionEnd))
        }
        context?.restoreGState()
    }

    private var selectionLayout: OCRSelectionLayout {
        OCRSelectionLayout(imagePixelSize: imagePixelSize, viewport: bounds)
    }

    private static func pixelSize(of image: NSImage) -> CGSize {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        if let image = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
            return CGSize(width: image.width, height: image.height)
        }
        if let representation = image.representations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), representation.pixelsWide > 0, representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }
        return image.size
    }

    private static func isClick(_ start: CGPoint, _ end: CGPoint) -> Bool {
        abs(start.x - end.x) < 1 && abs(start.y - end.y) < 1
    }

    private static func standardizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func clearDragState() {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

@MainActor
final class OCRSelectionResultView: NSView {
    let canvasView: OCRSelectionCanvasView
    let selectionModeButton: NSButton
    let copySelectionButton: NSButton
    let copyAllButton: NSButton
    let translateButton: NSButton
    let closeButton: NSButton
    let annotationEditor: PinAnnotationOverlayView
    private let contextualActions = NSVisualEffectView()

    var onClose: (() -> Void)?

    private let copyHandler: (String) -> Void
    private let translateHandler: (String) -> Void

    var document: OCRDocument { canvasView.selectionModel.document }
    var sourceImage: NSImage { canvasView.image }
    var contextualActionsHidden: Bool { contextualActions.isHidden }
    var contextualActionsFrame: CGRect { contextualActions.frame }

    init(
        image: NSImage,
        document: OCRDocument,
        copyHandler: @escaping (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        },
        translateHandler: @escaping (String) -> Void = { _ in }
    ) {
        canvasView = OCRSelectionCanvasView(image: image, document: document)
        selectionModeButton = Self.makeButton(title: "退出文字选择", symbol: "text.cursor")
        copySelectionButton = Self.makeButton(title: "复制", symbol: "doc.on.doc")
        copyAllButton = Self.makeButton(title: "复制全部", symbol: "doc.on.doc.fill")
        translateButton = Self.makeButton(title: "翻译", symbol: "character.bubble")
        closeButton = Self.makeButton(title: "关闭", symbol: "xmark")
        annotationEditor = PinAnnotationOverlayView(sourceImage: image)
        self.copyHandler = copyHandler
        self.translateHandler = translateHandler
        super.init(frame: .zero)

        canvasView.autoresizingMask = [.width, .height]
        addSubview(canvasView)

        selectionModeButton.target = self
        selectionModeButton.action = #selector(toggleSelectionMode)
        copySelectionButton.target = self
        copySelectionButton.action = #selector(copySelectedText)
        copySelectionButton.isEnabled = false
        copyAllButton.target = self
        copyAllButton.action = #selector(copyAllText)
        translateButton.target = self
        translateButton.action = #selector(translateText)
        closeButton.target = self
        closeButton.action = #selector(closePin)
        contextualActions.material = .hudWindow
        contextualActions.blendingMode = .withinWindow
        contextualActions.state = .active
        contextualActions.wantsLayer = true
        contextualActions.layer?.cornerRadius = 8
        contextualActions.layer?.masksToBounds = true
        contextualActions.isHidden = true
        let contextualStack = NSStackView(views: [copySelectionButton, translateButton])
        contextualStack.orientation = .horizontal
        contextualStack.alignment = .centerY
        contextualStack.spacing = 6
        contextualStack.frame = CGRect(x: 6, y: 4, width: 156, height: 28)
        contextualStack.autoresizingMask = [.width, .height]
        contextualActions.addSubview(contextualStack)
        addSubview(contextualActions)
        addSubview(annotationEditor)

        canvasView.onCopy = { [weak self] text in
            self?.copyHandler(text)
        }
        canvasView.onSelectionChanged = { [weak self] selectedText in
            self?.copySelectionButton.isEnabled = selectedText != nil
            self?.contextualActions.isHidden = selectedText == nil
        }
        canvasView.onSelectionModeChanged = { [weak self] isEnabled in
            self?.selectionModeButton.title = isEnabled ? "退出文字选择" : "选择文字"
        }
        canvasView.onCloseRequested = { [weak self] in
            self?.onClose?()
        }
        canvasView.onContextMenuRequested = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.makeContextMenu(), with: event, for: self.canvasView)
        }
        canvasView.onAnnotationRequested = { [weak self] in
            self?.toggleAnnotationEditing()
        }
        annotationEditor.onEditingChanged = { [weak self] isEditing in
            guard let self else { return }
            if isEditing {
                self.canvasView.setSelectionEnabled(false)
                self.contextualActions.isHidden = true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        canvasView.frame = bounds
        annotationEditor.frame = bounds
        contextualActions.frame = CGRect(
            x: max(8, bounds.maxX - 176),
            y: 10,
            width: 168,
            height: 36
        )
    }

    @objc private func copySelectedText() { canvasView.copySelectedText() }
    @objc private func copyAllText() { canvasView.copyAllText() }

    @objc private func translateText() {
        translateHandler(canvasView.selectionModel.selectedText ?? canvasView.selectionModel.allText)
    }

    @objc private func toggleSelectionMode() {
        if annotationEditor.isEditing {
            annotationEditor.finishEditing()
        }
        canvasView.setSelectionEnabled(!canvasView.isSelectionEnabled)
        selectionModeButton.title = canvasView.isSelectionEnabled ? "退出文字选择" : "选择文字"
    }

    @objc private func closePin() { onClose?() }

    @objc private func toggleAnnotationEditing() {
        if !annotationEditor.isEditing {
            canvasView.setSelectionEnabled(false)
        }
        annotationEditor.toggleEditing()
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem(
            title: canvasView.isSelectionEnabled ? "退出文字选择" : "选择文字",
            action: #selector(toggleSelectionMode)
        ))
        menu.addItem(menuItem(
            title: annotationEditor.isEditing ? "完成标注" : "标注",
            action: #selector(toggleAnnotationEditing)
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "复制全部文字", action: #selector(copyAllText)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "关闭贴图", action: #selector(closePin)))
        return menu
    }

    func snapshot(
        frame: CGRect,
        initialSize: CGSize,
        opacity: CGFloat
    ) -> PinWindowSnapshot {
        PinWindowSnapshot(
            ocrSelectionImage: annotationEditor.compositedImage(),
            document: document,
            translateHandler: translateHandler,
            frame: frame,
            initialSize: initialSize,
            opacity: opacity
        )
    }

    private static func makeButton(title: String, symbol: String) -> NSButton {
        let button = NSButton(
            title: title,
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
            target: nil,
            action: nil
        )
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}

@MainActor
final class OCRSelectionPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class OCRSelectionWindowManager: NSObject, NSWindowDelegate {
    private static let minimumContentSize = CGSize(width: 240, height: 140)
    private var panels: [ObjectIdentifier: OCRSelectionPanel] = [:]

    var activePanelCount: Int {
        panels.count
    }

    @discardableResult
    func present(
        image: NSImage,
        document: OCRDocument,
        sourceFrame: CGRect? = nil,
        translateHandler: @escaping (String) -> Void = { _ in }
    ) -> NSPanel? {
        guard Self.hasUsableImage(image), !document.items.isEmpty else {
            return nil
        }

        let frame = Self.initialFrame(for: image, sourceFrame: sourceFrame)
        let panel = OCRSelectionPanel(
            contentRect: frame,
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
        panel.minSize = Self.minimumContentSize
        let contentView = OCRSelectionResultView(
            image: image,
            document: document,
            translateHandler: translateHandler
        )
        contentView.onClose = { [weak panel] in
            panel?.close()
        }
        panel.contentView = contentView
        panel.delegate = self

        panels[ObjectIdentifier(panel)] = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(contentView.canvasView)
        return panel
    }

    func closeAll() {
        let retainedPanels = Array(panels.values)
        for panel in retainedPanels {
            panel.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? OCRSelectionPanel else {
            return
        }
        panels.removeValue(forKey: ObjectIdentifier(panel))
    }

    private static func hasUsableImage(_ image: NSImage) -> Bool {
        image.size.width.isFinite
            && image.size.height.isFinite
            && image.size.width > 0
            && image.size.height > 0
    }

    private static func initialContentSize(for image: NSImage) -> CGSize {
        let aspectRatio = image.size.width / image.size.height
        let width = min(980, max(520, image.size.width))
        let imageHeight = width / max(aspectRatio, 0.1)
        return CGSize(width: width, height: min(760, max(300, imageHeight)))
    }

    private static func initialFrame(for image: NSImage, sourceFrame: CGRect?) -> CGRect {
        if let sourceFrame,
           sourceFrame.width.isFinite,
           sourceFrame.height.isFinite,
           sourceFrame.width > 0,
           sourceFrame.height > 0 {
            let sourceFrame = sourceFrame.standardized
            let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(
                x: sourceFrame.midX,
                y: sourceFrame.midY
            )) }) ?? NSScreen.screens.first(where: { $0.frame.intersects(sourceFrame) })
            let available = screen?.visibleFrame.size ?? CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            let size = CGSize(
                width: min(available.width, max(minimumContentSize.width, sourceFrame.width)),
                height: min(available.height, max(minimumContentSize.height, sourceFrame.height))
            )
            let proposedOrigin = CGPoint(
                x: sourceFrame.midX - size.width / 2,
                y: sourceFrame.midY - size.height / 2
            )
            let origin: CGPoint
            if let visibleFrame = screen?.visibleFrame {
                origin = CGPoint(
                    x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
                    y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
                )
            } else {
                origin = proposedOrigin
            }
            return CGRect(origin: origin, size: size)
        }
        let contentSize = initialContentSize(for: image)
        var frame = CGRect(origin: .zero, size: contentSize)
        let screen = NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            frame.origin = CGPoint(
                x: visibleFrame.midX - contentSize.width / 2,
                y: visibleFrame.midY - contentSize.height / 2
            )
        }
        return frame
    }
}
