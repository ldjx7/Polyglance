import AppKit
import NativeTranslatorMacKit

@MainActor
private final class OCRTranslationContextTextView: NSTextView {
    var contextMenuProvider: (() -> NSMenu?)?
    var hoverCharacterHandler: ((Int?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?() ?? super.menu(for: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        hoverCharacterHandler?(characterIndex(at: convert(event.locationInWindow, from: nil)))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverCharacterHandler?(nil)
        super.mouseExited(with: event)
    }

    func setHighlightedRange(_ range: NSRange?) {
        guard let layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
        guard let range, range.length > 0, NSMaxRange(range) <= fullRange.length else { return }
        layoutManager.addTemporaryAttributes([
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.16),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemBlue,
        ], forCharacterRange: range)
    }

    private func characterIndex(at point: CGPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = CGPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).insetBy(dx: -3, dy: -3)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}

enum OCRTranslationDisplayMode: Equatable {
    case original
    case sourceText
    case translation
}

enum OCRTranslationPresentationStyle: Equatable {
    case youdaoResultCard
}

struct OCRTranslationPresentationModel: Equatable {
    let sourceText: String
    private(set) var translatedText: String
    private(set) var mode: OCRTranslationDisplayMode

    init(
        sourceText: String,
        translatedText: String,
        mode: OCRTranslationDisplayMode = .translation
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.mode = mode
    }

    var visibleText: String? {
        switch mode {
        case .original: nil
        case .sourceText: sourceText
        case .translation: translatedText
        }
    }

    mutating func showOriginal() {
        mode = .original
    }

    mutating func showTranslation() {
        mode = .translation
    }

    mutating func showSourceText() {
        mode = .sourceText
    }

    mutating func updateTranslation(_ text: String) {
        translatedText = text
    }
}

struct OCRScreenshotTranslator: Sendable {
    private let client: any TranslationClient

    init(client: any TranslationClient) {
        self.client = client
    }

    func translationUpdates(
        sourceText: String,
        targetLanguage: String
    ) -> AsyncThrowingStream<AppTranslationUpdate, Error> {
        client.translateStream(AppTranslationRequest(
            text: sourceText,
            sourceLanguage: nil,
            targetLanguage: targetLanguage
        ))
    }
}

@MainActor
final class OCRTranslationPinContentView: NSView {
    static let minimumResultCardSize = CGSize(width: 360, height: 240)
    private var model: OCRTranslationPresentationModel
    private let image: NSImage
    private let initialSize: CGSize
    private let pasteboard: NSPasteboard
    private let actions: PinWindowActions
    private let imageView: NSImageView
    private let translationOverlay: NSVisualEffectView
    private let translationTextView: OCRTranslationContextTextView
    private let sourceTextView: OCRTranslationContextTextView
    private let sourceScrollView: NSScrollView
    private let translationScrollView: NSScrollView
    private let headerLabel = NSTextField(labelWithString: "截图翻译")
    private let sourceLabel = NSTextField(labelWithString: "原文")
    private let translationLabel = NSTextField(labelWithString: "译文")
    private let toolbar: NSVisualEffectView
    let annotationEditor: PinAnnotationOverlayView
    private var actionButtons: [NSButton] = []
    private var dragStartMouseLocation: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var restoreResizableWhenUnlocked = true
    private var alignmentPairs: [TranslationSegmentPair]

    private(set) var mode: OCRTranslationDisplayMode = .translation
    private(set) var highlightedPairID: Int?
    private(set) var isLocked: Bool
    private(set) var isAlwaysOnTop: Bool
    private(set) var isTranslating: Bool

    var sourceText: String { model.sourceText }
    var originalImage: NSImage { image }
    var translationText: String { model.translatedText }
    var translationStatusText: String { headerLabel.stringValue }
    var visibleText: String? { model.visibleText }
    var isTranslationOverlayHidden: Bool { translationOverlay.isHidden }
    var isTranslationTextSelectable: Bool { translationTextView.isSelectable }
    var sourceContextText: String { sourceTextView.string }
    var showsSourceAlongsideTranslation: Bool {
        mode == .translation && !sourceScrollView.isHidden
    }
    let presentationStyle = OCRTranslationPresentationStyle.youdaoResultCard
    var translationSurfaceColor: NSColor { .windowBackgroundColor }
    var translationActionTitles: [String] { actionButtons.map(\.title) }
    var minimumResultCardSize: CGSize { Self.minimumResultCardSize }
    var visibleTextContextMenu: NSMenu? { makeContextMenu() }
    var highlightedSourceText: String? {
        alignmentPairs.first(where: { $0.id == highlightedPairID })?.sourceText
    }
    var highlightedTranslationText: String? {
        alignmentPairs.first(where: { $0.id == highlightedPairID })?.targetText
    }

    init(
        image: NSImage,
        sourceText: String,
        translatedText: String,
        displayMode: OCRTranslationDisplayMode = .translation,
        initialSize: CGSize? = nil,
        pasteboard: NSPasteboard = .general,
        isLocked: Bool = false,
        isAlwaysOnTop: Bool = true,
        isTranslating: Bool = false,
        actions: PinWindowActions? = nil
    ) {
        model = OCRTranslationPresentationModel(
            sourceText: sourceText,
            translatedText: translatedText,
            mode: displayMode
        )
        self.image = image
        let proposedInitialSize = initialSize ?? image.size
        self.initialSize = proposedInitialSize.width > 0 && proposedInitialSize.height > 0
            ? proposedInitialSize
            : CGSize(width: 1, height: 1)
        self.pasteboard = pasteboard
        self.isLocked = isLocked
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isTranslating = isTranslating
        self.actions = actions ?? PinWindowActions()
        alignmentPairs = TranslationAlignment.pairs(
            source: sourceText,
            target: translatedText
        )

        imageView = NSImageView(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        translationOverlay = NSVisualEffectView(frame: .zero)
        translationOverlay.material = .popover
        translationOverlay.blendingMode = .withinWindow
        translationOverlay.state = .active
        translationOverlay.wantsLayer = true
        translationOverlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        sourceTextView = Self.makeResultTextView(
            text: sourceText,
            color: .secondaryLabelColor,
            fontSize: 14
        )

        translationTextView = OCRTranslationContextTextView(frame: .zero)
        translationTextView.string = translatedText
        translationTextView.isEditable = false
        translationTextView.isSelectable = true
        translationTextView.drawsBackground = false
        translationTextView.textColor = .labelColor
        translationTextView.font = .systemFont(ofSize: 16, weight: .medium)
        translationTextView.textContainerInset = CGSize(width: 14, height: 14)
        translationTextView.isRichText = false
        translationTextView.allowsUndo = false
        translationTextView.minSize = .zero
        translationTextView.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        translationTextView.isVerticallyResizable = true
        translationTextView.isHorizontallyResizable = false
        translationTextView.autoresizingMask = [.width]
        translationTextView.textContainer?.widthTracksTextView = true

        sourceScrollView = Self.makeScrollView(documentView: sourceTextView)
        translationScrollView = Self.makeScrollView(documentView: translationTextView)
        headerLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        headerLabel.textColor = .labelColor
        headerLabel.stringValue = isTranslating ? "正在翻译…" : "截图翻译"
        sourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        translationLabel.font = .systemFont(ofSize: 11, weight: .medium)
        translationLabel.textColor = .secondaryLabelColor
        [headerLabel, sourceLabel, translationLabel, sourceScrollView, translationScrollView]
            .forEach(translationOverlay.addSubview)

        toolbar = NSVisualEffectView(frame: .zero)
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 9
        toolbar.layer?.masksToBounds = true
        annotationEditor = PinAnnotationOverlayView(sourceImage: image)

        super.init(frame: CGRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        translationOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(translationOverlay)
        NSLayoutConstraint.activate([
            translationOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            translationOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            translationOverlay.topAnchor.constraint(equalTo: topAnchor),
            translationOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configureToolbar()
        addSubview(annotationEditor)
        sourceTextView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        translationTextView.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        sourceTextView.hoverCharacterHandler = { [weak self] characterIndex in
            self?.updatePairHighlight(characterIndex: characterIndex, inSource: true)
        }
        translationTextView.hoverCharacterHandler = { [weak self] characterIndex in
            self?.updatePairHighlight(characterIndex: characterIndex, inSource: false)
        }
        applyMode()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let sizeLimits = PinResizeGeometry.sizeLimits(for: initialSize)
        window.contentAspectRatio = .zero
        window.contentMinSize = Self.minimumResultCardSize
        window.contentMaxSize = sizeLimits.maximum
        applyAlwaysOnTopState()
        applyLockState()
        applyMode()
    }

    override func layout() {
        super.layout()
        toolbar.frame = CGRect(
            x: max(8, bounds.maxX - 188),
            y: max(8, bounds.maxY - 42),
            width: min(180, max(0, bounds.width - 16)),
            height: 34
        )
        layoutResultCard()
        annotationEditor.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            closePin()
            return
        }
        guard !isLocked else { return }
        dragStartMouseLocation = window?.convertPoint(toScreen: event.locationInWindow)
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              !isLocked,
              let dragStartMouseLocation,
              let dragStartWindowOrigin else {
            return
        }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(
            x: dragStartWindowOrigin.x + current.x - dragStartMouseLocation.x,
            y: dragStartWindowOrigin.y + current.y - dragStartMouseLocation.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.characters == " " {
            toggleAnnotationEditing()
            return
        }
        super.keyDown(with: event)
    }

    func showOriginal() {
        model.showOriginal()
        mode = model.mode
        applyMode()
    }

    func showTranslation() {
        model.showTranslation()
        mode = model.mode
        applyMode()
    }

    func showSourceText() {
        model.showSourceText()
        mode = model.mode
        applyMode()
    }

    func updateTranslation(_ text: String, isFinal: Bool) {
        model.updateTranslation(text)
        translationTextView.string = text
        alignmentPairs = TranslationAlignment.pairs(source: sourceText, target: text)
        applyPairHighlight(nil)
        isTranslating = !isFinal
        headerLabel.stringValue = isFinal ? "截图翻译" : "正在翻译…"
        translationTextView.needsDisplay = true
        needsLayout = true
    }

    func selectTranslationRange(_ range: NSRange) {
        showTranslation()
        selectVisibleTextRange(range)
    }

    func highlightPairFromSourceCharacterIndex(_ characterIndex: Int) {
        updatePairHighlight(characterIndex: characterIndex, inSource: true)
    }

    func clearPairHighlight() {
        applyPairHighlight(nil)
    }

    func selectVisibleTextRange(_ range: NSRange) {
        let textView = activeTextView
        let validLength = (textView.string as NSString).length
        let location = min(max(0, range.location), validLength)
        let length = min(max(0, range.length), validLength - location)
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    func copyVisibleText() throws {
        guard mode != .original else {
            throw OCRTranslationPinError.noVisibleText
        }
        let textView = activeTextView
        let string = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let text: String
        if selectedRange.length > 0, NSMaxRange(selectedRange) <= string.length {
            text = string.substring(with: selectedRange)
        } else {
            text = textView.string
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw OCRTranslationPinError.copyFailed
        }
    }

    private func configureToolbar() {
        let original = toolbarButton(
            symbol: "photo",
            label: "原图",
            action: #selector(showOriginalAction)
        )
        let source = toolbarButton(
            symbol: "text.quote",
            label: "原文",
            action: #selector(showSourceTextAction)
        )
        let translated = toolbarButton(
            symbol: "character.bubble.fill",
            label: "译文",
            action: #selector(showTranslationAction)
        )
        let copy = toolbarButton(
            symbol: "doc.on.doc",
            label: "复制",
            action: #selector(copyTranslationAction)
        )
        let close = toolbarButton(
            symbol: "xmark",
            label: "关闭",
            action: #selector(closeAction)
        )
        let stack = NSStackView(views: [original, source, translated, copy, close])
        actionButtons = [original, source, translated, copy, close]
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.frame = toolbar.bounds.insetBy(dx: 4, dy: 3)
        stack.autoresizingMask = [.width, .height]
        toolbar.addSubview(stack)
        addSubview(toolbar)
    }

    private func toolbarButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!,
            target: self,
            action: action
        )
        button.title = label
        button.bezelStyle = .toolbar
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(label)
        button.contentTintColor = .white
        return button
    }

    private func applyMode() {
        mode = model.mode
        translationOverlay.isHidden = mode == .original
        sourceScrollView.isHidden = mode == .original
        sourceLabel.isHidden = mode == .original
        translationScrollView.isHidden = mode != .translation
        translationLabel.isHidden = mode != .translation
        if mode == .translation {
            translationTextView.setSelectedRange(NSRange(location: 0, length: 0))
            window?.makeFirstResponder(translationTextView)
        } else if mode == .sourceText {
            sourceTextView.setSelectedRange(NSRange(location: 0, length: 0))
            window?.makeFirstResponder(sourceTextView)
        } else {
            window?.makeFirstResponder(self)
        }
        needsLayout = true
    }

    private func updatePairHighlight(characterIndex: Int?, inSource: Bool) {
        guard let characterIndex else {
            applyPairHighlight(nil)
            return
        }
        applyPairHighlight(TranslationAlignment.pairID(
            at: characterIndex,
            inSource: inSource,
            pairs: alignmentPairs
        ))
    }

    private func applyPairHighlight(_ pairID: Int?) {
        highlightedPairID = pairID
        let pair = alignmentPairs.first(where: { $0.id == pairID })
        sourceTextView.setHighlightedRange(pair?.sourceRange)
        translationTextView.setHighlightedRange(pair?.targetRange)
    }

    private var activeTextView: NSTextView {
        mode == .sourceText ? sourceTextView : translationTextView
    }

    private func layoutResultCard() {
        guard !translationOverlay.isHidden else { return }
        let contentBounds = translationOverlay.bounds.insetBy(dx: 14, dy: 12)
        headerLabel.frame = CGRect(
            x: contentBounds.minX,
            y: contentBounds.maxY - 24,
            width: max(0, contentBounds.width - 196),
            height: 20
        )
        let top = contentBounds.maxY - 42
        if mode == .translation {
            let sectionHeight = max(44, (top - contentBounds.minY - 26) / 2)
            translationLabel.frame = CGRect(
                x: contentBounds.minX,
                y: contentBounds.minY + sectionHeight + 4,
                width: 52,
                height: 16
            )
            sourceLabel.frame = CGRect(
                x: contentBounds.minX,
                y: top - 16,
                width: 52,
                height: 16
            )
            sourceScrollView.frame = CGRect(
                x: contentBounds.minX,
                y: contentBounds.minY + sectionHeight + 22,
                width: contentBounds.width,
                height: max(28, top - contentBounds.minY - sectionHeight - 38)
            )
            translationScrollView.frame = CGRect(
                x: contentBounds.minX,
                y: contentBounds.minY,
                width: contentBounds.width,
                height: sectionHeight
            )
        } else {
            sourceLabel.frame = CGRect(
                x: contentBounds.minX,
                y: top - 16,
                width: 52,
                height: 16
            )
            sourceScrollView.frame = CGRect(
                x: contentBounds.minX,
                y: contentBounds.minY,
                width: contentBounds.width,
                height: max(28, top - contentBounds.minY - 20)
            )
        }
    }

    private static func makeResultTextView(
        text: String,
        color: NSColor,
        fontSize: CGFloat
    ) -> OCRTranslationContextTextView {
        let textView = OCRTranslationContextTextView(frame: .zero)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = color
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = CGSize(width: 4, height: 6)
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    private static func makeScrollView(documentView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        return scrollView
    }

    func snapshot(frame: CGRect, opacity: CGFloat) -> PinWindowSnapshot {
        PinWindowSnapshot(
            translationImage: annotationEditor.compositedImage(),
            sourceText: model.sourceText,
            translatedText: model.translatedText,
            displayMode: model.mode,
            frame: frame,
            initialSize: initialSize,
            opacity: opacity,
            isLocked: isLocked,
            isAlwaysOnTop: isAlwaysOnTop
        )
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: annotationEditor.isEditing ? "完成标注" : "标注", action: #selector(toggleAnnotationEditing), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示原图", action: #selector(showOriginalAction), keyEquivalent: "")
        menu.addItem(withTitle: "显示原文", action: #selector(showSourceTextAction), keyEquivalent: "")
        menu.addItem(withTitle: "显示译文", action: #selector(showTranslationAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制当前文字", action: #selector(copyTranslationAction), keyEquivalent: "")
        menu.addItem(.separator())

        let lockItem = NSMenuItem(
            title: isLocked ? "解锁贴图" : "锁定贴图",
            action: #selector(toggleLock(_:)),
            keyEquivalent: ""
        )
        lockItem.state = isLocked ? .on : .off
        menu.addItem(lockItem)
        let alwaysOnTopItem = NSMenuItem(
            title: isAlwaysOnTop ? "取消置顶" : "置顶贴图",
            action: #selector(toggleAlwaysOnTop(_:)),
            keyEquivalent: ""
        )
        alwaysOnTopItem.state = isAlwaysOnTop ? .on : .off
        menu.addItem(alwaysOnTopItem)

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
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
        menu.addItem(actionItem(
            title: "隐藏其他贴图",
            action: #selector(hideOtherPins),
            isEnabled: actions.hideOthers != nil && managerState.activePinCount > 1
        ))
        menu.addItem(actionItem(
            title: "隐藏全部贴图",
            action: #selector(hideAllPins),
            isEnabled: actions.hideAll != nil && managerState.visiblePinCount > 0
        ))
        menu.addItem(actionItem(
            title: "显示全部贴图",
            action: #selector(showAllPins),
            isEnabled: actions.showAll != nil && managerState.hiddenPinCount > 0
        ))
        menu.addItem(.separator())
        menu.addItem(actionItem(
            title: "恢复最近关闭的贴图",
            action: #selector(restoreMostRecentPin),
            isEnabled: actions.restoreMostRecent != nil && managerState.canRestoreMostRecent
        ))
        menu.addItem(actionItem(
            title: "关闭贴图",
            action: #selector(closeAction),
            isEnabled: true
        ))
        menu.addItem(actionItem(
            title: "彻底销毁翻译贴图",
            action: #selector(destroyPin),
            isEnabled: true
        ))
        menu.addItem(actionItem(
            title: "关闭全部贴图",
            action: #selector(closeAllPins),
            isEnabled: actions.closeAll != nil && managerState.activePinCount > 0
        ))
        menu.addItem(actionItem(
            title: "彻底销毁全部贴图",
            action: #selector(destroyAllPins),
            isEnabled: actions.destroyAll != nil && managerState.activePinCount > 0
        ))
        menu.items.forEach { item in
            if item.action != nil { item.target = self }
        }
        return menu
    }

    @objc private func toggleAnnotationEditing() {
        if !annotationEditor.isEditing {
            showOriginal()
        }
        annotationEditor.toggleEditing()
    }

    private func actionItem(title: String, action: Selector, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.isEnabled = isEnabled
        return item
    }

    private func closePin() {
        if let close = actions.close {
            close()
        } else {
            window?.close()
        }
    }

    private func applyAlwaysOnTopState() {
        guard let window else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        (window as? NSPanel)?.isFloatingPanel = isAlwaysOnTop
    }

    private func applyLockState() {
        guard let window else { return }
        if isLocked {
            if window.styleMask.contains(.resizable) {
                restoreResizableWhenUnlocked = true
            }
            window.styleMask.remove(.resizable)
        } else if restoreResizableWhenUnlocked {
            window.styleMask.insert(.resizable)
        }
    }

    @objc private func showOriginalAction() { showOriginal() }
    @objc private func showSourceTextAction() { showSourceText() }
    @objc private func showTranslationAction() { showTranslation() }

    @objc private func copyTranslationAction() {
        do {
            try copyVisibleText()
        } catch {
            OperationErrorPresenter().present(OperationErrorPresentation(
                title: "无法复制文字",
                message: error.localizedDescription
            ))
        }
    }

    @objc private func closeAction() { closePin() }
    @objc private func destroyPin() { actions.destroy?() ?? window?.close() }
    @objc private func restoreMostRecentPin() { actions.restoreMostRecent?() }
    @objc private func closeAllPins() { actions.closeAll?() }
    @objc private func destroyAllPins() { actions.destroyAll?() }
    @objc private func hideOtherPins() { actions.hideOthers?() }
    @objc private func hideAllPins() { actions.hideAll?() }
    @objc private func showAllPins() { actions.showAll?() }

    @objc private func changeOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
    }

    @objc private func toggleLock(_ sender: NSMenuItem) {
        isLocked.toggle()
        dragStartMouseLocation = nil
        dragStartWindowOrigin = nil
        applyLockState()
    }

    @objc private func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        isAlwaysOnTop.toggle()
        applyAlwaysOnTopState()
    }
}

final class OCRTranslationPinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum OCRTranslationPinError: LocalizedError {
    case copyFailed
    case noVisibleText

    var errorDescription: String? {
        switch self {
        case .copyFailed:
            "无法将文字写入剪贴板"
        case .noVisibleText:
            "当前显示的是原图，没有可复制的文字"
        }
    }
}
