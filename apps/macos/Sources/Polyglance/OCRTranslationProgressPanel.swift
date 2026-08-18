import AppKit

@MainActor
final class OCRTranslationProgressPanel: NSPanel {
    let message: String

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(
        message: String,
        sourceFrame: CGRect,
        visibleFrame: CGRect
    ) {
        self.message = message
        let size = CGSize(width: 224, height: 58)
        let origin = Self.origin(
            panelSize: size,
            sourceFrame: sourceFrame,
            visibleFrame: visibleFrame
        )
        super.init(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.setAccessibilityLabel(message)

        let stack = NSStackView(views: [progress, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
        ])
        contentView = background
    }

    private static func origin(
        panelSize: CGSize,
        sourceFrame: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let margin: CGFloat = 12
        let preferredY = sourceFrame.minY - panelSize.height - margin
        let fallbackY = sourceFrame.maxY + margin
        let y = preferredY >= visibleFrame.minY
            ? preferredY
            : min(fallbackY, visibleFrame.maxY - panelSize.height)
        let centeredX = sourceFrame.midX - panelSize.width / 2
        return CGPoint(
            x: min(
                max(centeredX, visibleFrame.minX),
                visibleFrame.maxX - panelSize.width
            ),
            y: min(
                max(y, visibleFrame.minY),
                visibleFrame.maxY - panelSize.height
            )
        )
    }
}
