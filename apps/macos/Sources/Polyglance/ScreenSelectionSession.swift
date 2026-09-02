import AppKit
import PolyglanceKit

struct SelectedScreenshot {
    let image: NSImage
    let screenFrame: CGRect
}

enum ScreenshotSelectionAction {
    case copy(SelectedScreenshot)
    case save(SelectedScreenshot)
    case pin(SelectedScreenshot)
    case ocrCopy(SelectedScreenshot)
    case ocrCopyAll(SelectedScreenshot)
    case ocrTranslate(SelectedScreenshot)
    case detectBarcode(SelectedScreenshot)
    case longScreenshot(SelectedScreenshot)
    case screenRecording(SelectedScreenshot)
    case screenTranslation(ScreenTranslationSelection)
}

enum ScreenshotCursorMode: Equatable {
    case crosshair
    case arrow
}

enum ScreenshotCapturePhase: Equatable {
    case ready
    case pressed(start: CGPoint, candidate: CGRect?)
    case dragging(start: CGPoint, current: CGPoint)
    case selected(CGRect)
    case annotating(CGRect)
}

typealias ScreenshotRegionProvider = (CGPoint) -> CGRect?
typealias ScreenshotRegionRefiner = @Sendable (CGPoint) async -> CGRect?

@MainActor
final class ScreenshotToolbarButton: NSButton {
    var onHoverChanged: ((ScreenshotToolbarButton, Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 5
        updateAppearance()
    }

    override var isEnabled: Bool {
        didSet {
            updateAppearance()
        }
    }

    var isActive: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    func updateAppearance() {
        if !isEnabled {
            contentTintColor = NSColor.black.withAlphaComponent(0.2)
            layer?.backgroundColor = NSColor.clear.cgColor
        } else if isActive {
            contentTintColor = NSColor.systemBlue
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        } else if isHovered {
            contentTintColor = NSColor(white: 0.08, alpha: 1.0)
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        } else {
            contentTintColor = NSColor(white: 0.18, alpha: 1.0)
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        updateAppearance()
        onHoverChanged?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        updateAppearance()
        onHoverChanged?(self, false)
    }
}

@MainActor
final class ScreenshotToolbarContainerView: NSVisualEffectView {
    private let backgroundCard = NSView()

    var cornerRadius: CGFloat = 22 {
        didSet {
            updateShape()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        material = .popover
        state = .active
        appearance = NSAppearance(named: .aqua)

        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.16).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowRadius = 8

        backgroundCard.wantsLayer = true
        backgroundCard.layer?.backgroundColor = NSColor.white.cgColor
        backgroundCard.layer?.borderWidth = 0.5
        backgroundCard.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        backgroundCard.layer?.masksToBounds = true
        backgroundCard.autoresizingMask = [.width, .height]
        backgroundCard.frame = bounds
        addSubview(backgroundCard, positioned: .below, relativeTo: nil)

        updateShape()
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    private func updateShape() {
        backgroundCard.frame = bounds
        backgroundCard.layer?.cornerRadius = cornerRadius
        layer?.cornerRadius = cornerRadius
        maskImage = Self.makeMaskImage(cornerRadius: cornerRadius)

        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        layer?.shadowPath = path
    }

    private static func makeMaskImage(cornerRadius: CGFloat) -> NSImage {
        let size = CGSize(width: cornerRadius * 2 + 2, height: cornerRadius * 2 + 2)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: cornerRadius,
                yRadius: cornerRadius
            )
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: cornerRadius,
            left: cornerRadius,
            bottom: cornerRadius,
            right: cornerRadius
        )
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
final class ScreenshotToolbarHelpBubble: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

fileprivate struct ScreenSelectionMirrorState {
    let selection: CGRect?
    let dimsDesktop: Bool
    let showsHandles: Bool
    let annotations: [ScreenshotAnnotationElement]
}

@MainActor
private final class CrossScreenSelectionMirrorView: NSView {
    private let capturedImage: CGImage
    private let displayImage: NSImage
    private let captureFrame: CGRect
    private let displayFrame: CGRect
    private var state = ScreenSelectionMirrorState(
        selection: nil,
        dimsDesktop: false,
        showsHandles: false,
        annotations: []
    )

    var displayedSelectionForTesting: CGRect? {
        localSelection(state.selection)
    }

    init(image: CGImage, captureFrame: CGRect, displayFrame: CGRect) {
        capturedImage = image
        displayImage = NSImage(cgImage: image, size: captureFrame.size)
        self.captureFrame = captureFrame
        self.displayFrame = displayFrame
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ state: ScreenSelectionMirrorState) {
        self.state = state
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCapturedDesktop()

        guard state.dimsDesktop,
              let selection = localSelection(state.selection),
              selection.intersects(bounds) else {
            return
        }

        NSColor.black.withAlphaComponent(0.46).setFill()
        bounds.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        drawCapturedDesktop()
        drawAnnotations()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        if state.showsHandles {
            drawHandles(for: selection)
        }
    }

    private func drawCapturedDesktop() {
        displayImage.draw(in: captureFrame.offsetBy(
            dx: -displayFrame.minX,
            dy: -displayFrame.minY
        ))
    }

    private func localSelection(_ selection: CGRect?) -> CGRect? {
        selection?.offsetBy(
            dx: captureFrame.minX - displayFrame.minX,
            dy: captureFrame.minY - displayFrame.minY
        )
    }

    private func drawAnnotations() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let offset = CGPoint(
            x: captureFrame.minX - displayFrame.minX,
            y: captureFrame.minY - displayFrame.minY
        )
        ScreenshotAnnotationRenderer.draw(
            elements: state.annotations,
            in: context,
            sourceImage: capturedImage,
            pointTransform: { point in
                CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            },
            sourcePixelTransform: { [captureFrame, capturedImage] point in
                guard captureFrame.width > 0, captureFrame.height > 0 else { return .zero }
                return CGPoint(
                    x: point.x * CGFloat(capturedImage.width) / captureFrame.width,
                    y: point.y * CGFloat(capturedImage.height) / captureFrame.height
                )
            }
        )
    }

    private func drawHandles(for selection: CGRect) {
        let points = [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY),
        ]
        for point in points {
            let handle = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: handle).stroke()
        }
    }
}

@MainActor
private final class CrossScreenSelectionMirrorWindow: NSPanel {
    let mirrorView: CrossScreenSelectionMirrorView

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(image: CGImage, captureFrame: CGRect, displayFrame: CGRect) {
        mirrorView = CrossScreenSelectionMirrorView(
            image: image,
            captureFrame: captureFrame,
            displayFrame: displayFrame
        )
        super.init(
            contentRect: displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = mirrorView
        setFrame(displayFrame, display: false)
    }
}

@MainActor
final class ScreenSelectionSession {
    private let window: ScreenSelectionWindow
    private let inactiveDimmingWindows: [InactiveScreenDimmingWindow]
    private let crossScreenWindows: [CrossScreenSelectionMirrorWindow]
    private var completion: ((ScreenshotSelectionAction?) -> Void)?
    private var didFinish = false
    private var screenChangeObserver: NSObjectProtocol?

    var inactiveDimmingWindowFrames: [CGRect] {
        inactiveDimmingWindows.map(\.frame)
    }

    var areInactiveScreensDimmed: Bool {
        !inactiveDimmingWindows.isEmpty && inactiveDimmingWindows.allSatisfy(\.isVisible)
    }

    var isSelectionWindowVisible: Bool {
        window.isVisible
    }

    var crossScreenOverlayFrames: [CGRect] { crossScreenWindows.map(\.frame) }
    var areCrossScreenOverlaysVisible: Bool {
        !crossScreenWindows.isEmpty && crossScreenWindows.allSatisfy(\.isVisible)
    }
    var crossScreenSelectionsForTesting: [CGRect?] {
        crossScreenWindows.map { $0.mirrorView.displayedSelectionForTesting }
    }

    var selectionWindowForTesting: ScreenSelectionWindow { window }

    init(
        image: CGImage,
        screen: NSScreen,
        captureFrame: CGRect? = nil,
        inactiveScreenFrames: [CGRect]? = nil,
        crossScreenFrames: [CGRect]? = nil,
        regionProvider: ScreenshotRegionProvider? = nil,
        regionRefiner: ScreenshotRegionRefiner? = nil,
        preferredAction: ScreenshotPreferredAction? = nil
    ) {
        window = ScreenSelectionWindow(
            image: image,
            screen: screen,
            captureFrame: captureFrame,
            regionProvider: regionProvider,
            regionRefiner: regionRefiner,
            preferredAction: preferredAction
        )
        let activeFrame = (captureFrame ?? screen.frame).standardized
        let candidateFrames = inactiveScreenFrames ?? NSScreen.screens.map(\.frame)
        var uniqueFrames: [CGRect] = []
        for frame in candidateFrames.map(\.standardized) {
            guard !frame.intersects(activeFrame),
                  !uniqueFrames.contains(where: { $0.intersects(frame) }) else {
                continue
            }
            uniqueFrames.append(frame)
        }
        inactiveDimmingWindows = uniqueFrames.map(InactiveScreenDimmingWindow.init(frame:))
        let selectionView = window.selectionView
        let participatingFrames = (crossScreenFrames ?? NSScreen.screens.map(\.frame))
            .map(\.standardized)
            .filter { frame in
                frame.intersects(activeFrame) && !frame.equalTo(screen.frame.standardized)
            }
        crossScreenWindows = participatingFrames.map { frame in
            CrossScreenSelectionMirrorWindow(
                image: image,
                captureFrame: activeFrame,
                displayFrame: frame
            )
        }
        selectionView.onMirrorStateChange = { [weak self] state in
            self?.crossScreenWindows.forEach { $0.mirrorView.update(state) }
        }
        selectionView.publishMirrorState()
        inactiveDimmingWindows.forEach { dimmingWindow in
            dimmingWindow.onRightClick = { [weak selectionView] in
                selectionView?.handleRightClickOutsideTargetScreen()
            }
        }
    }

    func present(completion: @escaping (ScreenshotSelectionAction?) -> Void) {
        guard !didFinish, self.completion == nil else {
            return
        }
        self.completion = completion
        window.onAction = { [weak self] action in
            self?.finish(with: action)
        }
        window.onCancel = { [weak self] in
            self?.finish(with: nil)
        }
        inactiveDimmingWindows.forEach { $0.orderFrontRegardless() }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(window.selectionView)
        crossScreenWindows.forEach { $0.orderFrontRegardless() }
        window.selectionView.prepareForCaptureInput()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    func cancel() {
        finish(with: nil)
    }

    func dismiss() {
        inactiveDimmingWindows.forEach { $0.orderOut(nil) }
        crossScreenWindows.forEach { $0.orderOut(nil) }
        window.orderOut(nil)
        NSCursor.arrow.set()
    }

    private func finish(with action: ScreenshotSelectionAction?) {
        guard !didFinish else {
            return
        }
        didFinish = true
        window.selectionView.cancelPendingWork()
        window.onAction = nil
        window.onCancel = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        inactiveDimmingWindows.forEach { $0.orderOut(nil) }
        crossScreenWindows.forEach { $0.orderOut(nil) }
        if case .pin = action {
            // Keep the captured pixels on screen until the pin window has been
            // created at the same frame. This avoids exposing one desktop frame
            // between the selection overlay and its pinned replacement.
        } else if case .detectBarcode = action {
            // The barcode result card is created at the code's on-screen frame,
            // so the overlay stays up for the same handoff as a pin.
        } else {
            dismiss()
        }
        let completion = completion
        self.completion = nil
        completion?(action)
    }
}

@MainActor
final class InactiveScreenDimmingWindow: NSPanel {
    var onRightClick: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.58)
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        let dimmingView = InactiveScreenDimmingView(frame: CGRect(origin: .zero, size: frame.size))
        dimmingView.onRightClick = { [weak self] in
            self?.onRightClick?()
        }
        contentView = dimmingView
    }
}

@MainActor
private final class InactiveScreenDimmingView: NSView {
    var onRightClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

@MainActor
final class ScreenSelectionWindow: NSWindow {
    let selectionView: ScreenSelectionView
    var onAction: ((ScreenshotSelectionAction) -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    /// Screenshot selection is intentionally allowed to span the complete
    /// virtual desktop. AppKit may otherwise constrain a borderless window back
    /// to the screen passed to the placement routine on some Spaces/display
    /// configurations.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(
        image: CGImage,
        screen: NSScreen,
        captureFrame: CGRect? = nil,
        regionProvider: ScreenshotRegionProvider? = nil,
        regionRefiner: ScreenshotRegionRefiner? = nil,
        colorPasteboard: NSPasteboard = .general,
        preferredAction: ScreenshotPreferredAction? = nil
    ) {
        let activeFrame = captureFrame ?? screen.frame
        selectionView = ScreenSelectionView(
            image: image,
            screen: screen,
            captureFrame: activeFrame,
            regionProvider: regionProvider,
            regionRefiner: regionRefiner,
            colorPasteboard: colorPasteboard,
            preferredAction: preferredAction
        )
        super.init(
            contentRect: activeFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        acceptsMouseMovedEvents = true
        contentView = selectionView
        isMovable = false
        isMovableByWindowBackground = false
        setFrame(activeFrame, display: false)

        selectionView.onAction = { [weak self] action in
            self?.onAction?(action)
        }
        selectionView.onCancel = { [weak self] in
            self?.onCancel?()
        }
    }
}

@MainActor
final class ScreenSelectionView: NSView, NSTextFieldDelegate {
    private enum SelectionEditMode {
        case relativeDrag
        case outwardExpansion
        case pendingHandleExpansion(clickTarget: CaptureSelectionEditTarget)
    }

    private struct ActiveSelectionEdit {
        let originalSelection: CGRect
        let dragStart: CGPoint
        let target: CaptureSelectionEditTarget
        let originalAnnotationHistory: ScreenshotAnnotationHistory
        let preservesAnnotationMode: Bool
        var mode: SelectionEditMode
    }

    var onAction: ((ScreenshotSelectionAction) -> Void)?
    var onCancel: (() -> Void)?
    fileprivate var onMirrorStateChange: ((ScreenSelectionMirrorState) -> Void)?

    private let capturedImage: CGImage
    private let displayImage: NSImage
    private let captureFrame: CGRect
    private let toolbarPlacementFrame: CGRect
    private let regionProvider: ScreenshotRegionProvider?
    private let regionRefiner: ScreenshotRegionRefiner?
    private let pixelSampler: PixelSampler?
    private let colorPasteboard: NSPasteboard
    private let preferredAction: ScreenshotPreferredAction?
    private var annotationHistory = ScreenshotAnnotationHistory()
    private var activeAnnotationElement: ScreenshotAnnotationElement?
    private(set) var selectedAnnotationTool: ScreenshotAnnotationTool = .freehand
    private var annotationStyle = ScreenshotAnnotationStyle.default
    private var toolbar: ScreenshotToolbarContainerView!
    private var toolbarStack: NSStackView!
    private var toolbarToolRow: NSStackView!
    private var toolbarActionRow: NSStackView!
    private var toolbarUsesTwoRows: Bool?
    private var toolbarButtons: [NSButton] = []
    private var toolbarToolButtons: [NSButton] = []
    private var toolbarActionButtons: [NSButton] = []
    private var toolbarHelpBubble: ScreenshotToolbarHelpBubble!
    private var toolbarHelpLabel: NSTextField!
    private weak var hoveredToolbarButton: NSButton?
    private var annotationToolButtons: [ScreenshotAnnotationTool: NSButton] = [:]
    private var subToolbar: ScreenshotSubToolbarView!
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private var magnifierView: ScreenshotMagnifierView!
    private var pointerTrackingArea: NSTrackingArea?
    private var hoverRefinementTask: Task<Void, Never>?
    private var hoverRequestID = 0
    private var lastHoverPoint: CGPoint?
    private var activeSelectionEdit: ActiveSelectionEdit?
    private var didLastClickExpandSelection = false
    private var activeTextOrigin: CGPoint?
    private var movingText: (index: Int, grabOffset: CGPoint)?
    private var globalDragTimer: Timer?

    private(set) var activeTextField: NSTextField?
    private(set) var currentPixelSample: PixelSample?
    private(set) var colorDisplayFormat: ScreenshotColorDisplayFormat = .hex

    private(set) var capturePhase: ScreenshotCapturePhase = .ready {
        didSet {
            publishMirrorState()
        }
    }
    private(set) var hoveredCandidate: CGRect?

    var visibleToolbarHelpText: String? {
        guard toolbarHelpBubble?.isHidden == false else {
            return nil
        }
        return toolbarHelpLabel.stringValue
    }

    private let dragThreshold: CGFloat = 4

    private var usesTwoRowToolbar: Bool {
        toolbarPlacementBounds.width < 700
    }

    private var toolbarPlacementBounds: CGRect {
        let placementBounds = toolbarPlacementFrame.intersection(bounds)
        return placementBounds.isNull || placementBounds.isEmpty ? bounds : placementBounds
    }

    private var toolbarSize: CGSize {
        CaptureGeometry.fittedToolbarSize(
            preferred: CGSize(
                width: 672,
                height: usesTwoRowToolbar ? 78 : 44
            ),
            bounds: toolbarPlacementBounds
        )
    }

    var toolbarFrameForTesting: CGRect { toolbar.frame }

    override var acceptsFirstResponder: Bool { true }

    var cursorMode: ScreenshotCursorMode {
        switch capturePhase {
        case .selected:
            return .arrow
        case .ready, .pressed, .dragging, .annotating:
            return .crosshair
        }
    }

    var confirmedSelection: CGRect? {
        switch capturePhase {
        case let .selected(selection), let .annotating(selection):
            return selection
        case .ready, .pressed, .dragging:
            return nil
        }
    }

    var dimsCurrentScreen: Bool {
        switch capturePhase {
        case .dragging, .selected, .annotating:
            return true
        case .ready, .pressed:
            return false
        }
    }

    private var isAnnotating: Bool {
        if case .annotating = capturePhase {
            return true
        }
        return false
    }

    var annotationElements: [ScreenshotAnnotationElement] {
        annotationHistory.elements
    }

    var selectionBorderColor: NSColor { .controlAccentColor }

    var showsSelectionHandles: Bool { confirmedSelection != nil }

    fileprivate func publishMirrorState() {
        onMirrorStateChange?(ScreenSelectionMirrorState(
            selection: displayedSelection,
            dimsDesktop: dimsCurrentScreen,
            showsHandles: showsSelectionHandles,
            annotations: annotationHistory.elements
                + (activeAnnotationElement.map { [$0] } ?? [])
        ))
    }

    init(
        image: CGImage,
        screen: NSScreen,
        captureFrame: CGRect? = nil,
        regionProvider: ScreenshotRegionProvider? = nil,
        regionRefiner: ScreenshotRegionRefiner? = nil,
        colorPasteboard: NSPasteboard = .general,
        preferredAction: ScreenshotPreferredAction? = nil
    ) {
        capturedImage = image
        let activeFrame = captureFrame ?? screen.frame
        displayImage = NSImage(cgImage: image, size: activeFrame.size)
        self.captureFrame = activeFrame
        let localScreenFrame = screen.frame.offsetBy(
            dx: -activeFrame.minX,
            dy: -activeFrame.minY
        )
        toolbarPlacementFrame = localScreenFrame
        self.regionProvider = regionProvider
        self.regionRefiner = regionRefiner
        pixelSampler = PixelSampler(image: image)
        self.colorPasteboard = colorPasteboard
        self.preferredAction = preferredAction
        super.init(frame: CGRect(origin: .zero, size: activeFrame.size))
        configureMagnifier()
        configureToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorMode == .crosshair ? .crosshair : .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func layout() {
        super.layout()
        guard toolbar != nil else {
            return
        }
        toolbar.frame.size = toolbarSize
        updateToolbarLayout()
        updateToolbarButtonPresentation()
        if let selection = confirmedSelection, !toolbar.isHidden {
            toolbar.frame.origin = CaptureGeometry.toolbarOrigin(
                selection: selection,
                toolbarSize: toolbarSize,
                bounds: toolbarPlacementBounds
            )
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Annotation edits do not always transition capturePhase, so keep the
        // passive overlays on the other displays in sync with every redraw.
        publishMirrorState()
        displayImage.draw(in: bounds)

        if dimsCurrentScreen {
            NSColor.black.withAlphaComponent(0.46).setFill()
            bounds.fill()
        }

        if let selection = displayedSelection, CaptureGeometry.isUsable(selection) {
            if dimsCurrentScreen {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: selection).addClip()
                displayImage.draw(in: bounds)
                drawAnnotations()
                NSGraphicsContext.restoreGraphicsState()
            }

            selectionBorderColor.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 1.0, dy: 1.0))
            border.lineWidth = 2.0
            border.stroke()

            if showsSelectionHandles {
                drawSelectionHandles(for: selection)
            }

            drawSizeLabel(for: selection)
        }

        if confirmedSelection == nil {
            drawInstructions()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: point)
        switch capturePhase {
        case .ready:
            updateHoveredCandidate(at: point)
        case let .selected(selection):
            setSelectionCursor(
                for: CaptureGeometry.selectionEditTarget(at: point, selection: selection),
                isDragging: false
            )
        case let .annotating(selection):
            setAnnotationCursor(at: point, selection: selection)
        case .pressed, .dragging:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: point)
        guard (toolbar.isHidden || !toolbar.frame.contains(point))
            && (subToolbar.isHidden || !subToolbar.frame.contains(point)) else {
            return
        }
        if case let .annotating(selection) = capturePhase {
            if beginSelectionEdit(
                at: point,
                selection: selection,
                allowsMove: false,
                preservesAnnotationMode: true
            ) {
                return
            }
            guard selection.contains(point) else { return }
            if let index = textElementIndex(at: point),
               case let .text(origin, _, _) = annotationHistory.elements[index] {
                movingText = (index, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
                return
            }
            if selectedAnnotationTool == .text {
                beginTextEditing(at: point, in: selection)
                return
            }
            activeAnnotationElement = ScreenshotAnnotationElement(
                tool: selectedAnnotationTool,
                start: point,
                style: annotationStyle,
                number: nextNumberValue
            )
            needsDisplay = true
            return
        }

        switch capturePhase {
        case .ready:
            beginNewSelection(at: point)
        case let .selected(selection):
            let suppressesDoubleClickCopy = event.clickCount >= 2 && didLastClickExpandSelection
            if event.clickCount >= 2,
               !suppressesDoubleClickCopy,
               selection.contains(point) {
                didLastClickExpandSelection = false
                copySelection()
                return
            }
            if suppressesDoubleClickCopy {
                didLastClickExpandSelection = false
            }
            if !beginSelectionEdit(
                at: point,
                selection: selection,
                allowsMove: true,
                preservesAnnotationMode: false
            ) {
                didLastClickExpandSelection = false
            }
        case .pressed, .dragging, .annotating:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: point)
        if var activeSelectionEdit {
            if case .pendingHandleExpansion = activeSelectionEdit.mode {
                guard distance(from: activeSelectionEdit.dragStart, to: point) >= dragThreshold else {
                    return
                }
                activeSelectionEdit.mode = .relativeDrag
                self.activeSelectionEdit = activeSelectionEdit
            }
            applySelectionEdit(activeSelectionEdit, current: point)
            return
        }
        if let movingText, case let .annotating(selection) = capturePhase {
            let origin = clamp(
                CGPoint(
                    x: point.x - movingText.grabOffset.x,
                    y: point.y - movingText.grabOffset.y
                ),
                to: selection
            )
            if annotationHistory.moveText(at: movingText.index, to: origin) {
                needsDisplay = true
            }
            return
        }
        if case let .annotating(selection) = capturePhase,
           let activeAnnotationElement {
            self.activeAnnotationElement = activeAnnotationElement.updating(
                to: clamp(point, to: selection)
            )
            needsDisplay = true
            return
        }

        continueInitialSelection(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: point)
        if var activeSelectionEdit {
            if case let .pendingHandleExpansion(clickTarget) = activeSelectionEdit.mode {
                if distance(from: activeSelectionEdit.dragStart, to: point) >= dragThreshold {
                    activeSelectionEdit.mode = .relativeDrag
                    didLastClickExpandSelection = false
                } else {
                    activeSelectionEdit = ActiveSelectionEdit(
                        originalSelection: activeSelectionEdit.originalSelection,
                        dragStart: activeSelectionEdit.dragStart,
                        target: clickTarget,
                        originalAnnotationHistory: activeSelectionEdit.originalAnnotationHistory,
                        preservesAnnotationMode: activeSelectionEdit.preservesAnnotationMode,
                        mode: .outwardExpansion
                    )
                    didLastClickExpandSelection = true
                }
            }
            applySelectionEdit(activeSelectionEdit, current: point)
            self.activeSelectionEdit = nil
            if let selection = confirmedSelection {
                showToolbar(for: selection)
            }
            updateCursor(at: point)
            needsDisplay = true
            return
        }

        if movingText != nil {
            movingText = nil
            updateAnnotationControls()
            needsDisplay = true
            return
        }

        if case .annotating = capturePhase {
            guard let activeAnnotationElement else {
                return
            }
            if activeAnnotationElement.isMeaningful {
                annotationHistory.append(activeAnnotationElement)
            }
            self.activeAnnotationElement = nil
            updateAnnotationControls()
            needsDisplay = true
            return
        }

        stopGlobalDragTracking()
        finishInitialSelection(at: point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard toolbar.isHidden || !toolbar.frame.contains(point) else {
            return
        }
        handleRightClick(at: point)
    }

    func handleRightClickOutsideTargetScreen() {
        handleRightClick(at: nil)
    }

    private func handleRightClick(at point: CGPoint?) {
        activeSelectionEdit = nil
        switch capturePhase {
        case .ready:
            onCancel?()
        case let .annotating(selection):
            cancelActiveTextInput(restoringFirstResponder: false)
            activeAnnotationElement = nil
            capturePhase = .selected(selection)
            resetAnnotationControls()
            updateCursor()
            needsDisplay = true
        case .pressed, .dragging, .selected:
            returnToInitialState(at: point)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, activeTextField != nil {
            cancelActiveTextInput()
            return
        }
        if handleColorShortcut(event, modifiers: modifiers) {
            return
        }
        if event.keyCode == 6, modifiers.contains(.command) {
            if modifiers.contains(.shift) {
                redoAnnotation()
            } else {
                undoAnnotation()
            }
            return
        }
        if applyKeyboardSelectionAdjustment(for: event, modifiers: modifiers) {
            return
        }
        if confirmedSelection != nil {
            if event.keyCode == 8, modifiers == .shift {
                ocrCopyAllSelection()
                return
            }
            if event.keyCode == 12, modifiers == .option {
                ocrTranslateSelection()
                return
            }
            if event.keyCode == 5, modifiers.isEmpty {
                screenRecordingSelection()
                return
            }
        }
        switch event.keyCode {
        case 53:
            onCancel?()
        case 36, 76:
            copySelection()
        default:
            super.keyDown(with: event)
        }
    }

    private func applyKeyboardSelectionAdjustment(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard case let .selected(selection) = capturePhase else {
            return false
        }
        let direction: CaptureSelectionKeyboardDirection
        switch event.keyCode {
        case 123:
            direction = .left
        case 124:
            direction = .right
        case 125:
            direction = .down
        case 126:
            direction = .up
        default:
            return false
        }

        let operation: CaptureSelectionKeyboardOperation
        if modifiers.contains(.command) {
            operation = .expand
        } else if modifiers.contains(.shift) {
            operation = .shrink
        } else {
            operation = .move
        }
        let pixelsPerPoint = max(
            bounds.width > 0 ? CGFloat(capturedImage.width) / bounds.width : 1,
            bounds.height > 0 ? CGFloat(capturedImage.height) / bounds.height : 1,
            1
        )
        let adjustment = CaptureSelectionKeyboardAdjustment(
            direction: direction,
            operation: operation,
            step: modifiers.contains(.option) ? .accelerated : .standard
        )
        let adjustedSelection = CaptureGeometry.adjustedSelection(
            selection,
            by: adjustment,
            in: bounds,
            minimumSide: 1 / pixelsPerPoint,
            pixelsPerPoint: pixelsPerPoint
        )

        if operation == .move {
            annotationHistory = translatedAnnotationHistory(
                annotationHistory,
                from: selection,
                to: adjustedSelection
            )
        }
        activeAnnotationElement = nil
        activeSelectionEdit = nil
        didLastClickExpandSelection = false
        capturePhase = .selected(adjustedSelection)
        showToolbar(for: adjustedSelection)
        updateAnnotationControls()
        updateCursor()
        needsDisplay = true
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        if activeTextField != nil {
            cancelActiveTextInput()
        } else {
            onCancel?()
        }
    }

    func prepareForCaptureInput() {
        window?.makeFirstResponder(self)
        if let window {
            let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let point = convert(pointInWindow, from: nil)
            updateHoveredCandidate(at: point)
            updateMagnifier(at: point)
        }
        updateCursor()
    }

    func cancelPendingWork() {
        stopGlobalDragTracking()
        cancelHoverRefinement()
        cancelActiveTextInput(restoringFirstResponder: false)
        activeSelectionEdit = nil
        hideMagnifier()
    }

    private var displayedSelection: CGRect? {
        switch capturePhase {
        case .ready:
            return hoveredCandidate
        case let .pressed(_, candidate):
            return candidate
        case let .dragging(start, current):
            return CaptureGeometry.selectionRect(from: start, to: current, in: bounds)
        case let .selected(selection), let .annotating(selection):
            return selection
        }
    }

    private func configureToolbar() {
        let container = ScreenshotToolbarContainerView(frame: CGRect(origin: .zero, size: toolbarSize))
        container.cornerRadius = usesTwoRowToolbar ? 12 : 22
        container.isHidden = true

        let toolButtons = ScreenshotAnnotationTool.allCases.map { tool in
            let button = makeToolbarButton(
                title: tool.title,
                symbol: tool.symbolName,
                action: #selector(selectAnnotationTool(_:))
            )
            button.tag = tool.rawValue
            annotationToolButtons[tool] = button
            return button
        }
        undoButton = makeToolbarButton(title: "撤销", symbol: "arrow.uturn.backward", action: #selector(undoAnnotation))
        redoButton = makeToolbarButton(title: "重做", symbol: "arrow.uturn.forward", action: #selector(redoAnnotation))
        let ocrCopyButton = makeToolbarButton(title: "OCR", symbol: "text.viewfinder", action: #selector(ocrCopySelection))
        let ocrTranslateButton = makeToolbarButton(title: "OCR翻译", symbol: "character.bubble", action: #selector(ocrTranslateSelection))
        let barcodeButton = makeToolbarButton(title: "二维码", symbol: "qrcode.viewfinder", action: #selector(detectBarcodeSelection))
        let longScreenshotButton = makeToolbarButton(title: "长截图", symbol: "scroll", action: #selector(longScreenshotSelection))
        let screenRecordingButton = makeToolbarButton(title: "录屏", symbol: "record.circle", action: #selector(screenRecordingSelection))
        let pinButton = makeToolbarButton(title: "贴图", symbol: "pin.fill", action: #selector(pinSelection))
        let saveButton = makeToolbarButton(title: "保存", symbol: "square.and.arrow.down", action: #selector(saveSelection))
        let cancelButton = makeToolbarButton(title: "取消", symbol: "xmark", action: #selector(cancelSelection))
        let copyButton = makeToolbarButton(title: "复制", symbol: "doc.on.doc", action: #selector(copySelection))

        let actionButtons: [NSButton] = [
            undoButton,
            redoButton,
            ocrCopyButton,
            ocrTranslateButton,
            barcodeButton,
            longScreenshotButton,
            screenRecordingButton,
            pinButton,
            saveButton,
            cancelButton,
            copyButton,
        ]
        toolbarToolButtons = toolButtons
        toolbarActionButtons = actionButtons
        toolbarButtons = toolButtons + actionButtons
        toolbarToolRow = makeToolbarRow([])
        toolbarActionRow = makeToolbarRow([])
        let stack = NSStackView(frame: container.bounds.insetBy(dx: 10, dy: 5))
        stack.frame = container.bounds.insetBy(dx: 10, dy: 5)
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        addSubview(container)
        toolbar = container
        toolbarStack = stack

        let subBar = ScreenshotSubToolbarView(frame: .zero)
        subBar.isHidden = true
        subBar.onStyleChanged = { [weak self] newStyle in
            guard let self else { return }
            self.annotationStyle = newStyle
            self.needsDisplay = true
        }
        subBar.onToolChanged = { [weak self] newTool in
            guard let self else { return }
            self.selectedAnnotationTool = newTool
            self.updateAnnotationControls()
            self.needsDisplay = true
        }
        addSubview(subBar, positioned: .above, relativeTo: container)
        subToolbar = subBar

        configureToolbarHelpBubble()
        updateToolbarLayout(force: true)
        updateToolbarButtonPresentation()
        updateAnnotationControls()
    }

    private func configureMagnifier() {
        let magnifier = ScreenshotMagnifierView(frame: CGRect(
            origin: .zero,
            size: ScreenshotMagnifierView.preferredSize
        ))
        addSubview(magnifier)
        magnifierView = magnifier
    }

    private func makeToolbarRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 4
        return row
    }

    private func makeToolbarButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = ScreenshotToolbarButton(title: title, target: self, action: action)
        button.title = title
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.controlSize = .large
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(symbolConfiguration)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor(white: 0.18, alpha: 1.0)
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(title)
        button.onHoverChanged = { [weak self] button, isHovering in
            if isHovering {
                self?.showToolbarHelp(for: button)
            } else {
                self?.hideToolbarHelp(for: button)
            }
        }
        return button
    }

    private func configureToolbarHelpBubble() {
        let bubble = ScreenshotToolbarHelpBubble(frame: .zero)
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        bubble.layer?.cornerRadius = 7
        bubble.layer?.masksToBounds = true
        bubble.isHidden = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        bubble.addSubview(label)
        addSubview(bubble, positioned: .above, relativeTo: toolbar)
        toolbarHelpBubble = bubble
        toolbarHelpLabel = label
    }

    private func showToolbarHelp(for button: NSButton) {
        guard !toolbar.isHidden else {
            return
        }
        let help = button.toolTip ?? button.title
        guard !help.isEmpty else {
            return
        }
        toolbarHelpLabel.stringValue = help
        hoveredToolbarButton = button
        let maximumWidth = max(1, min(360, bounds.width - 16))
        let textSize = help.size(withAttributes: [
            .font: toolbarHelpLabel.font ?? NSFont.systemFont(ofSize: 12),
        ])
        let size = CGSize(
            width: min(maximumWidth, max(min(120, maximumWidth), textSize.width + 20)),
            height: 28
        )
        let x = min(
            max(bounds.minX + 8, button.convert(button.bounds, to: self).midX - size.width / 2),
            bounds.maxX - size.width - 8
        )
        let aboveY = toolbar.frame.maxY + 6
        let belowY = toolbar.frame.minY - size.height - 6
        let preferredY = aboveY + size.height <= bounds.maxY - 8 ? aboveY : belowY
        let y = min(
            max(bounds.minY + 8, preferredY),
            bounds.maxY - size.height - 8
        )
        toolbarHelpBubble.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        toolbarHelpLabel.frame = toolbarHelpBubble.bounds.insetBy(dx: 8, dy: 5)
        toolbarHelpBubble.isHidden = false
    }

    private func hideToolbarHelp(for button: NSButton? = nil) {
        if let button, hoveredToolbarButton !== button {
            return
        }
        hoveredToolbarButton = nil
        toolbarHelpBubble?.isHidden = true
        toolbarHelpLabel?.stringValue = ""
    }

    private func showToolbar(for selection: CGRect) {
        hideToolbarHelp()
        toolbar.frame.size = toolbarSize
        updateToolbarLayout()
        updateToolbarButtonPresentation()
        toolbar.frame.origin = CaptureGeometry.toolbarOrigin(
            selection: selection,
            toolbarSize: toolbarSize,
            bounds: toolbarPlacementBounds
        )
        toolbar.isHidden = false
        updateSubToolbar()
    }

    private func updateSubToolbar() {
        guard case .annotating = capturePhase, !toolbar.isHidden else {
            subToolbar?.isHidden = true
            return
        }
        subToolbar?.update(tool: selectedAnnotationTool, style: annotationStyle)
        subToolbar?.isHidden = false
        updateSubToolbarPosition()
    }

    private func updateSubToolbarPosition() {
        guard let subToolbar, !subToolbar.isHidden, !toolbar.isHidden else { return }
        let naturalWidth = subToolbar.fittingSize.width > 50 ? subToolbar.fittingSize.width : 360
        let subSize = CGSize(width: min(bounds.width - 20, naturalWidth), height: 34)
        var originX = toolbar.frame.minX
        if originX + subSize.width > bounds.maxX - 10 {
            originX = bounds.maxX - subSize.width - 10
        }
        if originX < bounds.minX + 10 {
            originX = bounds.minX + 10
        }

        var originY = toolbar.frame.minY - subSize.height - 6
        if originY < bounds.minY + 6 {
            originY = toolbar.frame.maxY + 6
        }
        subToolbar.frame = CGRect(origin: CGPoint(x: originX, y: originY), size: subSize)
    }

    private func beginNewSelection(at point: CGPoint) {
        let candidate = candidateForPress(at: point)
        cancelHoverRefinement()
        activeSelectionEdit = nil
        didLastClickExpandSelection = false
        hoveredCandidate = candidate
        capturePhase = .pressed(start: point, candidate: candidate)
        toolbar.isHidden = true
        subToolbar?.isHidden = true
        hideToolbarHelp()
        annotationHistory.removeAll()
        activeAnnotationElement = nil
        cancelActiveTextInput(restoringFirstResponder: false)
        updateAnnotationControls()
        updateCursor()
        needsDisplay = true
        startGlobalDragTracking()
    }

    private func startGlobalDragTracking() {
        stopGlobalDragTracking()
        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(trackGlobalDrag(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        globalDragTimer = timer
    }

    private func stopGlobalDragTracking() {
        globalDragTimer?.invalidate()
        globalDragTimer = nil
    }

    @objc private func trackGlobalDrag(_ timer: Timer) {
        advanceGlobalDrag(
            globalPoint: NSEvent.mouseLocation,
            leftButtonPressed: NSEvent.pressedMouseButtons & 1 != 0
        )
    }

    func advanceGlobalDragForTesting(globalPoint: CGPoint, leftButtonPressed: Bool) {
        advanceGlobalDrag(globalPoint: globalPoint, leftButtonPressed: leftButtonPressed)
    }

    private func advanceGlobalDrag(globalPoint: CGPoint, leftButtonPressed: Bool) {
        switch capturePhase {
        case .pressed, .dragging:
            break
        case .ready, .selected, .annotating:
            stopGlobalDragTracking()
            return
        }
        let localPoint = CGPoint(
            x: globalPoint.x - captureFrame.minX,
            y: globalPoint.y - captureFrame.minY
        )
        if leftButtonPressed {
            continueInitialSelection(to: localPoint)
        } else {
            stopGlobalDragTracking()
            finishInitialSelection(at: localPoint)
        }
    }

    private func continueInitialSelection(to point: CGPoint) {
        switch capturePhase {
        case let .pressed(start, _):
            guard distance(from: start, to: point) >= dragThreshold else { return }
            hoveredCandidate = nil
            capturePhase = .dragging(start: start, current: point)
        case let .dragging(start, _):
            capturePhase = .dragging(start: start, current: point)
        case .ready, .selected, .annotating:
            return
        }
        needsDisplay = true
    }

    private func finishInitialSelection(at point: CGPoint) {
        switch capturePhase {
        case let .pressed(start, candidate):
            if distance(from: start, to: point) >= dragThreshold {
                confirmSelection(CaptureGeometry.selectionRect(from: start, to: point, in: bounds))
            } else if let candidate {
                confirmSelection(candidate)
            } else {
                returnToInitialState(at: point)
            }
        case let .dragging(start, _):
            confirmSelection(CaptureGeometry.selectionRect(from: start, to: point, in: bounds))
        case .ready, .selected, .annotating:
            return
        }
    }

    private func applySelectionEdit(_ edit: ActiveSelectionEdit, current point: CGPoint) {
        let selection: CGRect
        switch edit.mode {
        case .relativeDrag:
            selection = CaptureGeometry.editedSelection(
                original: edit.originalSelection,
                dragStart: edit.dragStart,
                current: point,
                target: edit.target,
                bounds: bounds
            )
            switch edit.target {
            case .move:
                annotationHistory = translatedAnnotationHistory(
                    edit.originalAnnotationHistory,
                    from: edit.originalSelection,
                    to: selection
                )
            case .resize:
                annotationHistory = edit.originalAnnotationHistory
            }
        case .outwardExpansion:
            selection = CaptureGeometry.expandedSelection(
                edit.originalSelection,
                toward: point,
                target: edit.target,
                in: bounds
            )
            annotationHistory = edit.originalAnnotationHistory
        case .pendingHandleExpansion:
            selection = edit.originalSelection
            annotationHistory = edit.originalAnnotationHistory
        }
        capturePhase = edit.preservesAnnotationMode ? .annotating(selection) : .selected(selection)
        toolbar.isHidden = true
        hideToolbarHelp()
        setSelectionCursor(for: edit.target, isDragging: true)
        needsDisplay = true
    }

    @discardableResult
    private func beginSelectionEdit(
        at point: CGPoint,
        selection: CGRect,
        allowsMove: Bool,
        preservesAnnotationMode: Bool
    ) -> Bool {
        if let target = CaptureGeometry.selectionEditTarget(at: point, selection: selection),
           allowsMove || target != .move {
            let mode: SelectionEditMode
            if let clickTarget = CaptureGeometry.selectionExpansionTarget(
                at: point,
                selection: selection
            ) {
                mode = .pendingHandleExpansion(clickTarget: clickTarget)
            } else {
                mode = .relativeDrag
            }
            activeSelectionEdit = ActiveSelectionEdit(
                originalSelection: selection,
                dragStart: point,
                target: target,
                originalAnnotationHistory: annotationHistory,
                preservesAnnotationMode: preservesAnnotationMode,
                mode: mode
            )
            didLastClickExpandSelection = false
            toolbar.isHidden = true
            hideToolbarHelp()
            setSelectionCursor(for: target, isDragging: true)
            return true
        }

        guard !selection.contains(point),
              let target = CaptureGeometry.selectionExpansionTarget(at: point, selection: selection) else {
            return false
        }
        let edit = ActiveSelectionEdit(
            originalSelection: selection,
            dragStart: point,
            target: target,
            originalAnnotationHistory: annotationHistory,
            preservesAnnotationMode: preservesAnnotationMode,
            mode: .outwardExpansion
        )
        activeSelectionEdit = edit
        didLastClickExpandSelection = true
        applySelectionEdit(edit, current: point)
        return true
    }

    private func translatedAnnotationHistory(
        _ sourceHistory: ScreenshotAnnotationHistory,
        from source: CGRect,
        to destination: CGRect
    ) -> ScreenshotAnnotationHistory {
        let translation = CGPoint(
            x: destination.minX - source.minX,
            y: destination.minY - source.minY
        )
        return sourceHistory.transformed { point in
            CGPoint(
                x: point.x + translation.x,
                y: point.y + translation.y
            )
        }
    }

    @objc private func selectAnnotationTool(_ sender: NSButton) {
        guard let tool = ScreenshotAnnotationTool(rawValue: sender.tag) else {
            return
        }
        cancelActiveTextInput(restoringFirstResponder: false)
        if case let .annotating(selection) = capturePhase, selectedAnnotationTool == tool {
            capturePhase = .selected(selection)
            activeAnnotationElement = nil
            resetAnnotationControls()
            updateCursor()
            needsDisplay = true
            window?.makeFirstResponder(self)
            return
        }

        selectedAnnotationTool = tool
        switch capturePhase {
        case let .selected(selection):
            capturePhase = .annotating(selection)
        case .annotating:
            activeAnnotationElement = nil
        case .ready, .pressed, .dragging:
            NSSound.beep()
            return
        }
        updateAnnotationControls()
        updateCursor()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    @objc private func undoAnnotation() {
        cancelActiveTextInput(restoringFirstResponder: false)
        guard annotationHistory.undo() != nil else {
            return
        }
        activeAnnotationElement = nil
        updateAnnotationControls()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    @objc private func redoAnnotation() {
        cancelActiveTextInput(restoringFirstResponder: false)
        guard annotationHistory.redo() != nil else {
            return
        }
        activeAnnotationElement = nil
        updateAnnotationControls()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    @objc private func copySelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.copy(result))
    }

    @objc private func saveSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.save(result))
    }

    @objc private func pinSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.pin(result))
    }

    @objc private func ocrCopySelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.ocrCopy(result))
    }

    private func ocrCopyAllSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.ocrCopyAll(result))
    }

    @objc private func ocrTranslateSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.ocrTranslate(result))
    }

    @objc private func detectBarcodeSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.detectBarcode(result))
    }

    @objc private func longScreenshotSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.longScreenshot(result))
    }

    @objc private func screenRecordingSelection() {
        guard let result = makeSelectedScreenshot() else {
            NSSound.beep()
            return
        }
        onAction?(.screenRecording(result))
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    private func makeSelectedScreenshot() -> SelectedScreenshot? {
        guard let selection = confirmedSelection else {
            return nil
        }
        let cropRect = CaptureGeometry.pixelCropRect(
            selection: selection,
            viewSize: bounds.size,
            imagePixelSize: CGSize(width: capturedImage.width, height: capturedImage.height)
        )
        guard let croppedImage = capturedImage.cropping(to: cropRect),
              let composedImage = ScreenshotImageComposer.compose(
                  image: croppedImage,
                  selection: selection,
                  elements: annotationHistory.elements
              ) else {
            return nil
        }
        let image = NSImage(cgImage: composedImage, size: selection.size)
        let screenFrame = VirtualDesktopCapture.globalFrame(for: selection, in: captureFrame)
        return SelectedScreenshot(image: image, screenFrame: screenFrame)
    }

    private func drawAnnotations() {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        ScreenshotAnnotationRenderer.draw(
            elements: annotationHistory.elements
                + (activeAnnotationElement.map { [$0] } ?? []),
            in: context,
            sourceImage: capturedImage,
            sourcePixelTransform: { [bounds, capturedImage] point in
                guard bounds.width > 0, bounds.height > 0 else {
                    return .zero
                }
                return CGPoint(
                    x: point.x * CGFloat(capturedImage.width) / bounds.width,
                    y: point.y * CGFloat(capturedImage.height) / bounds.height
                )
            }
        )
    }

    private func confirmSelection(_ selection: CGRect) {
        let clippedSelection = selection.standardized.intersection(bounds)
        guard !clippedSelection.isNull, CaptureGeometry.isUsable(clippedSelection) else {
            returnToInitialState()
            return
        }
        cancelHoverRefinement()
        activeSelectionEdit = nil
        didLastClickExpandSelection = false
        hoveredCandidate = nil
        capturePhase = .selected(clippedSelection)
        hideMagnifier()
        if let preferredAction {
            switch preferredAction {
            case .longScreenshot:
                if let result = makeSelectedScreenshot() {
                    onAction?(.longScreenshot(result))
                    return
                }
            case .screenRecording:
                if let result = makeSelectedScreenshot() {
                    onAction?(.screenRecording(result))
                    return
                }
            case .screenTranslation:
                onAction?(.screenTranslation(ScreenTranslationSelection(
                    capture: ScreenTranslationCapture(
                        fullImage: capturedImage,
                        screenFrame: captureFrame
                    ),
                    selection: VirtualDesktopCapture.globalFrame(
                        for: clippedSelection,
                        in: captureFrame
                    )
                )))
                return
            }
        }
        resetAnnotationControls()
        showToolbar(for: clippedSelection)
        updateCursor()
        needsDisplay = true
    }

    private func returnToInitialState(at point: CGPoint? = nil) {
        activeSelectionEdit = nil
        didLastClickExpandSelection = false
        capturePhase = .ready
        annotationHistory.removeAll()
        activeAnnotationElement = nil
        cancelActiveTextInput(restoringFirstResponder: false)
        toolbar.isHidden = true
        hideToolbarHelp()
        resetAnnotationControls()
        if let point {
            updateHoveredCandidate(at: point)
            updateMagnifier(at: point)
        } else {
            cancelHoverRefinement()
            lastHoverPoint = nil
            hoveredCandidate = nil
            hideMagnifier()
        }
        updateCursor()
        needsDisplay = true
    }

    private func resetAnnotationControls() {
        cancelActiveTextInput(restoringFirstResponder: false)
        activeAnnotationElement = nil
        updateAnnotationControls()
    }

    private func updateAnnotationControls() {
        for (tool, button) in annotationToolButtons {
            let isSelected = isAnnotating && tool == selectedAnnotationTool
            button.state = .off
            if let toolbarBtn = button as? ScreenshotToolbarButton {
                toolbarBtn.isActive = isSelected
            } else {
                button.contentTintColor = isSelected ? .controlAccentColor : NSColor(white: 0.18, alpha: 1.0)
            }
        }
        undoButton?.isEnabled = annotationHistory.canUndo
        redoButton?.isEnabled = annotationHistory.canRedo
        updateSubToolbar()
    }

    private func updateToolbarButtonPresentation() {
        for button in toolbarButtons {
            button.imagePosition = .imageOnly
            (button as? ScreenshotToolbarButton)?.updateAppearance()
        }
    }

    private func updateToolbarLayout(force: Bool = false) {
        let usesTwoRows = usesTwoRowToolbar
        guard force || toolbarUsesTwoRows != usesTwoRows else {
            return
        }
        toolbarUsesTwoRows = usesTwoRows
        toolbar.cornerRadius = usesTwoRows ? 12 : 22
        removeAllArrangedSubviews(from: toolbarStack)
        removeAllArrangedSubviews(from: toolbarToolRow)
        removeAllArrangedSubviews(from: toolbarActionRow)

        toolbarStack.spacing = 4
        toolbarStack.distribution = .fillEqually
        if usesTwoRows {
            toolbarStack.orientation = .vertical
            toolbarStack.alignment = .leading
            toolbarToolButtons.forEach(toolbarToolRow.addArrangedSubview)
            toolbarActionButtons.forEach(toolbarActionRow.addArrangedSubview)
            toolbarStack.addArrangedSubview(toolbarToolRow)
            toolbarStack.addArrangedSubview(toolbarActionRow)
        } else {
            toolbarStack.orientation = .horizontal
            toolbarStack.alignment = .centerY
            toolbarButtons.forEach(toolbarStack.addArrangedSubview)
        }
    }

    private func removeAllArrangedSubviews(from stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func handleColorShortcut(
        _ event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard event.keyCode == 8,
              modifiers.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch capturePhase {
        case .ready, .pressed, .dragging:
            break
        case .selected, .annotating:
            return false
        }

        if modifiers.contains(.shift) {
            colorDisplayFormat.toggle()
            refreshMagnifierContent()
        } else if let currentPixelSample {
            colorPasteboard.clearContents()
            // Copy what the magnifier currently shows: switching to RGB must also
            // switch what lands on the pasteboard.
            let copied = currentPixelSample.text(format: colorDisplayFormat)
            guard colorPasteboard.setString(copied, forType: .string) else {
                NSSound.beep()
                return true
            }
            magnifierView.showCopyConfirmation(copied)
        } else {
            NSSound.beep()
        }
        return true
    }

    private func updateMagnifier(at point: CGPoint) {
        switch capturePhase {
        case .ready, .pressed, .dragging:
            break
        case .selected, .annotating:
            hideMagnifier()
            return
        }
        guard let pixelSampler,
              let sample = pixelSampler.sample(
                  atViewPoint: point,
                  viewSize: bounds.size
              ) else {
            hideMagnifier()
            return
        }

        currentPixelSample = sample
        magnifierView.frame = ScreenshotMagnifierView.positionedFrame(
            near: point,
            in: bounds
        )
        magnifierView.update(
            sampler: pixelSampler,
            sample: sample,
            format: colorDisplayFormat
        )
        magnifierView.isHidden = false
    }

    private func refreshMagnifierContent() {
        guard !magnifierView.isHidden,
              let pixelSampler,
              let currentPixelSample else {
            return
        }
        magnifierView.update(
            sampler: pixelSampler,
            sample: currentPixelSample,
            format: colorDisplayFormat
        )
    }

    private func hideMagnifier() {
        currentPixelSample = nil
        magnifierView?.isHidden = true
    }

    private func beginTextEditing(at point: CGPoint, in selection: CGRect) {
        cancelActiveTextInput(restoringFirstResponder: false)
        let fieldHeight: CGFloat = 26
        let fieldWidth = min(220, selection.width)
        guard fieldWidth >= 2, selection.height >= 2 else {
            NSSound.beep()
            return
        }
        let origin = clamp(point, to: selection)
        let x = min(max(origin.x, selection.minX), selection.maxX - fieldWidth)
        var y = origin.y
        if y + fieldHeight > selection.maxY {
            y = origin.y - fieldHeight
        }
        y = min(max(y, selection.minY), max(selection.minY, selection.maxY - fieldHeight))

        let field = NSTextField(frame: CGRect(
            x: x,
            y: y,
            width: fieldWidth,
            height: min(fieldHeight, selection.height)
        ))
        field.placeholderString = "输入文字，回车确认"
        field.font = .systemFont(ofSize: annotationStyle.fontSize, weight: .semibold)
        field.textColor = annotationStyle.color
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.94)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.target = self
        field.action = #selector(commitTextAnnotation(_:))
        field.toolTip = "回车确认，Esc 取消"
        field.setAccessibilityLabel("截图文字标注输入")

        activeTextOrigin = origin
        activeTextField = field
        addSubview(field, positioned: .above, relativeTo: toolbar)
        window?.makeFirstResponder(field)
    }

    private var nextNumberValue: Int {
        annotationHistory.elements.reduce(0) { partialResult, element in
            if case let .number(_, value, _) = element {
                return max(partialResult, value)
            }
            return partialResult
        } + 1
    }

    private func textElementIndex(at point: CGPoint) -> Int? {
        annotationHistory.elements.indices.reversed().first { index in
            guard case let .text(origin, text, style) = annotationHistory.elements[index] else {
                return false
            }
            let size = (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: style.fontSize, weight: .semibold),
            ])
            return CGRect(
                x: origin.x - 4,
                y: origin.y - 6,
                width: max(size.width, 24) + 8,
                height: max(size.height, style.fontSize) + 12
            ).contains(point)
        }
    }

    @objc private func commitTextAnnotation(_ sender: Any?) {
        guard let field = activeTextField,
              let origin = activeTextOrigin else {
            return
        }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelActiveTextInput(restoringFirstResponder: true)
        let element = ScreenshotAnnotationElement.text(
            origin: origin,
            text: text,
            style: annotationStyle
        )
        if element.isMeaningful {
            annotationHistory.append(element)
        }
        updateAnnotationControls()
        needsDisplay = true
    }

    private func cancelActiveTextInput(restoringFirstResponder: Bool = true) {
        guard let field = activeTextField else {
            activeTextOrigin = nil
            return
        }
        activeTextField = nil
        activeTextOrigin = nil
        if restoringFirstResponder {
            window?.makeFirstResponder(self)
        }
        field.removeFromSuperview()
        needsDisplay = true
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commitTextAnnotation(control)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelActiveTextInput()
            return true
        default:
            return false
        }
    }

    private func updateHoveredCandidate(at point: CGPoint) {
        lastHoverPoint = point
        let candidate = candidateRegion(at: point)
        if candidate != hoveredCandidate {
            hoveredCandidate = candidate
            needsDisplay = true
        }
        scheduleElementRefinement(at: point)
    }

    private func candidateRegion(at point: CGPoint) -> CGRect? {
        guard bounds.contains(point) else {
            return nil
        }
        return validatedCandidate(regionProvider?(point))
    }

    private func candidateForPress(at point: CGPoint) -> CGRect? {
        if let lastHoverPoint,
           distance(from: lastHoverPoint, to: point) < 2,
           let hoveredCandidate,
           hoveredCandidate.contains(point) {
            return hoveredCandidate
        }
        return candidateRegion(at: point)
    }

    private func validatedCandidate(_ candidate: CGRect?) -> CGRect? {
        guard let candidate else {
            return nil
        }
        let clippedCandidate = candidate.standardized.intersection(bounds)
        guard !clippedCandidate.isNull, CaptureGeometry.isUsable(clippedCandidate) else {
            return nil
        }
        return clippedCandidate
    }

    private func scheduleElementRefinement(at point: CGPoint) {
        cancelHoverRefinement()
        guard let regionRefiner else {
            return
        }

        let requestID = hoverRequestID
        hoverRefinementTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(45))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            let refinedCandidate = await regionRefiner(point)
            guard !Task.isCancelled, let self else {
                return
            }
            await self.applyRefinedCandidate(refinedCandidate, requestID: requestID)
        }
    }

    private func applyRefinedCandidate(_ candidate: CGRect?, requestID: Int) {
        guard hoverRequestID == requestID,
              case .ready = capturePhase,
              let candidate = validatedCandidate(candidate) else {
            return
        }
        hoveredCandidate = candidate
        needsDisplay = true
    }

    private func cancelHoverRefinement() {
        hoverRefinementTask?.cancel()
        hoverRefinementTask = nil
        hoverRequestID += 1
    }

    private func distance(from start: CGPoint, to end: CGPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func updateCursor(at point: CGPoint? = nil) {
        window?.invalidateCursorRects(for: self)
        if case let .selected(selection) = capturePhase {
            let pointer = point ?? window.map { window in
                convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            }
            setSelectionCursor(
                for: pointer.flatMap {
                    CaptureGeometry.selectionEditTarget(at: $0, selection: selection)
                },
                isDragging: activeSelectionEdit != nil
            )
        } else if case let .annotating(selection) = capturePhase {
            if let point {
                setAnnotationCursor(at: point, selection: selection)
            } else {
                NSCursor.crosshair.set()
            }
        } else if cursorMode == .crosshair {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func setAnnotationCursor(at point: CGPoint, selection: CGRect) {
        if let target = CaptureGeometry.selectionEditTarget(at: point, selection: selection),
           target != .move {
            setSelectionCursor(for: target, isDragging: activeSelectionEdit != nil)
        } else if !selection.contains(point),
                  let target = CaptureGeometry.selectionExpansionTarget(at: point, selection: selection) {
            setSelectionCursor(for: target, isDragging: activeSelectionEdit != nil)
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func setSelectionCursor(
        for target: CaptureSelectionEditTarget?,
        isDragging: Bool
    ) {
        switch target {
        case .move:
            (isDragging ? NSCursor.closedHand : NSCursor.arrow).set()
        case let .resize(handle):
            switch handle {
            case .left, .right:
                NSCursor.resizeLeftRight.set()
            case .top, .bottom:
                NSCursor.resizeUpDown.set()
            case .topLeft, .topRight, .bottomRight, .bottomLeft:
                NSCursor.arrow.set()
            }
        case nil:
            NSCursor.arrow.set()
        }
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func drawInstructions() {
        let text = "移动鼠标自动选择 · C 复制色值 · ⇧C 切换 HEX/RGB · 右键返回 · Esc 退出"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.68),
        ]
        let size = text.size(withAttributes: attributes)
        let point = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 36)
        text.draw(at: point, withAttributes: attributes)
    }

    private func drawSizeLabel(for selection: CGRect) {
        let outputSize = CaptureGeometry.outputPixelSize(
            selection: selection,
            viewSize: bounds.size,
            imagePixelSize: CGSize(width: capturedImage.width, height: capturedImage.height)
        )
        let text = "\(Int(outputSize.width)) × \(Int(outputSize.height)) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72),
        ]
        let size = text.size(withAttributes: attributes)
        let x = min(selection.minX, bounds.maxX - size.width - 6)
        let y = min(bounds.maxY - size.height - 4, selection.maxY + 6)
        text.draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private func drawSelectionHandles(for selection: CGRect) {
        let points = [
            CGPoint(x: selection.minX, y: selection.minY),
            CGPoint(x: selection.midX, y: selection.minY),
            CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.midY),
            CGPoint(x: selection.maxX, y: selection.midY),
            CGPoint(x: selection.minX, y: selection.maxY),
            CGPoint(x: selection.midX, y: selection.maxY),
            CGPoint(x: selection.maxX, y: selection.maxY),
        ]
        for point in points {
            let handle = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            let handlePath = NSBezierPath(ovalIn: handle)
            handlePath.fill()
            NSColor.controlAccentColor.setStroke()
            handlePath.lineWidth = 1.5
            handlePath.stroke()
        }
    }
}
