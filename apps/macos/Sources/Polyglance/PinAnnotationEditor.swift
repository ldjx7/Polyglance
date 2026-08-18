import AppKit

@MainActor
final class PinAnnotationOverlayView: NSView {
    private let sourceImage: NSImage
    private var history = ScreenshotAnnotationHistory()
    private var activeElement: ScreenshotAnnotationElement?
    private var activeTool: ScreenshotAnnotationTool = .freehand
    private var style = ScreenshotAnnotationStyle.default
    private let toolbar = NSVisualEffectView()
    private var actionButtons: [NSButton] = []
    private var toolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private var textField: NSTextField?
    private var textOrigin: CGPoint?
    private weak var toolbarParentWindow: NSWindow?

    private(set) var isEditing = false
    private(set) var toolbarPanel: NSPanel?
    var elements: [ScreenshotAnnotationElement] { history.elements }
    var onEditingChanged: ((Bool) -> Void)?

    init(sourceImage: NSImage) {
        self.sourceImage = sourceImage
        super.init(frame: CGRect(origin: .zero, size: sourceImage.size))
        wantsLayer = true
        configureToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let toolbarPanel, let toolbarParentWindow {
            toolbarParentWindow.removeChildWindow(toolbarPanel)
            self.toolbarParentWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isEditing else { return }
        presentToolbar()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing ? super.hitTest(point) : nil
    }

    override func layout() {
        super.layout()
        layoutToolbar()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        ScreenshotAnnotationRenderer.draw(
            elements: history.elements + (activeElement.map { [$0] } ?? []),
            in: context,
            sourceImage: sourceCGImage,
            sourcePixelTransform: { [bounds, sourceCGImage] point in
                guard let sourceCGImage, bounds.width > 0, bounds.height > 0 else {
                    return .zero
                }
                return CGPoint(
                    x: point.x * CGFloat(sourceCGImage.width) / bounds.width,
                    y: point.y * CGFloat(sourceCGImage.height) / bounds.height
                )
            }
        )
    }

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true
        toolbar.isHidden = false
        window?.makeFirstResponder(self)
        updateToolbarState()
        onEditingChanged?(true)
        needsLayout = true
        layoutSubtreeIfNeeded()
        presentToolbar()
        needsDisplay = true
    }

    func finishEditing() {
        guard isEditing else { return }
        commitTextIfNeeded()
        activeElement = nil
        isEditing = false
        toolbar.isHidden = true
        toolbarPanel?.orderOut(nil)
        onEditingChanged?(false)
        needsDisplay = true
    }

    func toggleEditing() {
        isEditing ? finishEditing() : beginEditing()
    }

    func selectTool(_ tool: ScreenshotAnnotationTool) {
        activeTool = tool
        updateToolbarState()
    }

    func beginStroke(at point: CGPoint) {
        guard isEditing else { return }
        if activeTool == .text {
            beginTextInput(at: point)
            return
        }
        activeElement = ScreenshotAnnotationElement(tool: activeTool, start: point, style: style)
        needsDisplay = true
    }

    func continueStroke(to point: CGPoint) {
        guard isEditing, let activeElement else { return }
        self.activeElement = activeElement.updating(to: point)
        needsDisplay = true
    }

    func endStroke(at point: CGPoint) {
        guard isEditing, let activeElement else { return }
        let completed = activeElement.updating(to: point)
        if completed.isMeaningful {
            history.append(completed)
        }
        self.activeElement = nil
        updateToolbarState()
        needsDisplay = true
    }

    func compositedImage() -> NSImage {
        guard !history.elements.isEmpty,
              let sourceCGImage,
              bounds.width > 0,
              bounds.height > 0,
              let composed = ScreenshotImageComposer.compose(
                  image: sourceCGImage,
                  selection: bounds,
                  elements: history.elements
              ) else {
            return sourceImage
        }
        let representation = NSBitmapImageRep(cgImage: composed)
        let image = NSImage(size: sourceImage.size)
        image.addRepresentation(representation)
        return image
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginStroke(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        continueStroke(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        endStroke(at: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        finishEditing()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finishEditing()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers == .command {
            undo()
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z",
           modifiers == [.command, .shift] {
            redo()
            return
        }
        super.keyDown(with: event)
    }

    private var sourceCGImage: CGImage? {
        var rect = CGRect(origin: .zero, size: sourceImage.size)
        return sourceImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func configureToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.layer?.masksToBounds = true
        toolbar.isHidden = true
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = toolbar
        toolbarPanel = panel

        for tool in ScreenshotAnnotationTool.allCases {
            let button = makeButton(
                symbol: tool.symbolName,
                title: tool.title,
                action: #selector(selectToolAction(_:))
            )
            button.tag = tool.rawValue
            toolButtons[tool] = button
            actionButtons.append(button)
            toolbar.addSubview(button)
        }
        for definition in [
            ("arrow.uturn.backward", "撤销", #selector(undoAction)),
            ("arrow.uturn.forward", "重做", #selector(redoAction)),
            ("checkmark", "完成", #selector(finishAction)),
        ] {
            let button = makeButton(symbol: definition.0, title: definition.1, action: definition.2)
            actionButtons.append(button)
            toolbar.addSubview(button)
        }
    }

    private func makeButton(symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
            target: self,
            action: action
        )
        button.title = title
        button.imagePosition = .imageOnly
        button.bezelStyle = .toolbar
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func layoutToolbar() {
        guard !toolbar.isHidden, !actionButtons.isEmpty else { return }
        let buttonSide: CGFloat = 28
        let spacing: CGFloat = 3
        let width = CGFloat(actionButtons.count) * buttonSide
            + CGFloat(max(0, actionButtons.count - 1)) * spacing + 8
        let height = buttonSide + 8
        toolbarPanel?.setContentSize(CGSize(width: width, height: height))
        toolbar.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        for (index, button) in actionButtons.enumerated() {
            button.frame = CGRect(
                x: 4 + CGFloat(index) * (buttonSide + spacing),
                y: 4,
                width: buttonSide,
                height: buttonSide
            )
        }
        positionToolbar()
    }

    private func presentToolbar() {
        guard isEditing, let parent = window, let toolbarPanel else { return }
        if toolbarParentWindow !== parent {
            toolbarParentWindow?.removeChildWindow(toolbarPanel)
            parent.addChildWindow(toolbarPanel, ordered: .above)
            toolbarParentWindow = parent
        }
        toolbarPanel.level = parent.level
        positionToolbar()
        toolbarPanel.orderFrontRegardless()
    }

    private func positionToolbar() {
        guard let parent = window, let toolbarPanel else { return }
        let visibleFrame = parent.screen?.visibleFrame ?? parent.frame.insetBy(dx: -500, dy: -500)
        let proposedX = parent.frame.midX - toolbarPanel.frame.width / 2
        let x = min(
            max(proposedX, visibleFrame.minX + 8),
            max(visibleFrame.minX + 8, visibleFrame.maxX - toolbarPanel.frame.width - 8)
        )
        let belowY = parent.frame.minY - toolbarPanel.frame.height - 8
        let y = belowY >= visibleFrame.minY + 8
            ? belowY
            : min(visibleFrame.maxY - toolbarPanel.frame.height - 8, parent.frame.maxY + 8)
        toolbarPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func beginTextInput(at point: CGPoint) {
        commitTextIfNeeded()
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y - 3, width: 180, height: 24))
        field.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        field.textColor = style.color
        field.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.92)
        field.target = self
        field.action = #selector(commitTextAction)
        textOrigin = point
        textField = field
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    private func commitTextIfNeeded() {
        guard let textField, let textOrigin else { return }
        let element = ScreenshotAnnotationElement.text(
            origin: textOrigin,
            text: textField.stringValue,
            style: style
        )
        if element.isMeaningful {
            history.append(element)
        }
        textField.removeFromSuperview()
        self.textField = nil
        self.textOrigin = nil
        window?.makeFirstResponder(self)
        updateToolbarState()
        needsDisplay = true
    }

    private func updateToolbarState() {
        for (tool, button) in toolButtons {
            button.contentTintColor = tool == activeTool ? style.color : .white
        }
        if actionButtons.count >= 3 {
            actionButtons[actionButtons.count - 3].isEnabled = history.canUndo
            actionButtons[actionButtons.count - 2].isEnabled = history.canRedo
        }
    }

    private func undo() {
        _ = history.undo()
        updateToolbarState()
        needsDisplay = true
    }

    private func redo() {
        _ = history.redo()
        updateToolbarState()
        needsDisplay = true
    }

    @objc private func selectToolAction(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }

    @objc private func undoAction() { undo() }
    @objc private func redoAction() { redo() }
    @objc private func finishAction() { finishEditing() }
    @objc private func commitTextAction() { commitTextIfNeeded() }
}
