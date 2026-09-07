import AppKit

private final class TextPinTextView: NSTextView {
    var onDoubleClick: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScrollWheel {
            onScrollWheel(event)
            return
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        (enclosingScrollView?.superview as? TextPinContentView)?.makeContextMenu() ?? super.menu(for: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if let parent = enclosingScrollView?.superview as? TextPinContentView {
            parent.otherMouseDown(with: event)
            return
        }
        super.otherMouseDown(with: event)
    }
}

/// Native text selection stays available; PNG is only an export/thumbnail representation.
@MainActor
final class TextPinContentView: NSView {
    let text: String
    private let textPinView = TextPinTextView()
    var textView: NSTextView { textPinView }
    var isLocked = false
    private let actions: PinWindowActions
    private let scroll = NSScrollView()
    let initialSize: CGSize
    private let baseFontSize: CGFloat = 16.0
    private let zoomIndicator = PinZoomIndicatorView()

    static func fittedSize(_ text: String, maximumSize: NSSize) -> NSSize {
        let width = max(80, min(1_200, maximumSize.width * 0.9))
        let height = max(44, maximumSize.height * 0.8)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: width - 32, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 16)])
        return NSSize(width: min(width, max(80, ceil(measured.width) + 34)),
            height: min(height, max(44, ceil(measured.height) + 24)))
    }

    init(text: String, actions: PinWindowActions) {
        self.text = text
        self.actions = actions
        let fitSize = Self.fittedSize(text, maximumSize: NSSize(width: 1_400, height: 900))
        self.initialSize = fitSize
        super.init(frame: CGRect(origin: .zero, size: fitSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderColor = NSColor.gray.cgColor
        layer?.borderWidth = 1
        toolTip = "拖动贴图移动，滚轮缩放大小，中键重置；文字可直接选择，双击或 Esc 关闭。"
        textPinView.onDoubleClick = { [weak self] in self?.closePin() }
        textPinView.onScrollWheel = { [weak self] event in self?.scrollWheel(with: event) }
        scroll.frame = bounds.insetBy(dx: 8, dy: 8)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        textView.frame = scroll.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 8, height: 4)
        textView.backgroundColor = .white
        textView.textColor = .black
        textView.font = .systemFont(ofSize: baseFontSize)
        textView.string = text
        scroll.documentView = textView
        addSubview(scroll)
        addSubview(zoomIndicator)
        self.menu = makeContextMenu()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        restoreInitialSize()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window else { return }
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

    func applyScroll(
        deltaY: CGFloat,
        modifiers: NSEvent.ModifierFlags,
        anchorInWindow: CGPoint,
        hasPreciseScrollingDeltas: Bool = false
    ) {
        guard let window, deltaY.isFinite, deltaY != 0 else { return }
        let normalizedDelta = hasPreciseScrollingDeltas ? deltaY / 10 : deltaY
        if modifiers.contains(.command) {
            window.alphaValue = min(1, max(0.1, window.alphaValue + normalizedDelta * 0.05))
            return
        }
        guard !isLocked else { return }

        let sensitivity: CGFloat = modifiers.contains(.option) ? 0.025 : 0.1
        let boundedDelta = min(10, max(-10, normalizedDelta))
        resizeWindow(by: exp(boundedDelta * sensitivity), anchorInWindow: anchorInWindow)
    }

    private func resizeWindow(by scale: CGFloat, anchorInWindow: CGPoint) {
        guard let window else { return }
        let frame = PinResizeGeometry.scaledFrame(
            window.frame,
            requestedScale: scale,
            anchorInWindow: anchorInWindow,
            minimumSize: CGSize(width: 80, height: 44),
            maximumSize: CGSize(width: 4000, height: 3000)
        )
        window.setFrame(frame, display: true)
        let currentScale = frame.width / initialSize.width
        textView.font = .systemFont(ofSize: max(8, round(baseFontSize * currentScale)))
        let percent = Int(round(currentScale * 100))
        zoomIndicator.show(percent: percent, in: bounds)
    }

    func updateFontForFrame(_ frame: CGRect) {
        guard initialSize.width > 0 else { return }
        let currentScale = frame.width / initialSize.width
        textView.font = .systemFont(ofSize: max(8, round(baseFontSize * currentScale)))
    }

    private func restoreInitialSize() {
        guard let window, !isLocked else { return }
        let oldFrame = window.frame
        let frame = CGRect(
            x: oldFrame.midX - initialSize.width / 2,
            y: oldFrame.midY - initialSize.height / 2,
            width: initialSize.width,
            height: initialSize.height
        )
        window.setFrame(frame, display: true)
        textView.font = .systemFont(ofSize: baseFontSize)
        zoomIndicator.show(percent: 100, in: bounds)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            closePin()
            return
        }
        if !isLocked { window?.performDrag(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { actions.close?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeContextMenu()
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let lockItem = menuItem(
            title: isLocked ? "解锁贴图" : "锁定贴图",
            action: #selector(toggleLock),
            symbol: isLocked ? "lock.open" : "lock"
        )
        lockItem.state = isLocked ? .on : .off
        menu.addItem(lockItem)

        let isTopmost = window?.level == .floating
        let alwaysOnTopItem = menuItem(
            title: isTopmost ? "取消置顶" : "置顶贴图",
            action: #selector(toggleTopmost),
            symbol: isTopmost ? "pin.slash" : "pin"
        )
        alwaysOnTopItem.state = isTopmost ? .on : .off
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "复制所选文字",
            action: #selector(copySelection),
            symbol: "text.viewfinder",
            isEnabled: textView.selectedRange().length > 0
        ))
        menu.addItem(menuItem(
            title: "复制全部文字",
            action: #selector(copyAll),
            symbol: "doc.on.doc",
            keyEquivalent: "c"
        ))
        menu.addItem(menuItem(
            title: "复制图片",
            action: #selector(copyAsImage),
            symbol: "photo"
        ))
        menu.addItem(menuItem(
            title: "另存为…",
            action: #selector(saveAsImage),
            symbol: "square.and.arrow.down",
            keyEquivalent: "s"
        ))

        let opacityItem = menuItem(
            title: "透明度",
            action: nil,
            symbol: "slider.horizontal.3"
        )
        let opacityMenu = NSMenu()
        let currentOpacity = window?.alphaValue ?? 1.0
        for value in [100, 80, 60, 40] {
            let item = NSMenuItem(
                title: "\(value)%",
                action: #selector(changeOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = value
            item.state = abs(currentOpacity - CGFloat(value) / 100.0) < 0.05 ? .on : .off
            opacityMenu.addItem(item)
        }
        menu.setSubmenu(opacityMenu, for: opacityItem)
        menu.addItem(opacityItem)
        menu.addItem(.separator())

        let managerState = actions.currentState()

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
            action: #selector(restorePin),
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

    private func menuItem(
        title: String,
        action: Selector?,
        symbol: String? = nil,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = [],
        isEnabled: Bool = true
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = isEnabled
        if let symbol {
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: title
            )
        }
        return item
    }

    static func preview(_ text: String) -> NSImage {
        let excerpt = String(text.prefix(8_000))
        return NSImage(size: NSSize(width: 640, height: 480), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            (excerpt as NSString).draw(in: rect.insetBy(dx: 20, dy: 20), withAttributes: [
                .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black
            ])
            return true
        }
    }

    @objc private func copySelection() { textView.copy(nil) }
    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @objc private func copyAsImage() {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size); image.addRepresentation(bitmap)
        do { try ImagePasteboard.write(image) } catch { NSSound.beep() }
    }
    @objc private func saveAsImage() {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size); image.addRepresentation(bitmap)
        do { _ = try ScreenshotFileSaver().save(image) } catch { NSSound.beep() }
    }
    @objc private func toggleLock() {
        isLocked.toggle()
        window?.isMovable = !isLocked
    }
    @objc private func toggleTopmost() {
        guard let window else { return }
        window.level = (window.level == .floating) ? .normal : .floating
    }
    @objc private func changeOpacity(_ sender: NSMenuItem) {
        guard let window else { return }
        window.alphaValue = CGFloat(sender.tag) / 100.0
    }
    @objc private func hideOtherPins() { actions.hideOthers?() }
    @objc private func hideAllPins() { actions.hideAll?() }
    @objc private func showAllPins() { actions.showAll?() }
    @objc private func closeAllPins() { actions.closeAll?() }
    @objc private func destroyAllPins() { actions.destroyAll?() }
    @objc private func restorePin() { actions.restoreMostRecent?() }
    @objc private func closePin() { actions.close?() }
    @objc private func destroyPin() { actions.destroy?() }
}
