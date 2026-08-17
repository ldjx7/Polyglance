import AppKit

struct ScreenTranslationRenderedParagraph {
    let normalizedRect: CGRect
    let text: String
    let backgroundColor: NSColor
    let textColor: NSColor
    let lineCount: Int
}

enum ScreenTranslationRenderer {
    static func drawContent(
        image: NSImage?,
        paragraphs: [ScreenTranslationRenderedParagraph],
        showsTranslation: Bool,
        in rect: CGRect
    ) {
        image?.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        guard showsTranslation else {
            return
        }
        for paragraph in paragraphs {
            drawParagraph(paragraph, in: rect)
        }
    }

    static func exportImage(
        image: NSImage?,
        paragraphs: [ScreenTranslationRenderedParagraph],
        showsTranslation: Bool,
        size: CGSize,
        scale: CGFloat
    ) -> NSImage? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let flippedContent = NSImage(size: size, flipped: true) { rect in
            drawContent(
                image: image,
                paragraphs: paragraphs,
                showsTranslation: showsTranslation,
                in: rect
            )
            return true
        }
        let pixelScale = max(1, scale)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * pixelScale),
            pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        flippedContent.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let exported = NSImage(size: size)
        exported.addRepresentation(representation)
        return exported
    }

    private static func drawParagraph(
        _ paragraph: ScreenTranslationRenderedParagraph,
        in contentRect: CGRect
    ) {
        let box = paragraph.normalizedRect.standardized
        let rect = CGRect(
            x: contentRect.minX + box.minX * contentRect.width,
            y: contentRect.minY + (1 - box.maxY) * contentRect.height,
            width: box.width * contentRect.width,
            height: box.height * contentRect.height
        )
        let padding = min(4, rect.height * 0.12)
        let backgroundRect = rect.insetBy(dx: -padding, dy: -padding)
            .intersection(contentRect.insetBy(dx: -1, dy: -1))
        let cornerRadius = min(4, backgroundRect.height * 0.15)
        let path = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        paragraph.backgroundColor.setFill()
        path.fill()

        let (attributes, textHeight) = fittedAttributes(
            for: paragraph.text,
            width: rect.width,
            height: rect.height + padding * 1.5,
            lineCount: paragraph.lineCount,
            color: paragraph.textColor
        )
        let textRect = CGRect(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - textHeight) / 2),
            width: rect.width,
            height: min(rect.height + padding * 1.5, textHeight)
        )
        (paragraph.text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
    }

    private static func fittedAttributes(
        for text: String,
        width: CGFloat,
        height: CGFloat,
        lineCount: Int,
        color: NSColor
    ) -> ([NSAttributedString.Key: Any], CGFloat) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        var fontSize = min(60, max(9, height / CGFloat(max(1, lineCount)) * 0.74))
        var measuredHeight: CGFloat = 0
        while fontSize >= 9 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            measuredHeight = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            ).height
            if measuredHeight <= height {
                return (attributes, measuredHeight)
            }
            fontSize -= 1
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
        return (attributes, measuredHeight)
    }
}

final class ScreenTranslationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum ScreenTranslationDragZone {
    case move
    case resize(top: Bool, bottom: Bool, left: Bool, right: Bool)
}

final class ScreenTranslationOverlayView: NSView {
    static let contentMargin: CGFloat = 9

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var paragraphs: [ScreenTranslationRenderedParagraph] = [] {
        didSet { needsDisplay = true }
    }

    var showsTranslation = false {
        didSet { needsDisplay = true }
    }

    var onDragBegan: (() -> Void)?
    fileprivate var onDragChanged: ((ScreenTranslationDragZone, CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragZone: ScreenTranslationDragZone?
    private var dragStartLocation: CGPoint = .zero

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var contentRect: CGRect {
        bounds.insetBy(dx: Self.contentMargin, dy: Self.contentMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        ScreenTranslationRenderer.drawContent(
            image: image,
            paragraphs: paragraphs,
            showsTranslation: showsTranslation,
            in: contentRect
        )
        drawChrome()
    }

    private func drawChrome() {
        let borderColor = NSColor(srgbRed: 0.97, green: 0.35, blue: 0.35, alpha: 1)
        let borderPath = NSBezierPath(rect: contentRect)
        borderPath.lineWidth = 2
        borderColor.setStroke()
        borderPath.stroke()

        for center in handleCenters(in: contentRect) {
            let handleRect = CGRect(
                x: center.x - 5,
                y: center.y - 5,
                width: 10,
                height: 10
            )
            let circle = NSBezierPath(ovalIn: handleRect)
            NSColor(srgbRed: 1, green: 0.92, blue: 0.92, alpha: 1).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            borderColor.setStroke()
            circle.stroke()
        }
    }

    private func handleCenters(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        dragZone = zone(atWindowLocation: dragStartLocation)
        if dragZone != nil {
            onDragBegan?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragZone else {
            return
        }
        let location = event.locationInWindow
        let delta = CGSize(
            width: location.x - dragStartLocation.x,
            height: location.y - dragStartLocation.y
        )
        onDragChanged?(dragZone, delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragZone != nil else {
            return
        }
        dragZone = nil
        onDragEnded?()
    }

    /// The window shares the view's size; window coordinates keep the
    /// bottom-left origin so resize math stays in global-screen orientation.
    private func zone(atWindowLocation location: CGPoint) -> ScreenTranslationDragZone? {
        let margin = Self.contentMargin
        let rect = CGRect(
            x: margin,
            y: margin,
            width: bounds.width - margin * 2,
            height: bounds.height - margin * 2
        )
        let handleRadius: CGFloat = 9
        let nearLeft = abs(location.x - rect.minX) <= handleRadius
        let nearRight = abs(location.x - rect.maxX) <= handleRadius
        let nearBottom = abs(location.y - rect.minY) <= handleRadius
        let nearTop = abs(location.y - rect.maxY) <= handleRadius
        let withinX = location.x >= rect.minX - handleRadius
            && location.x <= rect.maxX + handleRadius
        let withinY = location.y >= rect.minY - handleRadius
            && location.y <= rect.maxY + handleRadius
        guard withinX, withinY else {
            return nil
        }
        if nearTop || nearBottom || nearLeft || nearRight {
            return .resize(
                top: nearTop,
                bottom: nearBottom,
                left: nearLeft,
                right: nearRight
            )
        }
        guard rect.contains(location) else {
            return nil
        }
        return .move
    }
}

@MainActor
final class ScreenTranslationOverlaySession {
    struct LanguageOption {
        let code: String?
        let title: String
    }

    static let sourceLanguages: [LanguageOption] = [
        LanguageOption(code: nil, title: "自动检测"),
        LanguageOption(code: "en", title: "英语"),
        LanguageOption(code: "zh-CN", title: "简体中文"),
        LanguageOption(code: "ja", title: "日语"),
        LanguageOption(code: "ko", title: "韩语"),
    ]

    static let targetLanguages: [LanguageOption] = [
        LanguageOption(code: "zh-CN", title: "简体中文"),
        LanguageOption(code: "en", title: "英语"),
        LanguageOption(code: "ja", title: "日语"),
        LanguageOption(code: "ko", title: "韩语"),
    ]

    let panel: ScreenTranslationOverlayPanel
    private let toolbarPanel: NSPanel
    private let overlayView: ScreenTranslationOverlayView
    private let progressIndicator = NSProgressIndicator()
    private let sourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapButton: NSButton
    private let compareSwitch = NSSwitch()
    private let copyTranslationButton: NSButton
    private let extractTextButton: NSButton
    private let reselectButton: NSButton
    private let pinButton: NSButton
    private let refreshButton: NSButton
    private let closeButton: NSButton
    private let screenBounds: CGRect
    private(set) var region: CGRect
    private var dragStartRegion: CGRect?
    private var sourceText = ""
    private var translatedText = ""
    private var hasTranslation = false
    private var keyMonitor: Any?

    var onRegionChanged: ((CGRect) -> Void)?
    var liveCropProvider: ((CGRect) -> NSImage?)?
    var onLanguageChanged: ((String?, String) -> Void)?
    var onExtractText: (() -> Void)?
    var onReselect: (() -> Void)?
    var onPin: ((NSImage, CGRect) -> Void)?
    var onRefresh: (() -> Void)?
    var onClosed: (() -> Void)?

    init(image: NSImage, region: CGRect, screenBounds: CGRect) {
        self.region = region.standardized
        self.screenBounds = screenBounds
        overlayView = ScreenTranslationOverlayView(frame: .zero)
        overlayView.image = image

        panel = ScreenTranslationOverlayPanel(
            contentRect: Self.panelFrame(for: region),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = overlayView

        swapButton = Self.makeButton(symbol: "arrow.left.arrow.right", tooltip: "互换语言")
        copyTranslationButton = Self.makeButton(symbol: "doc.on.doc", tooltip: "复制译文")
        extractTextButton = Self.makeButton(symbol: "doc.plaintext", tooltip: "提取文本")
        reselectButton = Self.makeButton(symbol: "viewfinder", tooltip: "重新截取")
        pinButton = Self.makeButton(symbol: "pin", tooltip: "钉住为贴图")
        refreshButton = Self.makeButton(symbol: "arrow.clockwise", tooltip: "刷新（重新识别当前屏幕内容）")
        closeButton = Self.makeButton(symbol: "xmark", tooltip: "关闭（Esc）")

        toolbarPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toolbarPanel.level = .floating
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbarPanel.isReleasedWhenClosed = false
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.isOpaque = false
        toolbarPanel.hasShadow = true
        toolbarPanel.appearance = NSAppearance(named: .darkAqua)

        configureProgressIndicator()
        configureToolbar()
        configureActions()
        configureDragHandling()
        configureKeyHandling()
        updateControlAvailability()
    }

    func present() {
        positionToolbar()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }

    func setLanguages(source: String?, target: String) {
        selectOption(in: sourcePopUp, options: Self.sourceLanguages, code: source)
        selectOption(in: targetPopUp, options: Self.targetLanguages, code: target)
        updateSwapAvailability()
    }

    func beginLoading() {
        hasTranslation = false
        overlayView.paragraphs = []
        overlayView.showsTranslation = false
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        updateControlAvailability()
    }

    func showPlainImage(_ image: NSImage) {
        overlayView.image = image
        overlayView.paragraphs = []
        overlayView.showsTranslation = false
    }

    func showTranslation(
        _ paragraphs: [ScreenTranslationRenderedParagraph],
        image: NSImage,
        sourceText: String,
        translatedText: String
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        hasTranslation = true
        overlayView.image = image
        overlayView.paragraphs = paragraphs
        overlayView.showsTranslation = compareSwitch.state == .on
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        updateControlAvailability()
    }

    func hideForRecapture() {
        panel.orderOut(nil)
        toolbarPanel.orderOut(nil)
    }

    func showAfterRecapture() {
        panel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        progressIndicator.stopAnimation(nil)
        toolbarPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    private static func panelFrame(for region: CGRect) -> CGRect {
        region.standardized.insetBy(
            dx: -ScreenTranslationOverlayView.contentMargin,
            dy: -ScreenTranslationOverlayView.contentMargin
        )
    }

    private static func makeButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        return button
    }

    private func configureProgressIndicator() {
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(progressIndicator)
        NSLayoutConstraint.activate([
            progressIndicator.trailingAnchor.constraint(
                equalTo: overlayView.trailingAnchor,
                constant: -(ScreenTranslationOverlayView.contentMargin + 6)
            ),
            progressIndicator.topAnchor.constraint(
                equalTo: overlayView.topAnchor,
                constant: ScreenTranslationOverlayView.contentMargin + 6
            ),
        ])
        progressIndicator.startAnimation(nil)
    }

    private func configureToolbar() {
        for option in Self.sourceLanguages {
            sourcePopUp.addItem(withTitle: option.title)
        }
        for option in Self.targetLanguages {
            targetPopUp.addItem(withTitle: option.title)
        }
        for popUp in [sourcePopUp, targetPopUp] {
            popUp.controlSize = .small
            popUp.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        swapButton.controlSize = .small
        compareSwitch.controlSize = .small
        compareSwitch.state = .on

        let compareLabel = NSTextField(labelWithString: "对照")
        compareLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        compareLabel.textColor = .labelColor

        let stack = NSStackView(views: [
            sourcePopUp,
            swapButton,
            targetPopUp,
            compareLabel,
            compareSwitch,
            copyTranslationButton,
            extractTextButton,
            reselectButton,
            pinButton,
            refreshButton,
            closeButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.setCustomSpacing(8, after: targetPopUp)
        stack.setCustomSpacing(2, after: compareLabel)
        stack.setCustomSpacing(8, after: compareSwitch)
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        toolbarPanel.contentView = background
    }

    private func configureActions() {
        sourcePopUp.target = self
        sourcePopUp.action = #selector(languageSelectionChanged)
        targetPopUp.target = self
        targetPopUp.action = #selector(languageSelectionChanged)
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        compareSwitch.target = self
        compareSwitch.action = #selector(compareSwitchChanged)
        copyTranslationButton.target = self
        copyTranslationButton.action = #selector(copyTranslation)
        extractTextButton.target = self
        extractTextButton.action = #selector(extractText)
        reselectButton.target = self
        reselectButton.action = #selector(reselect)
        pinButton.target = self
        pinButton.action = #selector(pinResult)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        closeButton.target = self
        closeButton.action = #selector(closeFromToolbar)
    }

    private func configureDragHandling() {
        overlayView.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStartRegion = region
        }
        overlayView.onDragChanged = { [weak self] zone, delta in
            guard let self, let dragStartRegion else {
                return
            }
            let updated = Self.adjustedRegion(
                from: dragStartRegion,
                zone: zone,
                delta: delta,
                bounds: screenBounds
            )
            apply(region: updated)
            if let preview = liveCropProvider?(updated) {
                showPlainImage(preview)
            }
        }
        overlayView.onDragEnded = { [weak self] in
            guard let self, dragStartRegion != nil else { return }
            let startRegion = dragStartRegion
            self.dragStartRegion = nil
            guard startRegion != region else {
                overlayView.showsTranslation = hasTranslation && compareSwitch.state == .on
                return
            }
            onRegionChanged?(region)
        }
    }

    private func configureKeyHandling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel.isKeyWindow, event.keyCode == 53 else {
                return event
            }
            requestClose()
            return nil
        }
    }

    private static func adjustedRegion(
        from start: CGRect,
        zone: ScreenTranslationDragZone,
        delta: CGSize,
        bounds: CGRect
    ) -> CGRect {
        let minimumSize = CGSize(width: 48, height: 28)
        var region = start
        switch zone {
        case .move:
            region.origin.x += delta.width
            region.origin.y += delta.height
            region.origin.x = min(
                max(region.origin.x, bounds.minX),
                bounds.maxX - region.width
            )
            region.origin.y = min(
                max(region.origin.y, bounds.minY),
                bounds.maxY - region.height
            )
        case let .resize(top, bottom, left, right):
            var minX = start.minX
            var maxX = start.maxX
            var minY = start.minY
            var maxY = start.maxY
            if left { minX = min(start.minX + delta.width, maxX - minimumSize.width) }
            if right { maxX = max(start.maxX + delta.width, minX + minimumSize.width) }
            if bottom { minY = min(start.minY + delta.height, maxY - minimumSize.height) }
            if top { maxY = max(start.maxY + delta.height, minY + minimumSize.height) }
            region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            region = region.intersection(bounds)
            if region.width < minimumSize.width || region.height < minimumSize.height {
                region = CGRect(
                    x: min(max(region.minX, bounds.minX), bounds.maxX - minimumSize.width),
                    y: min(max(region.minY, bounds.minY), bounds.maxY - minimumSize.height),
                    width: max(region.width, minimumSize.width),
                    height: max(region.height, minimumSize.height)
                )
            }
        }
        return region
    }

    private func apply(region: CGRect) {
        self.region = region
        panel.setFrame(Self.panelFrame(for: region), display: true)
        positionToolbar()
    }

    private func positionToolbar() {
        let toolbarSize = toolbarPanel.contentView?.fittingSize ?? CGSize(width: 460, height: 38)
        let gap: CGFloat = 6
        let visibleFrame = targetScreen()?.visibleFrame ?? screenBounds
        var origin = CGPoint(
            x: region.midX - toolbarSize.width / 2,
            y: region.minY - gap - toolbarSize.height
        )
        if origin.y < visibleFrame.minY {
            origin.y = min(region.maxY, visibleFrame.maxY) + gap
        }
        if origin.y + toolbarSize.height > visibleFrame.maxY {
            origin.y = max(
                visibleFrame.minY,
                min(region.minY + gap, visibleFrame.maxY - toolbarSize.height)
            )
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX),
            visibleFrame.maxX - toolbarSize.width
        )
        toolbarPanel.setFrame(CGRect(origin: origin, size: toolbarSize), display: false)
    }

    private func targetScreen() -> NSScreen? {
        let center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(screenBounds) })
    }

    private func selectOption(
        in popUp: NSPopUpButton,
        options: [LanguageOption],
        code: String?
    ) {
        let index = options.firstIndex(where: { $0.code == code }) ?? 0
        popUp.selectItem(at: index)
    }

    private var selectedSourceCode: String? {
        let index = sourcePopUp.indexOfSelectedItem
        guard index >= 0, index < Self.sourceLanguages.count else {
            return nil
        }
        return Self.sourceLanguages[index].code
    }

    private var selectedTargetCode: String {
        let index = targetPopUp.indexOfSelectedItem
        guard index >= 0, index < Self.targetLanguages.count else {
            return Self.targetLanguages[0].code ?? "zh-CN"
        }
        return Self.targetLanguages[index].code ?? "zh-CN"
    }

    private func updateControlAvailability() {
        compareSwitch.isEnabled = hasTranslation
        copyTranslationButton.isEnabled = hasTranslation
        extractTextButton.isEnabled = hasTranslation
        pinButton.isEnabled = hasTranslation
        updateSwapAvailability()
    }

    private func updateSwapAvailability() {
        swapButton.isEnabled = selectedSourceCode != nil
    }

    private func requestClose() {
        close()
        onClosed?()
    }

    @objc private func languageSelectionChanged() {
        updateSwapAvailability()
        onLanguageChanged?(selectedSourceCode, selectedTargetCode)
    }

    @objc private func swapLanguages() {
        guard let sourceCode = selectedSourceCode else {
            return
        }
        let targetCode = selectedTargetCode
        guard sourceCode != targetCode else {
            return
        }
        guard Self.targetLanguages.contains(where: { $0.code == sourceCode }) else {
            return
        }
        selectOption(in: sourcePopUp, options: Self.sourceLanguages, code: targetCode)
        selectOption(in: targetPopUp, options: Self.targetLanguages, code: sourceCode)
        languageSelectionChanged()
    }

    @objc private func compareSwitchChanged() {
        overlayView.showsTranslation = hasTranslation && compareSwitch.state == .on
    }

    @objc private func copyTranslation() {
        copyToPasteboard(translatedText)
    }

    @objc private func extractText() {
        onExtractText?()
    }

    @objc private func reselect() {
        close()
        onReselect?()
    }

    @objc private func pinResult() {
        guard hasTranslation,
              let exported = ScreenTranslationRenderer.exportImage(
                  image: overlayView.image,
                  paragraphs: overlayView.paragraphs,
                  showsTranslation: compareSwitch.state == .on,
                  size: region.size,
                  scale: panel.backingScaleFactor
              ) else {
            return
        }
        onPin?(exported, region)
    }

    @objc private func refresh() {
        onRefresh?()
    }

    @objc private func closeFromToolbar() {
        requestClose()
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
