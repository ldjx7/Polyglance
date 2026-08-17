import AppKit

struct ScreenTranslationRenderedParagraph {
    let normalizedRect: CGRect
    let text: String
    let backgroundColor: NSColor
    let textColor: NSColor
    let lineCount: Int
}

final class ScreenTranslationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ScreenTranslationOverlayView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var paragraphs: [ScreenTranslationRenderedParagraph] = [] {
        didSet { needsDisplay = true }
    }

    var showsTranslation = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(
            in: bounds,
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
            drawParagraph(paragraph)
        }
    }

    private func drawParagraph(_ paragraph: ScreenTranslationRenderedParagraph) {
        let box = paragraph.normalizedRect.standardized
        let rect = CGRect(
            x: box.minX * bounds.width,
            y: (1 - box.maxY) * bounds.height,
            width: box.width * bounds.width,
            height: box.height * bounds.height
        )
        let padding = min(4, rect.height * 0.12)
        let backgroundRect = rect.insetBy(dx: -padding, dy: -padding)
            .intersection(bounds.insetBy(dx: -1, dy: -1))
        let path = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: min(4, backgroundRect.height * 0.15),
            yRadius: min(4, backgroundRect.height * 0.15)
        )
        paragraph.backgroundColor.setFill()
        path.fill()

        let (attributes, textHeight) = Self.fittedAttributes(
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
        let initialSize = min(
            60,
            max(9, height / CGFloat(max(1, lineCount)) * 0.74)
        )
        var fontSize = initialSize
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

@MainActor
final class ScreenTranslationOverlaySession {
    let panel: ScreenTranslationOverlayPanel
    private let toolbarPanel: NSPanel
    private let overlayView: ScreenTranslationOverlayView
    private let progressIndicator = NSProgressIndicator()
    private let toggleButton: NSButton
    private let copyTranslationButton: NSButton
    private let copySourceButton: NSButton
    private let closeButton: NSButton
    private let screenFrame: CGRect
    private var sourceText = ""
    private var translatedText = ""
    private var hasTranslation = false
    private var keyMonitor: Any?
    var onClosed: (() -> Void)?

    init(screenshot: SelectedScreenshot) {
        screenFrame = screenshot.screenFrame.standardized
        overlayView = ScreenTranslationOverlayView(frame: CGRect(origin: .zero, size: screenFrame.size))
        overlayView.image = screenshot.image

        panel = ScreenTranslationOverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.contentView = overlayView

        toggleButton = Self.makeButton(symbol: "photo", tooltip: "显示原文")
        copyTranslationButton = Self.makeButton(symbol: "doc.on.doc", tooltip: "复制译文")
        copySourceButton = Self.makeButton(symbol: "doc.plaintext", tooltip: "复制原文")
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

        configureProgressIndicator()
        configureToolbar()
        configureActions()
        configureKeyHandling()
    }

    func present() {
        positionToolbar()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }

    func showTranslation(
        _ paragraphs: [ScreenTranslationRenderedParagraph],
        sourceText: String,
        translatedText: String
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        hasTranslation = true
        overlayView.paragraphs = paragraphs
        overlayView.showsTranslation = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        updateControlAvailability()
        updateTogglePresentation()
    }

    func finishLoading() {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
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

    private static func makeButton(symbol: String, tooltip: String) -> NSButton {
        let button = NSButton(title: "", target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .large
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
                constant: -8
            ),
            progressIndicator.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: 8),
        ])
        progressIndicator.startAnimation(nil)
        updateControlAvailability()
    }

    private func configureToolbar() {
        let stack = NSStackView(views: [
            toggleButton,
            copyTranslationButton,
            copySourceButton,
            closeButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
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
        toggleButton.target = self
        toggleButton.action = #selector(toggleView)
        copyTranslationButton.target = self
        copyTranslationButton.action = #selector(copyTranslation)
        copySourceButton.target = self
        copySourceButton.action = #selector(copySource)
        closeButton.target = self
        closeButton.action = #selector(closeFromToolbar)
    }

    private func configureKeyHandling() {
        panel.initialFirstResponder = overlayView
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel.isKeyWindow, event.keyCode == 53 else {
                return event
            }
            requestClose()
            return nil
        }
    }

    private func positionToolbar() {
        let toolbarSize = toolbarPanel.contentView?.fittingSize ?? CGSize(width: 168, height: 40)
        let gap: CGFloat = 8
        let visibleFrame = targetScreen()?.visibleFrame ?? screenFrame
        var origin = CGPoint(
            x: min(screenFrame.maxX, visibleFrame.maxX) - toolbarSize.width,
            y: screenFrame.minY - gap - toolbarSize.height
        )
        if origin.y < visibleFrame.minY {
            origin.y = min(screenFrame.maxY, visibleFrame.maxY) + gap
        }
        if origin.y + toolbarSize.height > visibleFrame.maxY {
            origin.y = max(
                visibleFrame.minY,
                min(screenFrame.minY + gap, visibleFrame.maxY - toolbarSize.height)
            )
        }
        origin.x = max(origin.x, visibleFrame.minX)
        toolbarPanel.setFrame(CGRect(origin: origin, size: toolbarSize), display: false)
    }

    private func targetScreen() -> NSScreen? {
        let center = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(screenFrame) })
    }

    private func updateControlAvailability() {
        toggleButton.isEnabled = hasTranslation
        copyTranslationButton.isEnabled = hasTranslation
        copySourceButton.isEnabled = hasTranslation
    }

    private func updateTogglePresentation() {
        let showsTranslation = overlayView.showsTranslation
        let tooltip = showsTranslation ? "显示原文" : "显示译文"
        toggleButton.toolTip = tooltip
        toggleButton.setAccessibilityLabel(tooltip)
        toggleButton.image = NSImage(
            systemSymbolName: showsTranslation ? "photo" : "character.book.closed",
            accessibilityDescription: tooltip
        )
    }

    private func requestClose() {
        close()
        onClosed?()
    }

    @objc private func toggleView() {
        guard hasTranslation else {
            return
        }
        overlayView.showsTranslation.toggle()
        updateTogglePresentation()
    }

    @objc private func copyTranslation() {
        copyToPasteboard(translatedText)
    }

    @objc private func copySource() {
        copyToPasteboard(sourceText)
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
