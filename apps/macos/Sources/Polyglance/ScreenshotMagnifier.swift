import AppKit

final class ScreenshotMagnifierView: NSView {
    static let preferredSize = CGSize(width: 184, height: 142)
    static let shortcutHint = "C 复制色值 · ⇧C 切换 HEX/RGB"

    private let previewRect = CGRect(x: 8, y: 42, width: 168, height: 92)
    private var patchImage: CGImage?
    private var feedbackWorkItem: DispatchWorkItem?
    private(set) var displayText = ""
    private(set) var instructionText = shortcutHint

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
        displayText = "(\(sample.coordinate.x), \(sample.coordinate.y)) px  \(sample.text(format: format))"
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        displayText.draw(
            in: CGRect(x: 6, y: 24, width: bounds.width - 12, height: 16),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        instructionText.draw(
            in: CGRect(x: 6, y: 7, width: bounds.width - 12, height: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: instructionText == Self.shortcutHint
                    ? NSColor.secondaryLabelColor
                    : NSColor.systemGreen,
                .paragraphStyle: paragraph,
            ]
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
        setAccessibilityValue("\(displayText), \(instructionText)")
    }
}
