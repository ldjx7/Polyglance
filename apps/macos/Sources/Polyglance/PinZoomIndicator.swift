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
