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
    private var activePopover: NSPopover?

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
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 10

        visualEffectView.material = .popover
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 0.5
        visualEffectView.layer?.borderColor = NSColor(white: 0.0, alpha: 0.10).cgColor
        visualEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(visualEffectView)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
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
            let rectBtn = makeIconButton(symbol: "rectangle", tooltip: "矩形", selected: tool == .rectangle) { [weak self] in
                self?.onToolChanged?(.rectangle)
            }
            let ellipseBtn = makeIconButton(symbol: "circle", tooltip: "椭圆", selected: tool == .ellipse) { [weak self] in
                self?.onToolChanged?(.ellipse)
            }
            controlStack.addArrangedSubview(rectBtn)
            controlStack.addArrangedSubview(ellipseBtn)

            let fillCheckbox = FillCheckboxButton(title: "填充", isChecked: currentStyle.isFilled) { [weak self] in
                guard let self else { return }
                self.currentStyle.isFilled.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(fillCheckbox)

            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)

            addLineWidthStepper()

        case .freehand:
            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)
            addLineWidthStepper()

        case .line, .arrow:
            let arrowDropdown = makeArrowStyleDropdownButton()
            controlStack.addArrangedSubview(arrowDropdown)

            let dashDropdown = makeDashLineDropdownButton()
            controlStack.addArrangedSubview(dashDropdown)

            addLineWidthStepper()

        case .text:
            let currentFontTitle = Self.fontFamilies.first(where: { $0.name == currentStyle.fontFamily })?.title ?? "系统默认"
            let fontDropdown = DropdownPillButton(title: currentFontTitle, minWidth: 70) { [weak self] btn in
                self?.showFontFamilyMenu(for: btn)
            }
            controlStack.addArrangedSubview(fontDropdown)

            addFontSizeStepper()

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
            addLineWidthStepper()

        case .mosaic:
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
            addLineWidthStepper()
        }
    }

    private func addLineWidthStepper() {
        let sizeVal = Int(currentStyle.lineWidth)
        let btn = SizeStepperButton(value: sizeVal, suffix: "") { [weak self] sender in
            self?.showLineWidthSliderPopover(for: sender)
        }
        btn.toolTip = "线条粗细（点击滑动条/滚轮调节）"
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
        let btn = DropdownPillButton(title: "\(sizeVal) pt", minWidth: 54) { [weak self] sender in
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
                btn.title = "\(Int(newSize)) pt"
            }
        }
        controlStack.addArrangedSubview(btn)
    }

    private func updateSizeDisplay() {
        if currentTool != .text {
            sizeButton?.value = Int(currentStyle.lineWidth)
        }
    }

    // MARK: - Graphical Dropdown Buttons

    private func makeDashLineDropdownButton() -> NSView {
        let img = Self.makeDashLineImage(pattern: currentStyle.lineDashPattern, isSelected: false, width: 36)
        let btn = ImageDropdownPillButton(previewImage: img, tooltip: "线条样式") { [weak self] sender in
            self?.showLineDashPopover(for: sender)
        }
        return btn
    }

    private func makeArrowStyleDropdownButton() -> NSView {
        let img = Self.makeArrowPreviewImage(arrowStyle: currentStyle.arrowStyle, isSelected: false, width: 42)
        let btn = ImageDropdownPillButton(previewImage: img, tooltip: "箭头样式") { [weak self] sender in
            self?.showArrowStylePopover(for: sender)
        }
        return btn
    }

    // MARK: - Popovers

    private func showLineWidthSliderPopover(for sender: NSView) {
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 170, height: 42))

        let slider = NSSlider(value: Double(currentStyle.lineWidth), minValue: 1.0, maxValue: 50.0, target: nil, action: nil)
        slider.isContinuous = true
        slider.frame = NSRect(x: 10, y: 11, width: 110, height: 20)

        let label = NSTextField(labelWithString: "\(Int(currentStyle.lineWidth)) px")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .right
        label.frame = NSRect(x: 122, y: 13, width: 38, height: 16)

        slider.target = self
        slider.action = #selector(onSliderValueChanged(_:))

        container.addSubview(slider)
        container.addSubview(label)

        let viewController = NSViewController()
        viewController.view = container
        popover.contentViewController = viewController

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        activePopover = popover
    }

    @objc private func onSliderValueChanged(_ sender: NSSlider) {
        let val = round(CGFloat(sender.doubleValue))
        currentStyle.lineWidth = val
        notifyStyleChanged()
        updateSizeDisplay()

        if let container = sender.superview,
           let label = container.subviews.compactMap({ $0 as? NSTextField }).first {
            label.stringValue = "\(Int(val)) px"
        }
    }

    private func showArrowStylePopover(for sender: NSView) {
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        for arrowStyle in 0...8 {
            let isSel = currentStyle.arrowStyle == arrowStyle
            let btn = PopoverItemButton(
                image: Self.makeArrowPreviewImage(arrowStyle: arrowStyle, isSelected: isSel, width: 76),
                isSelected: isSel
            ) { [weak self, weak popover] in
                guard let self else { return }
                self.currentStyle.arrowStyle = arrowStyle
                self.currentStyle.hasArrow = arrowStyle != 8
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
                popover?.close()
            }
            stack.addArrangedSubview(btn)
        }

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        activePopover = popover
    }

    private func showLineDashPopover(for sender: NSView) {
        activePopover?.close()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        for pattern in 0...3 {
            let isSel = currentStyle.lineDashPattern == pattern
            let btn = PopoverItemButton(
                image: Self.makeDashLineImage(pattern: pattern, isSelected: isSel, width: 70),
                isSelected: isSel
            ) { [weak self, weak popover] in
                guard let self else { return }
                self.currentStyle.lineDashPattern = pattern
                self.currentStyle.isDashed = pattern != 0
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
                popover?.close()
            }
            stack.addArrangedSubview(btn)
        }

        let container = NSView()
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let vc = NSViewController()
        vc.view = container
        popover.contentViewController = vc

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        activePopover = popover
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
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: menu.item(at: 0), at: location, in: sender)
    }

    @objc private func onMosaicModeSelected(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (shape: Int, isBlur: Bool) else { return }
        currentStyle.shapeType = tuple.shape
        currentStyle.hasBorder = tuple.isBlur
        notifyStyleChanged()
        rebuildControls(for: currentTool)
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
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: menu.item(at: 0), at: location, in: sender)
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
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: menu.item(at: 0), at: location, in: sender)
    }

    @objc private func onFontSizeSelected(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? CGFloat else { return }
        currentStyle.fontSize = size
        notifyStyleChanged()
        rebuildControls(for: currentTool)
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
            ctx.setStrokeColor(isSelected ? NSColor.white.cgColor : NSColor(white: 0.2, alpha: 1.0).cgColor)
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
            let color = isSelected ? NSColor.white : NSColor(white: 0.2, alpha: 1.0)
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

final class PopoverItemButton: NSButton {
    private let clickAction: () -> Void
    private let isSelectedState: Bool

    init(image: NSImage, isSelected: Bool, action: @escaping () -> Void) {
        self.isSelectedState = isSelected
        self.clickAction = action
        super.init(frame: .zero)
        self.title = ""
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 5
        self.image = image
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyDown

        if isSelected {
            self.layer?.backgroundColor = NSColor(srgbRed: 0.14, green: 0.48, blue: 0.95, alpha: 1.0).cgColor
        } else {
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: image.size.width + 12),
            heightAnchor.constraint(equalToConstant: 24)
        ])
        target = self
        self.action = #selector(handleClick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() {
        clickAction()
    }
}

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
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        self.toolTip = tooltip

        let combinedW = previewImage.size.width + 12
        let combinedSize = NSSize(width: combinedW, height: 24)
        let composite = NSImage(size: combinedSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            previewImage.draw(in: CGRect(x: 2, y: 3, width: previewImage.size.width, height: 18))

            // Subtle tiny caret ^ (width 6, height 3.5)
            let cx = previewImage.size.width + 6
            let cy: CGFloat = 11.5
            ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cx - 3, y: cy - 2))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 1.5))
            ctx.addLine(to: CGPoint(x: cx + 3, y: cy - 2))
            ctx.strokePath()
            return true
        }
        self.image = composite
        self.imagePosition = .imageOnly

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: combinedW + 2),
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
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        self.font = .systemFont(ofSize: 11.5, weight: .semibold)
        self.contentTintColor = NSColor(white: 0.2, alpha: 1.0)
        self.imagePosition = .imageLeft

        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        self.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(config)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
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
        self.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        self.font = .systemFont(ofSize: 11.5, weight: .medium)
        self.contentTintColor = NSColor(white: 0.2, alpha: 1.0)
        self.alignment = .center

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 7.5, weight: .bold)
        self.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(chevronConfig)
        self.imagePosition = .imageRight
        self.imageScaling = .scaleProportionallyDown

        translatesAutoresizingMaskIntoConstraints = false
        let titleWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        let minW: CGFloat = max(minWidth, titleWidth + 20)
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
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
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
            // Distinct outer glowing ring matching the reference screenshot
            let ringRect = bounds.insetBy(dx: 1, dy: 1)
            let ringPath = NSBezierPath(ovalIn: ringRect)
            ringPath.lineWidth = 1.5
            color.withAlphaComponent(0.85).setStroke()
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
