import AppKit

@MainActor
final class ScreenshotSubToolbarView: NSView {
    var onStyleChanged: ((ScreenshotAnnotationStyle) -> Void)?
    var onToolChanged: ((ScreenshotAnnotationTool) -> Void)?

    private(set) var currentTool: ScreenshotAnnotationTool = .rectangle
    private(set) var currentStyle: ScreenshotAnnotationStyle = .default

    private let visualEffectView = NSVisualEffectView()
    private let contentStack = NSStackView()
    private let controlStack = NSStackView()
    private let colorStack = NSStackView()

    private var colorButtons: [ColorDotButton] = []
    private var sizeDropdownButton: DropdownPillButton?

    static let presetColors: [NSColor] = [
        NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1.0), // Red (#EF4444)
        NSColor(srgbRed: 0.98, green: 0.45, blue: 0.09, alpha: 1.0), // Orange (#F97316)
        NSColor(srgbRed: 0.98, green: 0.80, blue: 0.08, alpha: 1.0), // Yellow (#FACC15)
        NSColor(srgbRed: 0.06, green: 0.73, blue: 0.51, alpha: 1.0), // Green (#10B981)
        NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1.0), // Blue (#3B82F6)
        NSColor(srgbRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0), // Purple (#8B5CF6)
        NSColor(srgbRed: 0.12, green: 0.16, blue: 0.22, alpha: 1.0), // Dark (#1F2937)
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)  // White (#FFFFFF)
    ]

    static let presetLineWidths: [CGFloat] = [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32]
    static let presetFontSizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64, 72]

    static let fontFamilies: [(title: String, name: String)] = [
        ("系统默认", ""),
        ("苹方", "PingFangSC-Regular"),
        ("宋体", "Songti SC"),
        ("黑体", "Heiti SC"),
        ("楷体", "Kaiti SC"),
        ("Arial", "Arial"),
        ("Georgia", "Georgia"),
        ("Courier", "Courier"),
        ("Times New Roman", "TimesNewRomanPSMT")
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8

        visualEffectView.material = .popover
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 17
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 0.5
        visualEffectView.layer?.borderColor = NSColor(white: 0.0, alpha: 0.08).cgColor
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(contentStack)

        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 5

        colorStack.orientation = .horizontal
        colorStack.alignment = .centerY
        colorStack.spacing = 4

        NSLayoutConstraint.activate([
            visualEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            visualEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            visualEffectView.topAnchor.constraint(equalTo: topAnchor),
            visualEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        buildColorPalette()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else {
            super.scrollWheel(with: event)
            return
        }

        if currentTool == .text {
            let step: CGFloat = delta > 0 ? 2 : -2
            let newSize = min(96, max(8, currentStyle.fontSize + step))
            if newSize != currentStyle.fontSize {
                currentStyle.fontSize = newSize
                notifyStyleChanged()
                updateSizeDisplay()
            }
        } else {
            let step: CGFloat = delta > 0 ? 1 : -1
            let newWidth = min(50, max(1, currentStyle.lineWidth + step))
            if newWidth != currentStyle.lineWidth {
                currentStyle.lineWidth = newWidth
                notifyStyleChanged()
                updateSizeDisplay()
            }
        }
    }

    func update(tool: ScreenshotAnnotationTool, style: ScreenshotAnnotationStyle) {
        self.currentTool = tool
        self.currentStyle = style

        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        rebuildControls(for: tool)
        contentStack.addArrangedSubview(controlStack)

        if tool != .mosaic {
            let divider = makeDivider()
            contentStack.addArrangedSubview(divider)
            contentStack.addArrangedSubview(colorStack)
            updateColorSelection()
        }
    }

    private func makeDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 1),
            box.heightAnchor.constraint(equalToConstant: 16)
        ])
        return box
    }

    private func rebuildControls(for tool: ScreenshotAnnotationTool) {
        controlStack.arrangedSubviews.forEach {
            controlStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        sizeDropdownButton = nil

        switch tool {
        case .rectangle, .ellipse:
            // 样式下拉框 (描边实线 / 描边虚线 / 填充实心)
            let currentStyleTitle: String
            if currentStyle.isFilled {
                currentStyleTitle = "填充实心"
            } else if currentStyle.isDashed {
                currentStyleTitle = "描边虚线"
            } else {
                currentStyleTitle = "描边实线"
            }
            let styleDropdown = DropdownPillButton(title: currentStyleTitle, iconSymbol: "square.dashed") { [weak self] btn in
                self?.showRectStyleMenu(for: btn)
            }
            controlStack.addArrangedSubview(styleDropdown)

            // 粗细下拉框 (数字)
            addLineWidthDropdown()

        case .freehand:
            // 粗细下拉框
            addLineWidthDropdown()

        case .line, .arrow:
            // 样式下拉框 (实线 / 虚线)
            let styleTitle = currentStyle.isDashed ? "虚线" : "实线"
            let styleDropdown = DropdownPillButton(title: styleTitle, iconSymbol: "line.horizontal.3.decrease") { [weak self] btn in
                self?.showLineStyleMenu(for: btn)
            }
            controlStack.addArrangedSubview(styleDropdown)

            // 粗细下拉框
            addLineWidthDropdown()

        case .text:
            // 字体下拉框
            let currentFontTitle = Self.fontFamilies.first(where: { $0.name == currentStyle.fontFamily })?.title ?? "系统默认"
            let fontDropdown = DropdownPillButton(title: currentFontTitle, iconSymbol: "textformat") { [weak self] btn in
                self?.showFontFamilyMenu(for: btn)
            }
            controlStack.addArrangedSubview(fontDropdown)

            // 字号下拉框 (数字)
            addFontSizeDropdown()

            // 加粗 / 斜体 / 边框背景
            let boldBtn = makeTextFormatButton(title: "B", tooltip: "加粗", isBold: true, selected: currentStyle.isBold) { [weak self] in
                guard let self else { return }
                self.currentStyle.isBold.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let italicBtn = makeTextFormatButton(title: "I", tooltip: "斜体", isItalic: true, selected: currentStyle.isItalic) { [weak self] in
                guard let self else { return }
                self.currentStyle.isItalic.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let borderBtn = makeIconButton(
                symbol: "character.textbox",
                tooltip: currentStyle.hasBorder ? "文字背景框" : "纯文字",
                selected: currentStyle.hasBorder
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.hasBorder.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(boldBtn)
            controlStack.addArrangedSubview(italicBtn)
            controlStack.addArrangedSubview(borderBtn)

        case .number:
            // 样式下拉框 (实心序号 / 空心序号)
            let styleTitle = currentStyle.numberStyle == 1 ? "空心序号" : "实心序号"
            let styleDropdown = DropdownPillButton(title: styleTitle, iconSymbol: "1.circle") { [weak self] btn in
                self?.showNumberStyleMenu(for: btn)
            }
            controlStack.addArrangedSubview(styleDropdown)

            // 尺寸/粗细下拉框
            addLineWidthDropdown()

        case .mosaic:
            // 模式与类型下拉框 (涂抹像素 / 涂抹模糊 / 矩形像素 / 矩形模糊)
            let modeTitle: String
            switch (currentStyle.shapeType, currentStyle.hasBorder) {
            case (0, false): modeTitle = "涂抹 · 像素"
            case (0, true):  modeTitle = "涂抹 · 模糊"
            case (1, false): modeTitle = "矩形 · 像素"
            case (1, true):  modeTitle = "矩形 · 模糊"
            default:         modeTitle = "涂抹 · 像素"
            }
            let modeDropdown = DropdownPillButton(title: modeTitle, iconSymbol: "square.grid.3x3.fill") { [weak self] btn in
                self?.showMosaicModeMenu(for: btn)
            }
            controlStack.addArrangedSubview(modeDropdown)

            // 粗细/颗粒度下拉框
            addLineWidthDropdown()
        }
    }

    private func addLineWidthDropdown() {
        let sizeVal = Int(currentStyle.lineWidth)
        let btn = DropdownPillButton(title: "\(sizeVal)", iconSymbol: "scribble") { [weak self] sender in
            self?.showLineWidthMenu(for: sender)
        }
        btn.toolTip = "线条粗细（滚轮可调节）"
        btn.onScroll = { [weak self] delta in
            guard let self else { return }
            let step: CGFloat = delta > 0 ? 1 : -1
            let newWidth = min(50, max(1, self.currentStyle.lineWidth + step))
            if newWidth != self.currentStyle.lineWidth {
                self.currentStyle.lineWidth = newWidth
                self.notifyStyleChanged()
                self.updateSizeDisplay()
            }
        }
        sizeDropdownButton = btn
        controlStack.addArrangedSubview(btn)
    }

    private func addFontSizeDropdown() {
        let sizeVal = Int(currentStyle.fontSize)
        let btn = DropdownPillButton(title: "\(sizeVal)", iconSymbol: "text.cursor") { [weak self] sender in
            self?.showFontSizeMenu(for: sender)
        }
        btn.toolTip = "字号大小（滚轮可调节）"
        btn.onScroll = { [weak self] delta in
            guard let self else { return }
            let step: CGFloat = delta > 0 ? 2 : -2
            let newSize = min(96, max(8, self.currentStyle.fontSize + step))
            if newSize != self.currentStyle.fontSize {
                self.currentStyle.fontSize = newSize
                self.notifyStyleChanged()
                self.updateSizeDisplay()
            }
        }
        sizeDropdownButton = btn
        controlStack.addArrangedSubview(btn)
    }

    private func updateSizeDisplay() {
        if currentTool == .text {
            sizeDropdownButton?.title = "\(Int(currentStyle.fontSize))"
        } else {
            sizeDropdownButton?.title = "\(Int(currentStyle.lineWidth))"
        }
    }

    // MARK: - Dropdown Menus

    private func showRectStyleMenu(for sender: NSView) {
        let menu = NSMenu()
        let items: [(title: String, isFilled: Bool, isDashed: Bool)] = [
            ("描边实线", false, false),
            ("描边虚线", false, true),
            ("填充实心", true, false)
        ]
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(onRectStyleSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            if currentStyle.isFilled == item.isFilled && currentStyle.isDashed == item.isDashed {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onRectStyleSelected(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (title: String, isFilled: Bool, isDashed: Bool) else { return }
        currentStyle.isFilled = tuple.isFilled
        currentStyle.isDashed = tuple.isDashed
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showLineStyleMenu(for sender: NSView) {
        let menu = NSMenu()
        let items: [(title: String, isDashed: Bool)] = [
            ("实线", false),
            ("虚线", true)
        ]
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(onLineStyleSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.isDashed
            if currentStyle.isDashed == item.isDashed {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onLineStyleSelected(_ sender: NSMenuItem) {
        guard let isDashed = sender.representedObject as? Bool else { return }
        currentStyle.isDashed = isDashed
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showNumberStyleMenu(for sender: NSView) {
        let menu = NSMenu()
        let items: [(title: String, style: Int)] = [
            ("实心序号", 0),
            ("空心序号", 1)
        ]
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(onNumberStyleSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.style
            if currentStyle.numberStyle == item.style {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onNumberStyleSelected(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? Int else { return }
        currentStyle.numberStyle = style
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showMosaicModeMenu(for sender: NSView) {
        let menu = NSMenu()
        let items: [(title: String, shape: Int, isBlur: Bool)] = [
            ("涂抹 · 像素", 0, false),
            ("涂抹 · 模糊", 0, true),
            ("矩形 · 像素", 1, false),
            ("矩形 · 模糊", 1, true)
        ]
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(onMosaicModeSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = (item.shape, item.isBlur)
            if currentStyle.shapeType == item.shape && currentStyle.hasBorder == item.isBlur {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onMosaicModeSelected(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (shape: Int, isBlur: Bool) else { return }
        currentStyle.shapeType = tuple.shape
        currentStyle.hasBorder = tuple.isBlur
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showLineWidthMenu(for sender: NSView) {
        let menu = NSMenu()
        for width in Self.presetLineWidths {
            let menuItem = NSMenuItem(title: "\(Int(width)) px", action: #selector(onLineWidthSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = width
            if abs(currentStyle.lineWidth - width) < 0.5 {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onLineWidthSelected(_ sender: NSMenuItem) {
        guard let width = sender.representedObject as? CGFloat else { return }
        currentStyle.lineWidth = width
        notifyStyleChanged()
        updateSizeDisplay()
    }

    private func showFontFamilyMenu(for sender: NSView) {
        let menu = NSMenu()
        for font in Self.fontFamilies {
            let menuItem = NSMenuItem(title: font.title, action: #selector(onFontFamilySelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = font.name
            if currentStyle.fontFamily == font.name {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onFontFamilySelected(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        currentStyle.fontFamily = name
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showFontSizeMenu(for sender: NSView) {
        let menu = NSMenu()
        for size in Self.presetFontSizes {
            let menuItem = NSMenuItem(title: "\(Int(size)) pt", action: #selector(onFontSizeSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = size
            if abs(currentStyle.fontSize - size) < 0.5 {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onFontSizeSelected(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        currentStyle.fontSize = size
        notifyStyleChanged()
        updateSizeDisplay()
    }

    private func showMenu(_ menu: NSMenu, for view: NSView) {
        let location = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: menu.item(at: 0), at: location, in: view)
    }

    // MARK: - Color Palette

    private func buildColorPalette() {
        colorStack.arrangedSubviews.forEach {
            colorStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        colorButtons.removeAll()

        for (index, color) in Self.presetColors.enumerated() {
            let btn = ColorDotButton(color: color, isSelected: false) { [weak self] in
                guard let self else { return }
                self.currentStyle.color = color
                self.notifyStyleChanged()
                self.updateColorSelection()
            }
            btn.tag = index
            colorButtons.append(btn)
            colorStack.addArrangedSubview(btn)
        }
    }

    private func updateColorSelection() {
        for btn in colorButtons {
            let isSelected = currentStyle.color.isEqual(btn.color)
            btn.isSelected = isSelected
        }
    }

    private func makeIconButton(
        symbol: String,
        tooltip: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let btn = IconOnlyButton(symbolName: symbol, tooltip: tooltip, isSelected: selected, action: action)
        return btn
    }

    private func makeTextFormatButton(
        title: String,
        tooltip: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        selected: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let btn = TextFormatButton(title: title, tooltip: tooltip, isBold: isBold, isItalic: isItalic, isSelected: selected, action: action)
        return btn
    }

    private func notifyStyleChanged() {
        onStyleChanged?(currentStyle)
    }
}

// MARK: - Dropdown Pill Button

final class DropdownPillButton: NSButton {
    private let clickAction: (NSView) -> Void
    var onScroll: ((CGFloat) -> Void)?

    init(title: String, iconSymbol: String? = nil, action: @escaping (NSView) -> Void) {
        self.clickAction = action
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.06).cgColor
        self.font = .systemFont(ofSize: 11.5, weight: .medium)
        self.contentTintColor = NSColor(white: 0.18, alpha: 1.0)
        self.alignment = .center

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        self.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(chevronConfig)
        self.imagePosition = .imageRight
        self.imageScaling = .scaleProportionallyDown

        translatesAutoresizingMaskIntoConstraints = false
        let titleWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        let minW: CGFloat = max(34, titleWidth + 24)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: minW),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        target = self
        self.action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() {
        clickAction(self)
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScroll {
            onScroll(event.scrollingDeltaY)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
    }
}

// MARK: - Native Sub-toolbar Controls

final class IconOnlyButton: NSButton {
    private let actionClosure: () -> Void
    var isSelectedState: Bool {
        didSet { updateAppearance() }
    }

    init(symbolName: String, tooltip: String, isSelected: Bool, action: @escaping () -> Void) {
        self.actionClosure = action
        self.isSelectedState = isSelected
        super.init(frame: .zero)
        self.title = ""
        self.attributedTitle = NSAttributedString()
        self.isBordered = false
        self.imagePosition = .imageOnly
        self.toolTip = tooltip
        self.wantsLayer = true
        self.layer?.cornerRadius = 5

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        self.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        self.imageScaling = .scaleProportionallyDown

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        target = self
        self.action = #selector(handleClick)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() {
        actionClosure()
    }

    private func updateAppearance() {
        if isSelectedState {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            contentTintColor = .systemBlue
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor(white: 0.25, alpha: 1.0)
        }
    }
}

final class TextFormatButton: NSButton {
    private let actionClosure: () -> Void
    var isSelectedState: Bool {
        didSet { updateAppearance() }
    }

    init(title: String, tooltip: String, isBold: Bool, isItalic: Bool, isSelected: Bool, action: @escaping () -> Void) {
        self.actionClosure = action
        self.isSelectedState = isSelected
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.toolTip = tooltip
        self.wantsLayer = true
        self.layer?.cornerRadius = 5

        var font = NSFont.systemFont(ofSize: 13, weight: isBold ? .bold : .medium)
        if isItalic {
            let desc = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: desc, size: 13) ?? font
        }
        self.font = font

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        target = self
        self.action = #selector(handleClick)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() {
        actionClosure()
    }

    private func updateAppearance() {
        if isSelectedState {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            contentTintColor = .systemBlue
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor(white: 0.25, alpha: 1.0)
        }
    }
}

final class ColorDotButton: NSButton {
    let color: NSColor
    private let actionClosure: () -> Void
    var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    init(color: NSColor, isSelected: Bool, action: @escaping () -> Void) {
        self.color = color
        self.isSelected = isSelected
        self.actionClosure = action
        super.init(frame: .zero)
        self.title = ""
        self.attributedTitle = NSAttributedString()
        self.isBordered = false
        self.imagePosition = .noImage
        self.wantsLayer = true

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20)
        ])
        target = self
        self.action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() {
        actionClosure()
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dotRadius: CGFloat = 7.5
        let dotRect = CGRect(x: center.x - dotRadius, y: center.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

        if isSelected {
            // Outer selection ring
            let ringRect = bounds.insetBy(dx: 1, dy: 1)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1.5
            color.setStroke()
            ringPath.stroke()

            // Inner dot
            let innerRadius: CGFloat = 5.5
            let innerRect = CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
            let innerPath = NSBezierPath(ovalIn: innerRect)
            color.setFill()
            innerPath.fill()
        } else {
            let dotPath = NSBezierPath(ovalIn: dotRect)
            color.setFill()
            dotPath.fill()

            // Subtle border for white / very bright colors
            NSColor(white: 0.0, alpha: 0.15).setStroke()
            dotPath.lineWidth = 0.5
            dotPath.stroke()
        }
    }
}
