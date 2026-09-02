import AppKit

@MainActor
final class ScreenshotSubToolbarView: NSVisualEffectView {
    var onStyleChanged: ((ScreenshotAnnotationStyle) -> Void)?
    var onToolChanged: ((ScreenshotAnnotationTool) -> Void)?

    private(set) var currentTool: ScreenshotAnnotationTool = .rectangle
    private(set) var currentStyle: ScreenshotAnnotationStyle = .default

    private let contentStack = NSStackView()
    private let controlStack = NSStackView()
    private let colorStack = NSStackView()

    private var colorButtons: [NSButton] = []
    private var lineWidthButtons: [NSButton] = []

    private static let presetColors: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.26, blue: 0.21, alpha: 1.0), // Red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1.0), // Orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1.0), // Yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1.0), // Green
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1.0), // Blue
        NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0), // Dark
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 1.0)  // White
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
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.2).cgColor

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 4

        colorStack.orientation = .horizontal
        colorStack.alignment = .centerY
        colorStack.spacing = 5

        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
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

        let divider = NSBox()
        divider.boxType = .separator
        contentStack.addArrangedSubview(divider)

        contentStack.addArrangedSubview(colorStack)
        updateColorSelection()
    }

    private func rebuildControls(for tool: ScreenshotAnnotationTool) {
        controlStack.arrangedSubviews.forEach {
            controlStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        lineWidthButtons.removeAll()

        switch tool {
        case .rectangle, .ellipse:
            // Shape selector: Rect vs Ellipse
            let rectBtn = makeIconButton(symbol: "rectangle", tooltip: "矩形", selected: tool == .rectangle) { [weak self] in
                self?.onToolChanged?(.rectangle)
            }
            let ellipseBtn = makeIconButton(symbol: "circle", tooltip: "椭圆", selected: tool == .ellipse) { [weak self] in
                self?.onToolChanged?(.ellipse)
            }
            controlStack.addArrangedSubview(rectBtn)
            controlStack.addArrangedSubview(ellipseBtn)

            // Fill Toggle
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

            // Dashed Toggle
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
            // Straight vs Arrow
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
            addLineWidthButtons()
        }
    }

    private func addLineWidthButtons() {
        let sizes: [CGFloat] = [2, 4, 8]
        for size in sizes {
            let isSelected = abs(currentStyle.lineWidth - size) < 0.5
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 4
            btn.layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
            btn.toolTip = "线宽 \(Int(size))px"
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 22),
                btn.heightAnchor.constraint(equalToConstant: 22)
            ])

            let dot = CALayer()
            dot.cornerRadius = size / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.frame = CGRect(
                x: (22 - size) / 2,
                y: (22 - size) / 2,
                width: size,
                height: size
            )
            btn.layer?.addSublayer(dot)

            btn.target = self
            btn.action = #selector(onLineWidthClicked(_:))
            btn.tag = Int(size)
            lineWidthButtons.append(btn)
            controlStack.addArrangedSubview(btn)
        }
    }

    private func addFontSizeButtons() {
        let fontSizes: [(String, CGFloat)] = [("小", 14), ("中", 18), ("大", 26)]
        for (label, size) in fontSizes {
            let isSelected = abs(currentStyle.fontSize - size) < 1.0
            let btn = NSButton(title: label, target: self, action: #selector(onFontSizeClicked(_:)))
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 11, weight: isSelected ? .bold : .regular)
            btn.contentTintColor = isSelected ? .systemBlue : .white
            btn.tag = Int(size)
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 24),
                btn.heightAnchor.constraint(equalToConstant: 22)
            ])
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
            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.cornerRadius = 9
            btn.layer?.backgroundColor = color.cgColor
            btn.layer?.borderWidth = 1.5
            btn.layer?.borderColor = NSColor.clear.cgColor
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 18),
                btn.heightAnchor.constraint(equalToConstant: 18)
            ])

            btn.target = self
            btn.action = #selector(onColorClicked(_:))
            btn.tag = index
            colorButtons.append(btn)
            colorStack.addArrangedSubview(btn)
        }

        // Custom Color Picker Button
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
        for (index, btn) in colorButtons.enumerated() {
            let color = Self.presetColors[index]
            let isSelected = currentStyle.color.isEqual(color)
            btn.layer?.borderColor = isSelected ? NSColor.white.cgColor : NSColor.clear.cgColor
            btn.layer?.borderWidth = isSelected ? 2.0 : 1.0
        }
    }

    private func makeIconButton(
        symbol: String,
        tooltip: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> NSButton {
        let btn = ClosureButton(title: "", target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 4
        btn.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        btn.toolTip = tooltip
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(config)
        btn.imagePosition = .imageOnly
        btn.contentTintColor = selected ? .systemBlue : .white
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 24),
            btn.heightAnchor.constraint(equalToConstant: 22)
        ])
        btn.closure = action
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
        let btn = ClosureButton(title: title, target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 4
        btn.layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.25).cgColor : NSColor.clear.cgColor
        btn.toolTip = tooltip
        var font = NSFont.systemFont(ofSize: 13, weight: isBold ? .bold : .regular)
        if isItalic {
            let desc = font.fontDescriptor.withSymbolicTraits(.italic)
            font = NSFont(descriptor: desc, size: 13) ?? font
        }
        btn.font = font
        btn.contentTintColor = selected ? .systemBlue : .white
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 24),
            btn.heightAnchor.constraint(equalToConstant: 22)
        ])
        btn.closure = action
        return btn
    }

    @objc private func onLineWidthClicked(_ sender: NSButton) {
        currentStyle.lineWidth = CGFloat(sender.tag)
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    @objc private func onFontSizeClicked(_ sender: NSButton) {
        currentStyle.fontSize = CGFloat(sender.tag)
        notifyStyleChanged()
        rebuildControls(for: currentTool)
    }

    @objc private func onColorClicked(_ sender: NSButton) {
        guard sender.tag >= 0 && sender.tag < Self.presetColors.count else { return }
        currentStyle.color = Self.presetColors[sender.tag]
        notifyStyleChanged()
        updateColorSelection()
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

private final class ClosureButton: NSButton {
    var closure: (() -> Void)?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let closure {
            closure()
            return true
        }
        return super.sendAction(action, to: target)
    }
}
