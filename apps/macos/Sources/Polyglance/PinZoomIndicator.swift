import AppKit

@MainActor
final class PinZoomIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "100%")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(percent: Int, in parentBounds: CGRect) {
        hideWorkItem?.cancel()
        label.stringValue = "\(percent)%"

        let size = CGSize(width: 72, height: 32)
        frame = CGRect(
            x: round((parentBounds.width - size.width) / 2),
            y: round((parentBounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        isHidden = false

        let workItem = DispatchWorkItem { [weak self] in
            self?.isHidden = true
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }
}

@MainActor
final class PinToastIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        isHidden = true

        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(text: String, in parentBounds: CGRect, duration: TimeInterval = 1.0) {
        hideWorkItem?.cancel()
        label.stringValue = text

        let padding: CGFloat = 8
        let size = CGSize(width: 60, height: 26)
        frame = CGRect(
            x: max(0, parentBounds.maxX - size.width - padding),
            y: max(0, parentBounds.maxY - size.height - padding),
            width: size.width,
            height: size.height
        )
        isHidden = false

        let workItem = DispatchWorkItem { [weak self] in
            self?.isHidden = true
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }
}

@MainActor
final class CapsuleButton: NSButton {
    private var trackingArea: NSTrackingArea?

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 4

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(white: 0.15, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .paragraphStyle: style
            ]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 14, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.07).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
final class PinTextCapsuleBarView: NSView {
    var onCopy: (() -> Void)?
    var onHighlight: (() -> Void)?
    var onWavy: (() -> Void)?
    var onLine: (() -> Void)?
    var onStrikethrough: (() -> Void)?
    var onTranslate: (() -> Void)?

    private let stackView = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.98, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.borderColor = NSColor(white: 0.0, alpha: 0.12).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        isHidden = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        let copyBtn = CapsuleButton(title: "复制", target: self, action: #selector(handleCopy))
        let sep1 = makeSeparator()
        let highlightBtn = CapsuleButton(title: "荧光笔", target: self, action: #selector(handleHighlight))
        let wavyBtn = CapsuleButton(title: "波浪线", target: self, action: #selector(handleWavy))
        let lineBtn = CapsuleButton(title: "直线", target: self, action: #selector(handleLine))
        let strikeBtn = CapsuleButton(title: "删除线", target: self, action: #selector(handleStrikethrough))
        let sep2 = makeSeparator()
        let translateBtn = CapsuleButton(title: "翻译", target: self, action: #selector(handleTranslate))

        stackView.addArrangedSubview(copyBtn)
        stackView.addArrangedSubview(sep1)
        stackView.addArrangedSubview(highlightBtn)
        stackView.addArrangedSubview(wavyBtn)
        stackView.addArrangedSubview(lineBtn)
        stackView.addArrangedSubview(strikeBtn)
        stackView.addArrangedSubview(sep2)
        stackView.addArrangedSubview(translateBtn)

        addSubview(stackView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        stackView.frame = bounds
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        // Absorb background clicks within capsule bar
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.12).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 1),
            view.heightAnchor.constraint(equalToConstant: 13)
        ])
        return view
    }

    @objc private func handleCopy() { onCopy?() }
    @objc private func handleHighlight() { onHighlight?() }
    @objc private func handleWavy() { onWavy?() }
    @objc private func handleLine() { onLine?() }
    @objc private func handleStrikethrough() { onStrikethrough?() }
    @objc private func handleTranslate() { onTranslate?() }

    func show(above rect: CGRect, in parentBounds: CGRect) {
        let fittingWidth = ceil(stackView.fittingSize.width)
        let size = CGSize(width: max(220, fittingWidth), height: 28)
        let midX = rect.midX
        let clampedMaxX = max(6, parentBounds.width - size.width - 6)
        let x = max(6, min(clampedMaxX, midX - size.width / 2))
        var y = rect.maxY + 8
        if y + size.height > parentBounds.height - 4 {
            y = rect.minY - size.height - 8
        }
        let clampedMaxY = max(4, parentBounds.height - size.height - 4)
        y = max(4, min(clampedMaxY, y))
        frame = CGRect(x: round(x), y: round(y), width: size.width, height: size.height)
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
