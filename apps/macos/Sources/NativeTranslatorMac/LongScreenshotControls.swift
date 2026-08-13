import AppKit

enum LongScreenshotControlAction: Equatable {
    case cancel
    case copy
    case pin
}

@MainActor
final class LongScreenshotControlView: NSView {
    private(set) var pinButton: NSButton!
    private(set) var copyButton: NSButton!
    private(set) var closeButton: NSButton!
    private(set) var actionStack: NSStackView!

    var onAction: ((LongScreenshotControlAction) -> Void)?
    private var state: LongScreenshotSessionState = .ready
    private var hasCapturedFrame = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 142, height: 50))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

        pinButton = makeIconButton(symbol: "pin", title: "贴图", action: #selector(pinOutput))
        copyButton = makeIconButton(symbol: "doc.on.doc", title: "复制", action: #selector(copyOutput))
        closeButton = makeIconButton(symbol: "xmark", title: "关闭", action: #selector(cancelCapture))

        actionStack = NSStackView(views: [
            pinButton,
            copyButton,
            closeButton,
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .fillProportionally
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actionStack)
        NSLayoutConstraint.activate([
            actionStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            actionStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            pinButton.widthAnchor.constraint(equalToConstant: 32),
            copyButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
        ])
        update(for: .ready)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(for state: LongScreenshotSessionState) {
        self.state = state
        let canUseOutput = hasCapturedFrame && (state == .capturing || state == .paused || state == .finished)
        pinButton.isEnabled = canUseOutput
        copyButton.isEnabled = canUseOutput
        closeButton.isEnabled = state == .ready
            || state == .capturing
            || state == .paused
            || state == .finished
    }

    private func makeIconButton(symbol symbolName: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: symbol(symbolName), target: self, action: action)
        button.title = ""
        button.imagePosition = .imageOnly
        button.bezelStyle = .toolbar
        button.controlSize = .small
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    func setHasCapturedFrame(_ hasCapturedFrame: Bool) {
        self.hasCapturedFrame = hasCapturedFrame
        update(for: state)
    }

    @objc private func cancelCapture() {
        onAction?(.cancel)
    }

    @objc private func copyOutput() {
        onAction?(.copy)
    }

    @objc private func pinOutput() {
        onAction?(.pin)
    }
}

@MainActor
final class LongScreenshotPreviewView: NSView {
    private let imageView = NSImageView()
    private let viewportIndicator = NSView()

    private(set) var image: NSImage?
    private(set) var viewportFraction: CGFloat = 0
    private(set) var viewportOffsetFraction: CGFloat = 0
    private var direction: LongScreenshotDirection = .vertical

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
        viewportIndicator.wantsLayer = true
        viewportIndicator.layer?.borderColor = NSColor.systemGreen.cgColor
        viewportIndicator.layer?.borderWidth = 2
        viewportIndicator.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.08).cgColor
        addSubview(viewportIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    func update(with preview: LongScreenshotPreview) {
        image = preview.image
        direction = preview.direction
        let totalLength = preview.direction == .vertical
            ? preview.totalPixelHeight
            : preview.totalPixelWidth
        let viewportLength = preview.direction == .vertical
            ? preview.viewportPixelHeight
            : preview.viewportPixelWidth
        viewportFraction = totalLength > 0
            ? min(1, CGFloat(viewportLength) / CGFloat(totalLength))
            : 0
        viewportOffsetFraction = totalLength > 0
            ? min(1, max(0, CGFloat(preview.viewportPixelOffset) / CGFloat(totalLength)))
            : 0
        imageView.image = preview.image
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func layoutPreview() {
        guard let image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        let imageAspect = image.size.width / image.size.height
        let boundsAspect = bounds.width / bounds.height
        let imageFrame: CGRect
        if boundsAspect > imageAspect {
            let width = bounds.height * imageAspect
            imageFrame = CGRect(x: bounds.midX - width / 2, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / imageAspect
            imageFrame = CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
        }
        imageView.frame = imageFrame
        if direction == .vertical {
            let indicatorHeight = max(8, imageFrame.height * viewportFraction)
            let offset = imageFrame.height * viewportOffsetFraction
            viewportIndicator.frame = CGRect(
                x: imageFrame.minX,
                y: max(imageFrame.minY, imageFrame.maxY - offset - indicatorHeight),
                width: imageFrame.width,
                height: min(imageFrame.height, indicatorHeight)
            )
        } else {
            let indicatorWidth = max(8, imageFrame.width * viewportFraction)
            viewportIndicator.frame = CGRect(
                x: imageFrame.minX + imageFrame.width * viewportOffsetFraction,
                y: imageFrame.minY,
                width: min(imageFrame.width, indicatorWidth),
                height: imageFrame.height
            )
        }
    }
}

@MainActor
final class LongScreenshotPreviewPanel: NSPanel {
    private static let crossAxisLength: CGFloat = 180
    private static let maximumLongAxis: CGFloat = 520

    let previewView = LongScreenshotPreviewView(frame: CGRect(x: 0, y: 0, width: 180, height: 90))
    private var state: LongScreenshotSessionState = .ready
    private var hasPreview = false
    private var direction: LongScreenshotDirection = .vertical

    init() {
        super.init(
            contentRect: previewView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = previewView
    }

    func update(preview: LongScreenshotPreview, near selection: CGRect) {
        hasPreview = true
        direction = preview.direction
        setContentSize(Self.contentSize(for: preview))
        previewView.update(with: preview)
        position(near: selection)
        updateVisibility()
    }

    func update(for state: LongScreenshotSessionState, near selection: CGRect) {
        self.state = state
        position(near: selection)
        updateVisibility()
    }

    private func updateVisibility() {
        if hasPreview && (state == .capturing || state == .paused) {
            orderFrontRegardless()
        } else {
            orderOut(nil)
        }
    }

    private func position(near selection: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        if direction == .horizontal {
            let x = min(
                max(selection.midX - frame.width / 2, visible.minX + 8),
                visible.maxX - frame.width - 8
            )
            let belowY = selection.minY - frame.height - 10
            let y = belowY >= visible.minY + 8
                ? belowY
                : min(selection.maxY + 10, visible.maxY - frame.height - 8)
            setFrameOrigin(CGPoint(x: x, y: y))
            return
        }
        let rightX = selection.maxX + 10
        let x = rightX + frame.width <= visible.maxX - 8
            ? rightX
            : max(visible.minX + 8, selection.minX - frame.width - 10)
        let y = min(
            max(selection.maxY - frame.height, visible.minY + 8),
            visible.maxY - frame.height - 8
        )
        setFrameOrigin(CGPoint(x: x, y: y))
    }

    private static func contentSize(for preview: LongScreenshotPreview) -> CGSize {
        guard preview.image.size.width > 0, preview.image.size.height > 0 else {
            return CGSize(width: crossAxisLength, height: crossAxisLength)
        }
        let aspect = preview.image.size.width / preview.image.size.height
        switch preview.direction {
        case .vertical:
            return CGSize(
                width: crossAxisLength,
                height: min(maximumLongAxis, max(1, crossAxisLength / aspect))
            )
        case .horizontal:
            return CGSize(
                width: min(maximumLongAxis, max(1, crossAxisLength * aspect)),
                height: crossAxisLength
            )
        }
    }
}

@MainActor
final class LongScreenshotControlPanel: NSPanel {
    let controls: LongScreenshotControlView

    convenience init() {
        self.init(controls: LongScreenshotControlView())
    }

    init(controls: LongScreenshotControlView) {
        self.controls = controls
        super.init(
            contentRect: controls.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = controls
    }

    func present(near selection: CGRect) {
        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(selection) }) ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else {
            center()
            orderFrontRegardless()
            return
        }
        let proposedX = selection.midX - frame.width / 2
        let belowY = selection.minY - frame.height - 10
        let aboveY = selection.maxY + 10
        let proposedY = belowY >= visibleFrame.minY + 8
            ? belowY
            : min(aboveY, visibleFrame.maxY - frame.height - 8)
        let origin = CGPoint(
            x: min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - frame.width - 8),
            y: proposedY
        )
        setFrameOrigin(origin)
        orderFrontRegardless()
    }
}

@MainActor
final class LongScreenshotRegionOverlayView: NSView {
    private enum DragTarget {
        case move
        case left
        case right
        case top
        case bottom
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private var state: LongScreenshotSessionState = .ready
    private var dragTarget: DragTarget?
    private var dragStartScreenPoint: CGPoint?
    private var dragStartFrame: CGRect?

    var onRegionChanged: ((CGRect) -> Void)?
    var isRegionVisible: Bool { !isHidden && state != .cancelled && state != .failed }
    var allowsRegionEditing: Bool { state == .ready }
    var borderColor: NSColor {
        switch state {
        case .ready:
            return .systemBlue
        case .capturing:
            return .systemRed
        case .paused:
            return .systemOrange
        case .finished:
            return .systemGreen
        case .cancelled, .failed:
            return .clear
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsRegionEditing else { return nil }
        return dragTarget(at: point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isRegionVisible, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(3)
        context.stroke(bounds.insetBy(dx: 1.5, dy: 1.5))
        context.setFillColor(borderColor.cgColor)
        for point in resizeHandleCenters {
            context.fillEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
        let moveRect = moveHandleRect
        let path = CGPath(roundedRect: moveRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    func update(for state: LongScreenshotSessionState) {
        self.state = state
        dragTarget = nil
        dragStartScreenPoint = nil
        dragStartFrame = nil
        isHidden = state == .cancelled || state == .failed
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsRegionEditing, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragTarget = dragTarget(at: point)
        dragStartScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        dragStartFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let dragTarget,
              let dragStartScreenPoint,
              let dragStartFrame else { return }
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGPoint(
            x: current.x - dragStartScreenPoint.x,
            y: current.y - dragStartScreenPoint.y
        )
        var frame = adjustedFrame(dragStartFrame, target: dragTarget, delta: delta)
        if let visibleFrame = window.screen?.frame {
            frame = constrained(frame, to: visibleFrame)
        }
        window.setFrame(frame, display: true)
        onRegionChanged?(frame)
    }

    override func mouseUp(with event: NSEvent) {
        dragTarget = nil
        dragStartScreenPoint = nil
        dragStartFrame = nil
    }

    private var moveHandleRect: CGRect {
        CGRect(x: bounds.midX - 22, y: bounds.maxY - 14, width: 44, height: 10)
    }

    private var resizeHandleCenters: [CGPoint] {
        [
            CGPoint(x: bounds.minX + 2, y: bounds.minY + 2),
            CGPoint(x: bounds.midX, y: bounds.minY + 2),
            CGPoint(x: bounds.maxX - 2, y: bounds.minY + 2),
            CGPoint(x: bounds.minX + 2, y: bounds.midY),
            CGPoint(x: bounds.maxX - 2, y: bounds.midY),
            CGPoint(x: bounds.minX + 2, y: bounds.maxY - 2),
            CGPoint(x: bounds.midX, y: bounds.maxY - 2),
            CGPoint(x: bounds.maxX - 2, y: bounds.maxY - 2),
        ]
    }

    private func dragTarget(at point: CGPoint) -> DragTarget? {
        if moveHandleRect.insetBy(dx: -5, dy: -5).contains(point) {
            return .move
        }
        let tolerance: CGFloat = 9
        let left = abs(point.x - bounds.minX) <= tolerance
        let right = abs(point.x - bounds.maxX) <= tolerance
        let bottom = abs(point.y - bounds.minY) <= tolerance
        let top = abs(point.y - bounds.maxY) <= tolerance
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nil
    }

    private func adjustedFrame(
        _ original: CGRect,
        target: DragTarget,
        delta: CGPoint
    ) -> CGRect {
        if target == .move {
            return original.offsetBy(dx: delta.x, dy: delta.y)
        }
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch target {
        case .left, .topLeft, .bottomLeft:
            minX = min(original.maxX - 80, original.minX + delta.x)
        default:
            break
        }
        switch target {
        case .right, .topRight, .bottomRight:
            maxX = max(original.minX + 80, original.maxX + delta.x)
        default:
            break
        }
        switch target {
        case .bottom, .bottomLeft, .bottomRight:
            minY = min(original.maxY - 60, original.minY + delta.y)
        default:
            break
        }
        switch target {
        case .top, .topLeft, .topRight:
            maxY = max(original.minY + 60, original.maxY + delta.y)
        default:
            break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func constrained(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, bounds.width),
            height: min(frame.height, bounds.height)
        )
        return CGRect(
            x: min(max(frame.minX, bounds.minX), bounds.maxX - size.width),
            y: min(max(frame.minY, bounds.minY), bounds.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}

@MainActor
final class LongScreenshotRegionOverlayPanel: NSPanel {
    let overlayView: LongScreenshotRegionOverlayView

    init(region: CGRect) {
        overlayView = LongScreenshotRegionOverlayView(
            frame: CGRect(origin: .zero, size: region.size)
        )
        super.init(
            contentRect: region,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = overlayView
        update(for: .ready)
    }

    func present() {
        orderFrontRegardless()
    }

    func update(for state: LongScreenshotSessionState) {
        overlayView.update(for: state)
        ignoresMouseEvents = state != .ready
    }
}
