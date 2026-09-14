import AppKit
import PolyglanceKit
import QuartzCore

@MainActor
final class ScreenSelectionBackdropView: NSView {
    struct Segment {
        let image: CGImage
        let rect: CGRect
    }

    private static let dimAlpha: Float = 0.46
    private let dimLayer = CALayer()
    private let holeMask = CAShapeLayer()

    init(frame: CGRect, segments: [Segment], backingScaleFactor: CGFloat) {
        super.init(frame: frame)
        let root = CALayer()
        root.actions = Self.noActions
        layer = root
        wantsLayer = true
        for segment in segments {
            let desktop = CALayer()
            desktop.actions = Self.noActions
            desktop.frame = segment.rect
            desktop.contents = segment.image
            desktop.contentsGravity = .resize
            desktop.contentsScale = backingScaleFactor
            desktop.isOpaque = true
            root.addSublayer(desktop)
        }
        dimLayer.actions = Self.noActions
        dimLayer.frame = bounds
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = Self.dimAlpha
        holeMask.actions = Self.noActions
        holeMask.frame = bounds
        holeMask.fillRule = .evenOdd
        holeMask.fillColor = NSColor.black.cgColor
        dimLayer.mask = holeMask
        root.addSublayer(dimLayer)
        update(selection: nil, dims: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(selection: CGRect?, dims: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.isHidden = !dims
        if dims {
            holeMask.frame = bounds
            let path = CGMutablePath()
            path.addRect(bounds)
            if let selection, CaptureGeometry.isUsable(selection), selection.intersects(bounds) {
                path.addRect(selection)
            }
            holeMask.path = path
        }
        CATransaction.commit()
    }

    private static let noActions: [String: CAAction] = [
        "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "opacity": NSNull(), "path": NSNull(), "sublayers": NSNull(),
    ]
}

@MainActor
final class ScreenSelectionOverlayCanvasView: NSView {
    var drawHandler: ((NSRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawHandler?(dirtyRect)
    }
}
