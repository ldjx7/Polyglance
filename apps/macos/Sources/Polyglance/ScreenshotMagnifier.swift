import AppKit

final class ScreenshotMagnifierView: NSView {
    /// Tall enough to give the coordinate, the colour and the hint a line each.
    /// A single line had to hold both the coordinate and an `RGB(255, 255, 255)`
    /// value, which overflowed the panel and was clipped mid-value.
    static let preferredSize = CGSize(width: 196, height: 176)
    static let shortcutHint = "C 复制色值 · ⇧C 切换 HEX/RGB"

    private static let swatchSide: CGFloat = 13
    private static let swatchTextSpacing: CGFloat = 6
    private static let colorFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let coordinateFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private static let hintFont = NSFont.systemFont(ofSize: 9, weight: .medium)

    private let previewRect = CGRect(x: 8, y: 68, width: 180, height: 100)
    private let colorRowRect = CGRect(x: 8, y: 45, width: 180, height: 16)
    private let coordinateRect = CGRect(x: 8, y: 26, width: 180, height: 15)
    private let hintRect = CGRect(x: 6, y: 8, width: 184, height: 13)

    private var patchImage: CGImage?
    private var feedbackWorkItem: DispatchWorkItem?
    private var sampleColor: NSColor?
    private(set) var colorText = ""
    private(set) var coordinateText = ""
    private(set) var instructionText = shortcutHint

    /// The whole readout on one string, newline separated. Also what the
    /// accessibility value reports.
    var displayText: String {
        guard !coordinateText.isEmpty || !colorText.isEmpty else { return "" }
        return "\(coordinateText)\n\(colorText)"
    }

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("像素放大镜")
    }

    deinit {
        feedbackWorkItem?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        sampler: PixelSampler,
        sample: PixelSample,
        format: ScreenshotColorDisplayFormat
    ) {
        patchImage = sampler.patch(around: sample.coordinate, radius: 5)
        coordinateText = "(\(sample.coordinate.x), \(sample.coordinate.y)) px"
        colorText = sample.text(format: format)
        sampleColor = NSColor(
            srgbRed: CGFloat(sample.red) / 255,
            green: CGFloat(sample.green) / 255,
            blue: CGFloat(sample.blue) / 255,
            alpha: 1
        )
        refreshAccessibilityValue()
        needsDisplay = true
    }

    func showCopyConfirmation(_ copiedValue: String, duration: TimeInterval = 1.2) {
        feedbackWorkItem?.cancel()
        instructionText = "已复制 \(copiedValue)"
        refreshAccessibilityValue()
        needsDisplay = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            instructionText = Self.shortcutHint
            refreshAccessibilityValue()
            needsDisplay = true
        }
        feedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration), execute: workItem)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        NSColor.white.withAlphaComponent(0.42).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        border.lineWidth = 1
        border.stroke()

        if let patchImage {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = .none
            let image = NSImage(cgImage: patchImage, size: previewRect.size)
            image.draw(in: previewRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        drawGridAndCrosshair()
        drawColorRow()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        coordinateText.draw(
            in: coordinateRect,
            withAttributes: [
                .font: Self.coordinateFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .paragraphStyle: paragraph,
            ]
        )
        instructionText.draw(
            in: hintRect,
            withAttributes: [
                .font: Self.hintFont,
                .foregroundColor: instructionText == Self.shortcutHint
                    ? NSColor.white.withAlphaComponent(0.55)
                    : NSColor.systemGreen,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// The swatch and the colour value are centred as one unit, so the value
    /// keeps its own line and can use the full panel width.
    private func drawColorRow() {
        guard !colorText.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.colorFont,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (colorText as NSString).size(withAttributes: attributes)
        let available = colorRowRect.width - Self.swatchSide - Self.swatchTextSpacing
        let textWidth = min(textSize.width, available)
        let groupWidth = Self.swatchSide + Self.swatchTextSpacing + textWidth
        let originX = colorRowRect.minX + max(0, (colorRowRect.width - groupWidth) / 2)

        let swatch = CGRect(
            x: originX,
            y: colorRowRect.midY - Self.swatchSide / 2,
            width: Self.swatchSide,
            height: Self.swatchSide
        )
        let swatchPath = NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3)
        (sampleColor ?? NSColor.black).setFill()
        swatchPath.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        swatchPath.lineWidth = 1
        swatchPath.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        var textAttributes = attributes
        textAttributes[.paragraphStyle] = paragraph
        colorText.draw(
            in: CGRect(
                x: swatch.maxX + Self.swatchTextSpacing,
                y: colorRowRect.midY - textSize.height / 2,
                width: textWidth,
                height: textSize.height
            ),
            withAttributes: textAttributes
        )
    }

    static func positionedFrame(
        near point: CGPoint,
        size: CGSize = preferredSize,
        in bounds: CGRect,
        spacing: CGFloat = 14,
        edgeInset: CGFloat = 8
    ) -> CGRect {
        let bounds = bounds.standardized
        let maximumWidth = max(1, bounds.width - edgeInset * 2)
        let maximumHeight = max(1, bounds.height - edgeInset * 2)
        let fittedSize = CGSize(
            width: min(size.width, maximumWidth),
            height: min(size.height, maximumHeight)
        )

        var x = point.x + spacing
        if x + fittedSize.width > bounds.maxX - edgeInset {
            x = point.x - spacing - fittedSize.width
        }
        var y = point.y + spacing
        if y + fittedSize.height > bounds.maxY - edgeInset {
            y = point.y - spacing - fittedSize.height
        }
        x = min(max(x, bounds.minX + edgeInset), bounds.maxX - edgeInset - fittedSize.width)
        y = min(max(y, bounds.minY + edgeInset), bounds.maxY - edgeInset - fittedSize.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: fittedSize)
    }

    private func drawGridAndCrosshair() {
        let columns: CGFloat = 11
        let rows: CGFloat = 11
        let cellWidth = previewRect.width / columns
        let cellHeight = previewRect.height / rows

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for index in 1..<Int(columns) {
            let x = previewRect.minX + CGFloat(index) * cellWidth
            grid.move(to: CGPoint(x: x, y: previewRect.minY))
            grid.line(to: CGPoint(x: x, y: previewRect.maxY))
        }
        for index in 1..<Int(rows) {
            let y = previewRect.minY + CGFloat(index) * cellHeight
            grid.move(to: CGPoint(x: previewRect.minX, y: y))
            grid.line(to: CGPoint(x: previewRect.maxX, y: y))
        }
        grid.stroke()

        NSColor.systemYellow.setStroke()
        let crosshair = NSBezierPath()
        crosshair.lineWidth = 1.5
        crosshair.move(to: CGPoint(x: previewRect.midX, y: previewRect.minY))
        crosshair.line(to: CGPoint(x: previewRect.midX, y: previewRect.maxY))
        crosshair.move(to: CGPoint(x: previewRect.minX, y: previewRect.midY))
        crosshair.line(to: CGPoint(x: previewRect.maxX, y: previewRect.midY))
        crosshair.stroke()

        NSColor.systemYellow.setStroke()
        let centerPixel = CGRect(
            x: previewRect.midX - cellWidth / 2,
            y: previewRect.midY - cellHeight / 2,
            width: cellWidth,
            height: cellHeight
        )
        let outline = NSBezierPath(rect: centerPixel)
        outline.lineWidth = 2
        outline.stroke()
    }

    private func refreshAccessibilityValue() {
        setAccessibilityValue("\(coordinateText), \(colorText), \(instructionText)")
    }
}
