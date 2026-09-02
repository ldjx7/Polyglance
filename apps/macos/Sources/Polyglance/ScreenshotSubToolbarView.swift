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
    private var lineWidthButtons: [LineWidthButton] = []

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
        controlStack.spacing = 3

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
        lineWidthButtons.removeAll()

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

            let fillBtn = makeIconButton(
                symbol: currentStyle.isFilled ? "square.fill" : "square",
                tooltip: currentStyle.isFilled ? "实心填充" : "空心轮廓",
                selected: currentStyle.isFilled
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.isFilled.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(fillBtn)

            let dashBtn = makeIconButton(
                symbol: "line.horizontal.3.decrease",
                tooltip: currentStyle.isDashed ? "虚线" : "实线",
                selected: currentStyle.isDashed
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.isDashed.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(dashBtn)
            addLineWidthButtons()

        case .freehand:
            addLineWidthButtons()

        case .line:
            let lineBtn = makeIconButton(symbol: "line.diagonal", tooltip: "直线", selected: !currentStyle.hasArrow) { [weak self] in
                guard let self else { return }
                self.currentStyle.hasArrow = false
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let arrowBtn = makeIconButton(symbol: "arrow.up.right", tooltip: "箭头", selected: currentStyle.hasArrow) { [weak self] in
                guard let self else { return }
                self.currentStyle.hasArrow = true
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(lineBtn)
            controlStack.addArrangedSubview(arrowBtn)

            let dashBtn = makeIconButton(
                symbol: "line.horizontal.3.decrease",
                tooltip: currentStyle.isDashed ? "虚线" : "实线",
                selected: currentStyle.isDashed
            ) { [weak self] in
                guard let self else { return }
                self.currentStyle.isDashed.toggle()
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(dashBtn)
            addLineWidthButtons()

        case .arrow:
            addLineWidthButtons()

        case .text:
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
            addFontSizeButtons()

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
            addLineWidthButtons()

        case .mosaic:
            let brushBtn = makeIconButton(symbol: "scribble", tooltip: "涂抹马赛克", selected: currentStyle.shapeType == 0) { [weak self] in
                guard let self else { return }
                self.currentStyle.shapeType = 0
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let rectBtn = makeIconButton(symbol: "rectangle.dashed", tooltip: "矩形马赛克", selected: currentStyle.shapeType == 1) { [weak self] in
                guard let self else { return }
                self.currentStyle.shapeType = 1
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(brushBtn)
            controlStack.addArrangedSubview(rectBtn)

            let pixelBtn = makeIconButton(symbol: "square.grid.3x3.fill", tooltip: "像素颗粒", selected: !currentStyle.hasBorder) { [weak self] in
                guard let self else { return }
                self.currentStyle.hasBorder = false
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            let blurBtn = makeIconButton(symbol: "sparkles", tooltip: "高斯模糊", selected: currentStyle.hasBorder) { [weak self] in
                guard let self else { return }
                self.currentStyle.hasBorder = true
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(pixelBtn)
            controlStack.addArrangedSubview(blurBtn)
            addLineWidthButtons()
        }
    }

    private func addLineWidthButtons() {
        let sizes: [CGFloat] = [2, 4, 8]
        for size in sizes {
            let isSelected = abs(currentStyle.lineWidth - size) < 0.5
            let btn = LineWidthButton(dotSize: size, isSelected: isSelected) { [weak self] in
                guard let self else { return }
                self.currentStyle.lineWidth = size
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            lineWidthButtons.append(btn)
            controlStack.addArrangedSubview(btn)
        }
    }

    private func addFontSizeButtons() {
        let fontSizes: [(String, CGFloat)] = [("小", 14), ("中", 18), ("大", 26)]
        for (label, size) in fontSizes {
            let isSelected = abs(currentStyle.fontSize - size) < 1.0
            let btn = TextPillButton(title: label, isSelected: isSelected) { [weak self] in
                guard let self else { return }
                self.currentStyle.fontSize = size
                self.notifyStyleChanged()
                self.rebuildControls(for: self.currentTool)
            }
            controlStack.addArrangedSubview(btn)
        }
    }

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

        let pickerBtn = makeIconButton(symbol: "paintpalette", tooltip: "自定义颜色", selected: false) { [weak self] in
            guard let self else { return }
            NSColorPanel.shared.color = self.currentStyle.color
            NSColorPanel.shared.setTarget(self)
            NSColorPanel.shared.setAction(#selector(self.onCustomColorPanelChanged(_:)))
            NSColorPanel.shared.orderFront(nil)
        }
        colorStack.addArrangedSubview(pickerBtn)
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

    @objc private func onCustomColorPanelChanged(_ sender: NSColorPanel) {
        currentStyle.color = sender.color
        notifyStyleChanged()
        updateColorSelection()
    }

    private func notifyStyleChanged() {
        onStyleChanged?(currentStyle)
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

final class TextPillButton: NSButton {
    private let actionClosure: () -> Void
    var isSelectedState: Bool {
        didSet { updateAppearance() }
    }

    init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.actionClosure = action
        self.isSelectedState = isSelected
        super.init(frame: .zero)
        self.title = title
        self.isBordered = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 4
        self.font = .systemFont(ofSize: 11, weight: isSelected ? .bold : .regular)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22)
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

final class LineWidthButton: NSButton {
    let dotSize: CGFloat
    private let actionClosure: () -> Void
    var isSelectedState: Bool {
        didSet { needsDisplay = true }
    }

    init(dotSize: CGFloat, isSelected: Bool, action: @escaping () -> Void) {
        self.dotSize = dotSize
        self.isSelectedState = isSelected
        self.actionClosure = action
        super.init(frame: .zero)
        self.title = ""
        self.attributedTitle = NSAttributedString()
        self.isBordered = false
        self.imagePosition = .noImage
        self.toolTip = "粗细 \(Int(dotSize))px"
        self.wantsLayer = true
        self.layer?.cornerRadius = 4

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
        if isSelectedState {
            let bgRect = bounds.insetBy(dx: 1, dy: 1)
            let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
            NSColor.systemBlue.withAlphaComponent(0.16).setFill()
            bgPath.fill()
        }

        let dotRect = CGRect(
            x: (bounds.width - dotSize) / 2,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        let dotPath = NSBezierPath(ovalIn: dotRect)
        if isSelectedState {
            NSColor.systemBlue.setFill()
        } else {
            NSColor(white: 0.3, alpha: 1.0).setFill()
        }
        dotPath.fill()
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
