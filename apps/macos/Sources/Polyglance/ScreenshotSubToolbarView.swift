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
    private var sizeButton: SizeStepperButton?

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
        controlStack.spacing = 4

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
        sizeButton = nil

        switch tool {
        case .rectangle, .ellipse:
            // 1. 形状切换: [ ▢ ] [ ○ ]
            let rectBtn = makeIconButton(symbol: "rectangle", tooltip: "矩形", selected: tool == .rectangle) { [weak self] in
                self?.onToolChanged?(.rectangle)
            }
            let ellipseBtn = makeIconButton(symbol: "circle", tooltip: "椭圆", selected: tool == .ellipse) { [weak self] in
                self?.onToolChanged?(.ellipse)
            }
            controlStack.addArrangedSubview(rectBtn)
            controlStack.addArrangedSubview(ellipseBtn)

            // 2. 填充复选按钮: [ ▢ 填充 ]
            let fillCheckbox = FillCheckboxButton(title: "填充", isChecked: currentStyle.isFilled) { [weak self] in
                guard let self else { return }
                self.currentStyle.isFilled.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(fillCheckbox)

            // 3. 线条样式图形下拉框 (实线/虚线/点线/点划线)
            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)

            // 4. 线宽步进按钮: [ ≡ 3 ]
            addLineWidthStepper()

        case .freehand:
            // 线条样式下拉框
            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)

            // 线宽步进按钮
            addLineWidthStepper()

        case .line, .arrow:
            // 1. 箭头类型图形下拉框 (8 种样式)
            let arrowDropdown = makeArrowStyleDropdownButton()
            controlStack.addArrangedSubview(arrowDropdown)

            // 2. 线条样式图形下拉框
            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)

            // 3. 线宽步进按钮
            addLineWidthStepper()

        case .text:
            // 字体下拉框
            let currentFontTitle = Self.fontFamilies.first(where: { $0.name == currentStyle.fontFamily })?.title ?? "系统默认"
            let fontDropdown = DropdownPillButton(title: currentFontTitle, minWidth: 70) { [weak self] btn in
                self?.showFontFamilyMenu(for: btn)
            }
            controlStack.addArrangedSubview(fontDropdown)

            // 字号下拉框
            addFontSizeStepper()

            // 加粗 / 斜体 / 边框
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
            // 序号样式切换
            let filledBtn = makeIconButton(symbol: "1.circle.fill", tooltip: "实心序号", selected: currentStyle.numberStyle == 0) { [weak self] in
                guard let self else { return }
                self.currentStyle.numberStyle = 0
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let outlineBtn = makeIconButton(symbol: "1.circle", tooltip: "空心序号", selected: currentStyle.numberStyle == 1) { [weak self] in
                guard let self else { return }
                self.currentStyle.numberStyle = 1
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(filledBtn)
            controlStack.addArrangedSubview(outlineBtn)

            // 尺寸
            addLineWidthStepper()

        case .mosaic:
            // 模式选择
            let modeTitle: String
            switch (currentStyle.shapeType, currentStyle.hasBorder) {
            case (0, false): modeTitle = "涂抹 · 像素"
            case (0, true):  modeTitle = "涂抹 · 模糊"
            case (1, false): modeTitle = "矩形 · 像素"
            case (1, true):  modeTitle = "矩形 · 模糊"
            default:         modeTitle = "涂抹 · 像素"
            }
            let modeDropdown = DropdownPillButton(title: modeTitle, minWidth: 80) { [weak self] btn in
                self?.showMosaicModeMenu(for: btn)
            }
            controlStack.addArrangedSubview(modeDropdown)

            // 粗细
            addLineWidthStepper()
        }
    }

    private func addLineWidthStepper() {
        let sizeVal = Int(currentStyle.lineWidth)
        let btn = SizeStepperButton(value: sizeVal, suffix: "") { [weak self] sender in
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
        sizeButton = btn
        controlStack.addArrangedSubview(btn)
    }

    private func addFontSizeStepper() {
        let sizeVal = Int(currentStyle.fontSize)
        let btn = SizeStepperButton(value: sizeVal, suffix: "pt") { [weak self] sender in
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
        sizeButton = btn
        controlStack.addArrangedSubview(btn)
    }

    private func updateSizeDisplay() {
        if currentTool == .text {
            sizeButton?.value = Int(currentStyle.fontSize)
        } else {
            sizeButton?.value = Int(currentStyle.lineWidth)
        }
    }

    // MARK: - Graphical Dropdowns

    private func makeDashLineDropdownButton() -> NSView {
        let img = Self.makeDashLineImage(pattern: currentStyle.lineDashPattern, isSelected: false, width: 36)
        let btn = ImageDropdownPillButton(previewImage: img, tooltip: "线条样式") { [weak self] sender in
            self?.showLineDashMenu(for: sender)
        }
        return btn
    }

    private func makeArrowStyleDropdownButton() -> NSView {
        let img = Self.makeArrowPreviewImage(arrowStyle: currentStyle.arrowStyle, isSelected: false, width: 44)
        let btn = ImageDropdownPillButton(previewImage: img, tooltip: "箭头样式") { [weak self] sender in
            self?.showArrowStyleMenu(for: sender)
        }
        return btn
    }

    // MARK: - Menus

    private func showLineDashMenu(for sender: NSView) {
        let menu = NSMenu()
        let patterns: [(title: String, pattern: Int)] = [
            ("实线", 0),
            ("长虚线", 1),
            ("点线", 2),
            ("点划线", 3)
        ]
        for item in patterns {
            let isSel = currentStyle.lineDashPattern == item.pattern
            let img = Self.makeDashLineImage(pattern: item.pattern, isSelected: isSel, width: 72)
            let menuItem = NSMenuItem(title: "", action: #selector(onLineDashSelected(_:)), keyEquivalent: "")
            menuItem.image = img
            menuItem.target = self
            menuItem.representedObject = item.pattern
            if isSel {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onLineDashSelected(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? Int else { return }
        currentStyle.lineDashPattern = pattern
        currentStyle.isDashed = pattern != 0
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    private func showArrowStyleMenu(for sender: NSView) {
        let menu = NSMenu()
        for arrowStyle in 0...7 {
            let isSel = currentStyle.arrowStyle == arrowStyle
            let img = Self.makeArrowPreviewImage(arrowStyle: arrowStyle, isSelected: isSel, width: 80)
            let menuItem = NSMenuItem(title: "", action: #selector(onArrowStyleSelected(_:)), keyEquivalent: "")
            menuItem.image = img
            menuItem.target = self
            menuItem.representedObject = arrowStyle
            if isSel {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        showMenu(menu, for: sender)
    }

    @objc private func onArrowStyleSelected(_ sender: NSMenuItem) {
        guard let arrowStyle = sender.representedObject as? Int else { return }
        currentStyle.arrowStyle = arrowStyle
        currentStyle.hasArrow = arrowStyle != 7
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

    // MARK: - Image Generators

    static func makeDashLineImage(pattern: Int, isSelected: Bool, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(isSelected ? NSColor.systemBlue.cgColor : NSColor(white: 0.22, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineCap(.round)
            switch pattern {
            case 0:
                break
            case 1:
                ctx.setLineDash(phase: 0, lengths: [6, 3])
            case 2:
                ctx.setLineDash(phase: 0, lengths: [2, 3])
            case 3:
                ctx.setLineDash(phase: 0, lengths: [8, 3, 2, 3])
            default:
                break
            }
            ctx.beginPath()
            ctx.move(to: CGPoint(x: 2, y: 9))
            ctx.addLine(to: CGPoint(x: width - 2, y: 9))
            ctx.strokePath()
            return true
        }
        img.isTemplate = false
        return img
    }

    static func makeArrowPreviewImage(arrowStyle: Int, isSelected: Bool, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let color = isSelected ? NSColor.systemBlue : NSColor(white: 0.22, alpha: 1.0)
            let dummyStyle = ScreenshotAnnotationStyle(color: color, lineWidth: 2, arrowStyle: arrowStyle)
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ScreenshotAnnotationRenderer.drawArrowGeometry(
                from: CGPoint(x: 4, y: 9),
                to: CGPoint(x: width - 4, y: 9),
                style: dummyStyle,
                lineWidth: 2.0,
                in: ctx
            )
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Custom Controls

final class FillCheckboxButton: NSButton {
    private let actionClosure: () -> Void
    var isChecked: Bool {
        didSet { updateAppearance() }
    }

    init(title: String, isChecked: Bool, action: @escaping () -> Void) {
        self.actionClosure = action
        self.isChecked = isChecked
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.font = .systemFont(ofSize: 11.5, weight: .medium)
        self.imageScaling = .scaleProportionallyDown
        self.imagePosition = .imageLeft

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 52)
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
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let iconName = isChecked ? "checkmark.square.fill" : "square"
        self.image = NSImage(systemSymbolName: iconName, accessibilityDescription: title)?.withSymbolConfiguration(config)
        if isChecked {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.14).cgColor
            contentTintColor = .systemBlue
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            contentTintColor = NSColor(white: 0.25, alpha: 1.0)
        }
    }
}

final class ImageDropdownPillButton: NSButton {
    private let clickAction: (NSView) -> Void

    init(previewImage: NSImage, tooltip: String, action: @escaping (NSView) -> Void) {
        self.clickAction = action
        super.init(frame: .zero)
        self.title = ""
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.06).cgColor
        self.toolTip = tooltip

        // Combine preview image and chevron down into a single composite image
        let combinedW = previewImage.size.width + 16
        let combinedSize = NSSize(width: combinedW, height: 24)
        let composite = NSImage(size: combinedSize, flipped: false) { rect in
            previewImage.draw(in: CGRect(x: 3, y: 3, width: previewImage.size.width, height: 18))
            let chevronConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(chevronConfig) {
                chevron.draw(in: CGRect(x: previewImage.size.width + 5, y: 7, width: 8, height: 10))
            }
            return true
        }
        self.image = composite
        self.imagePosition = .imageOnly

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: combinedW + 4),
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
}

final class SizeStepperButton: NSButton {
    private let clickAction: (NSView) -> Void
    var onScroll: ((CGFloat) -> Void)?
    var suffix: String
    var value: Int {
        didSet { updateTitle() }
    }

    init(value: Int, suffix: String = "", action: @escaping (NSView) -> Void) {
        self.value = value
        self.suffix = suffix
        self.clickAction = action
        super.init(frame: .zero)
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.06).cgColor
        self.font = .systemFont(ofSize: 11.5, weight: .semibold)
        self.contentTintColor = NSColor(white: 0.2, alpha: 1.0)
        self.imagePosition = .imageLeft

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        self.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(config)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        target = self
        self.action = #selector(handleClick)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        self.title = suffix.isEmpty ? " \(value)" : " \(value) \(suffix)"
    }

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
}

final class DropdownPillButton: NSButton {
    private let clickAction: (NSView) -> Void
    var onScroll: ((CGFloat) -> Void)?

    init(title: String, minWidth: CGFloat = 40, action: @escaping (NSView) -> Void) {
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
        let minW: CGFloat = max(minWidth, titleWidth + 24)
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
}

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
            let ringRect = bounds.insetBy(dx: 1, dy: 1)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1.5
            color.setStroke()
            ringPath.stroke()

            let innerRadius: CGFloat = 5.5
            let innerRect = CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
            let innerPath = NSBezierPath(ovalIn: innerRect)
            color.setFill()
            innerPath.fill()
        } else {
            let dotPath = NSBezierPath(ovalIn: dotRect)
            color.setFill()
            dotPath.fill()

            NSColor(white: 0.0, alpha: 0.15).setStroke()
            dotPath.lineWidth = 0.5
            dotPath.stroke()
        }
    }
}
