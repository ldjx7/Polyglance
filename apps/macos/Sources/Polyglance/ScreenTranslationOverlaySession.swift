import AppKit
import SwiftUI

struct ScreenTranslationRenderedParagraph {
    let normalizedRect: CGRect
    let text: String
    let backgroundColor: NSColor
    let textColor: NSColor
    let lineCount: Int
}

enum ScreenTranslationRenderer {
    static func drawContent(
        image: NSImage?,
        paragraphs: [ScreenTranslationRenderedParagraph],
        showsTranslation: Bool,
        in rect: CGRect
    ) {
        image?.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
        guard showsTranslation else {
            return
        }
        for paragraph in paragraphs {
            drawParagraph(paragraph, in: rect)
        }
    }

    static func exportImage(
        image: NSImage?,
        paragraphs: [ScreenTranslationRenderedParagraph],
        showsTranslation: Bool,
        size: CGSize,
        scale: CGFloat
    ) -> NSImage? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let flippedContent = NSImage(size: size, flipped: true) { rect in
            drawContent(
                image: image,
                paragraphs: paragraphs,
                showsTranslation: showsTranslation,
                in: rect
            )
            return true
        }
        let pixelScale = max(1, scale)
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * pixelScale),
            pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        flippedContent.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let exported = NSImage(size: size)
        exported.addRepresentation(representation)
        return exported
    }

    private static func drawParagraph(
        _ paragraph: ScreenTranslationRenderedParagraph,
        in contentRect: CGRect
    ) {
        let box = paragraph.normalizedRect.standardized
        let rect = CGRect(
            x: contentRect.minX + box.minX * contentRect.width,
            y: contentRect.minY + (1 - box.maxY) * contentRect.height,
            width: box.width * contentRect.width,
            height: box.height * contentRect.height
        )
        let padding = min(4, rect.height * 0.12)
        let backgroundRect = rect.insetBy(dx: -padding, dy: -padding)
            .intersection(contentRect.insetBy(dx: -1, dy: -1))
        let cornerRadius = min(4, backgroundRect.height * 0.15)
        let path = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        paragraph.backgroundColor.setFill()
        path.fill()

        let (attributes, textHeight) = fittedAttributes(
            for: paragraph.text,
            width: rect.width,
            height: rect.height + padding * 1.5,
            lineCount: paragraph.lineCount,
            color: paragraph.textColor
        )
        let textRect = CGRect(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - textHeight) / 2),
            width: rect.width,
            height: min(rect.height + padding * 1.5, textHeight)
        )
        (paragraph.text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
    }

    private static func fittedAttributes(
        for text: String,
        width: CGFloat,
        height: CGFloat,
        lineCount: Int,
        color: NSColor
    ) -> ([NSAttributedString.Key: Any], CGFloat) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        var fontSize = min(60, max(9, height / CGFloat(max(1, lineCount)) * 0.74))
        var measuredHeight: CGFloat = 0
        while fontSize >= 9 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle,
            ]
            measuredHeight = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: attributes
            ).height
            if measuredHeight <= height {
                return (attributes, measuredHeight)
            }
            fontSize -= 1
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle,
        ]
        return (attributes, measuredHeight)
    }
}

final class ScreenTranslationOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private enum ScreenTranslationDragZone {
    case move
    case resize(top: Bool, bottom: Bool, left: Bool, right: Bool)
}

final class ScreenTranslationOverlayView: NSView {
    static let contentMargin: CGFloat = 9

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var paragraphs: [ScreenTranslationRenderedParagraph] = [] {
        didSet { needsDisplay = true }
    }

    var showsTranslation = false {
        didSet { needsDisplay = true }
    }

    var onDragBegan: (() -> Void)?
    fileprivate var onDragChanged: ((ScreenTranslationDragZone, CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var dragZone: ScreenTranslationDragZone?
    private var dragStartLocation: CGPoint = .zero

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var contentRect: CGRect {
        bounds.insetBy(dx: Self.contentMargin, dy: Self.contentMargin)
    }

    override func draw(_ dirtyRect: NSRect) {
        ScreenTranslationRenderer.drawContent(
            image: image,
            paragraphs: paragraphs,
            showsTranslation: showsTranslation,
            in: contentRect
        )
        drawChrome()
    }

    private func drawChrome() {
        let borderColor = NSColor.controlAccentColor
        let borderPath = NSBezierPath(rect: contentRect)
        borderPath.lineWidth = 2.0
        borderColor.setStroke()
        borderPath.stroke()

        for center in handleCenters(in: contentRect) {
            let handleRect = CGRect(
                x: center.x - 4.5,
                y: center.y - 4.5,
                width: 9,
                height: 9
            )
            let circle = NSBezierPath(ovalIn: handleRect)
            NSColor.white.setFill()
            circle.fill()
            circle.lineWidth = 1.5
            borderColor.setStroke()
            circle.stroke()
        }
    }

    private func handleCenters(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocation = event.locationInWindow
        dragZone = zone(atWindowLocation: dragStartLocation)
        if dragZone != nil {
            onDragBegan?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragZone else {
            return
        }
        let location = event.locationInWindow
        let delta = CGSize(
            width: location.x - dragStartLocation.x,
            height: location.y - dragStartLocation.y
        )
        onDragChanged?(dragZone, delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragZone != nil else {
            return
        }
        dragZone = nil
        onDragEnded?()
    }

    /// The window shares the view's size; window coordinates keep the
    /// bottom-left origin so resize math stays in global-screen orientation.
    private func zone(atWindowLocation location: CGPoint) -> ScreenTranslationDragZone? {
        let margin = Self.contentMargin
        let rect = CGRect(
            x: margin,
            y: margin,
            width: bounds.width - margin * 2,
            height: bounds.height - margin * 2
        )
        let handleRadius: CGFloat = 9
        let nearLeft = abs(location.x - rect.minX) <= handleRadius
        let nearRight = abs(location.x - rect.maxX) <= handleRadius
        let nearBottom = abs(location.y - rect.minY) <= handleRadius
        let nearTop = abs(location.y - rect.maxY) <= handleRadius
        let withinX = location.x >= rect.minX - handleRadius
            && location.x <= rect.maxX + handleRadius
        let withinY = location.y >= rect.minY - handleRadius
            && location.y <= rect.maxY + handleRadius
        guard withinX, withinY else {
            return nil
        }
        if nearTop || nearBottom || nearLeft || nearRight {
            return .resize(
                top: nearTop,
                bottom: nearBottom,
                left: nearLeft,
                right: nearRight
            )
        }
        guard rect.contains(location) else {
            return nil
        }
        return .move
    }
}

final class ScreenTranslationCompareView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    var paragraphs: [ScreenTranslationRenderedParagraph] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ScreenTranslationRenderer.drawContent(
            image: image,
            paragraphs: paragraphs,
            showsTranslation: true,
            in: bounds
        )
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.0, dy: 1.0))
        border.lineWidth = 2.0
        border.stroke()
    }
}

@MainActor
final class ScreenTranslationToolbarState: ObservableObject {
    @Published var selectedSourceCode: String?
    @Published var selectedTargetCode: String = "zh-CN"
    @Published var isComparing = false
    @Published var hasTranslation = false

    var onLanguageChanged: (() -> Void)?
    var onToggleCompare: (() -> Void)?
    var onCopyTranslation: (() -> Void)?
    var onExtractText: (() -> Void)?
    var onReselect: (() -> Void)?
    var onPin: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onClose: (() -> Void)?

    var sourceTitle: String {
        ScreenTranslationOverlaySession.sourceLanguages.first(where: { $0.code == selectedSourceCode })?.title ?? "自动检测"
    }

    var targetTitle: String {
        ScreenTranslationOverlaySession.targetLanguages.first(where: { $0.code == selectedTargetCode })?.title ?? "简体中文"
    }

    var canSwap: Bool {
        guard let source = selectedSourceCode else { return false }
        return source != selectedTargetCode && ScreenTranslationOverlaySession.targetLanguages.contains(where: { $0.code == source })
    }

    func swapLanguages() {
        guard let source = selectedSourceCode else { return }
        let target = selectedTargetCode
        guard source != target, ScreenTranslationOverlaySession.targetLanguages.contains(where: { $0.code == source }) else { return }
        selectedSourceCode = target
        selectedTargetCode = source
        onLanguageChanged?()
    }
}

struct ScreenTranslationToolbarView: View {
    @ObservedObject var state: ScreenTranslationToolbarState

    var body: some View {
        HStack(spacing: 8) {
            // 语言选择胶囊容器
            HStack(spacing: 4) {
                Menu {
                    ForEach(ScreenTranslationOverlaySession.sourceLanguages, id: \.title) { option in
                        Button(option.title) {
                            state.selectedSourceCode = option.code
                            state.onLanguageChanged?()
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(state.sourceTitle)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .menuStyle(.borderlessButton)

                Button {
                    state.swapLanguages()
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(state.canSwap ? .white.opacity(0.85) : .white.opacity(0.3))
                        .padding(2)
                }
                .buttonStyle(.plain)
                .disabled(!state.canSwap)

                Menu {
                    ForEach(ScreenTranslationOverlaySession.targetLanguages, id: \.title) { option in
                        Button(option.title) {
                            state.selectedTargetCode = option.code ?? "zh-CN"
                            state.onLanguageChanged?()
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(state.targetTitle)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.12))
            )

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // 动作按钮组
            HStack(spacing: 3) {
                ToolbarIconButton(
                    symbol: "square.split.2x1",
                    tooltip: "对照模式 (原图/译文对照)",
                    isActive: state.isComparing,
                    disabled: !state.hasTranslation,
                    action: { state.onToggleCompare?() }
                )

                ToolbarIconButton(
                    symbol: "doc.on.doc",
                    tooltip: "复制译文",
                    disabled: !state.hasTranslation,
                    action: { state.onCopyTranslation?() }
                )

                ToolbarIconButton(
                    symbol: "doc.plaintext",
                    tooltip: "提取文字",
                    disabled: !state.hasTranslation,
                    action: { state.onExtractText?() }
                )

                ToolbarIconButton(
                    symbol: "viewfinder",
                    tooltip: "重新选区",
                    action: { state.onReselect?() }
                )

                ToolbarIconButton(
                    symbol: "pin",
                    tooltip: "钉住为贴图",
                    disabled: !state.hasTranslation,
                    action: { state.onPin?() }
                )

                ToolbarIconButton(
                    symbol: "arrow.clockwise",
                    tooltip: "刷新（重新识别）",
                    action: { state.onRefresh?() }
                )
            }

            Divider()
                .frame(height: 14)
                .opacity(0.3)

            // 关闭按钮
            ToolbarIconButton(
                symbol: "xmark",
                tooltip: "关闭 (Esc)",
                action: { state.onClose?() }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                .background(.ultraThinMaterial, in: Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
        .preferredColorScheme(.dark)
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let tooltip: String
    var isActive: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isActive ? Color.accentColor : (disabled ? Color.white.opacity(0.3) : Color.white.opacity(0.88)))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.25) : (isHovered ? Color.white.opacity(0.12) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(tooltip)
        .onHover { isHovered = $0 }
    }
}

@MainActor
final class ScreenTranslationOverlaySession {
    struct LanguageOption {
        let code: String?
        let title: String
    }

    static let sourceLanguages: [LanguageOption] = [
        LanguageOption(code: nil, title: "自动检测"),
        LanguageOption(code: "zh-CN", title: "简体中文"),
        LanguageOption(code: "en", title: "英语"),
        LanguageOption(code: "ja", title: "日语"),
        LanguageOption(code: "ko", title: "韩语"),
    ]

    static let targetLanguages: [LanguageOption] = [
        LanguageOption(code: "zh-CN", title: "简体中文"),
        LanguageOption(code: "en", title: "英语"),
        LanguageOption(code: "ja", title: "日语"),
        LanguageOption(code: "ko", title: "韩语"),
    ]

    let panel: ScreenTranslationOverlayPanel
    private let toolbarPanel: NSPanel
    private let comparePanel: NSPanel
    private let compareView = ScreenTranslationCompareView(frame: .zero)
    private let overlayView: ScreenTranslationOverlayView
    private let progressIndicator = NSProgressIndicator()
    private let toolbarState = ScreenTranslationToolbarState()
    private let screenBounds: CGRect
    private(set) var region: CGRect
    private var dragStartRegion: CGRect?
    private var sourceText = ""
    private var translatedText = ""
    private var hasTranslation = false
    private var keyMonitor: Any?

    var onRegionChanged: ((CGRect) -> Void)?
    var liveCropProvider: ((CGRect) -> NSImage?)?
    var onLanguageChanged: ((String?, String) -> Void)?
    var onExtractText: (() -> Void)?
    var onReselect: (() -> Void)?
    var onPin: ((NSImage, CGRect) -> Void)?
    var onRefresh: (() -> Void)?
    var onClosed: (() -> Void)?

    init(image: NSImage, region: CGRect, screenBounds: CGRect) {
        self.region = region.standardized
        self.screenBounds = screenBounds
        overlayView = ScreenTranslationOverlayView(frame: .zero)
        overlayView.image = image

        panel = ScreenTranslationOverlayPanel(
            contentRect: Self.panelFrame(for: region),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = overlayView

        toolbarPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toolbarPanel.level = .floating
        toolbarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toolbarPanel.isReleasedWhenClosed = false
        toolbarPanel.hidesOnDeactivate = false
        toolbarPanel.backgroundColor = .clear
        toolbarPanel.isOpaque = false
        toolbarPanel.hasShadow = false
        toolbarPanel.contentView = NSHostingView(rootView: ScreenTranslationToolbarView(state: toolbarState))

        comparePanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        comparePanel.level = .floating
        comparePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        comparePanel.isReleasedWhenClosed = false
        comparePanel.hidesOnDeactivate = false
        comparePanel.backgroundColor = .clear
        comparePanel.isOpaque = false
        comparePanel.hasShadow = true
        comparePanel.contentView = compareView

        configureProgressIndicator()
        configureToolbarCallbacks()
        configureDragHandling()
        configureKeyHandling()
    }

    private func configureToolbarCallbacks() {
        toolbarState.onLanguageChanged = { [weak self] in
            guard let self else { return }
            self.onLanguageChanged?(self.toolbarState.selectedSourceCode, self.toolbarState.selectedTargetCode)
        }
        toolbarState.onToggleCompare = { [weak self] in
            self?.toggleCompare()
        }
        toolbarState.onCopyTranslation = { [weak self] in
            self?.copyTranslation()
        }
        toolbarState.onExtractText = { [weak self] in
            self?.extractText()
        }
        toolbarState.onReselect = { [weak self] in
            self?.reselect()
        }
        toolbarState.onPin = { [weak self] in
            self?.pinResult()
        }
        toolbarState.onRefresh = { [weak self] in
            self?.refresh()
        }
        toolbarState.onClose = { [weak self] in
            self?.closeFromToolbar()
        }
    }

    func present() {
        positionToolbar()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }

    func setLanguages(source: String?, target: String) {
        toolbarState.selectedSourceCode = source
        toolbarState.selectedTargetCode = target
    }

    func beginLoading() {
        toolbarState.hasTranslation = false
        overlayView.paragraphs = []
        overlayView.showsTranslation = false
        comparePanel.orderOut(nil)
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
    }

    func showPlainImage(_ image: NSImage) {
        overlayView.image = image
        overlayView.paragraphs = []
        overlayView.showsTranslation = false
        comparePanel.orderOut(nil)
    }

    func showTranslation(
        _ paragraphs: [ScreenTranslationRenderedParagraph],
        image: NSImage,
        sourceText: String,
        translatedText: String
    ) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        toolbarState.hasTranslation = true
        overlayView.image = image
        overlayView.paragraphs = paragraphs
        compareView.image = image
        compareView.paragraphs = paragraphs
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        updatePresentation()
    }

    func hideForRecapture() {
        panel.orderOut(nil)
        toolbarPanel.orderOut(nil)
        comparePanel.orderOut(nil)
    }

    func showAfterRecapture() {
        panel.orderFrontRegardless()
        toolbarPanel.orderFrontRegardless()
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        progressIndicator.stopAnimation(nil)
        comparePanel.orderOut(nil)
        toolbarPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    private static func panelFrame(for region: CGRect) -> CGRect {
        region.standardized.insetBy(
            dx: -ScreenTranslationOverlayView.contentMargin,
            dy: -ScreenTranslationOverlayView.contentMargin
        )
    }

    private func configureProgressIndicator() {
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(progressIndicator)
        NSLayoutConstraint.activate([
            progressIndicator.trailingAnchor.constraint(
                equalTo: overlayView.trailingAnchor,
                constant: -(ScreenTranslationOverlayView.contentMargin + 6)
            ),
            progressIndicator.topAnchor.constraint(
                equalTo: overlayView.topAnchor,
                constant: ScreenTranslationOverlayView.contentMargin + 6
            ),
        ])
        progressIndicator.startAnimation(nil)
    }

    private func configureDragHandling() {
        overlayView.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStartRegion = region
        }
        overlayView.onDragChanged = { [weak self] zone, delta in
            guard let self, let dragStartRegion else {
                return
            }
            let updated = Self.adjustedRegion(
                from: dragStartRegion,
                zone: zone,
                delta: delta,
                bounds: screenBounds
            )
            apply(region: updated)
            if let preview = liveCropProvider?(updated) {
                showPlainImage(preview)
            }
        }
        overlayView.onDragEnded = { [weak self] in
            guard let self, dragStartRegion != nil else { return }
            let startRegion = dragStartRegion
            self.dragStartRegion = nil
            guard startRegion != region else {
                updatePresentation()
                return
            }
            onRegionChanged?(region)
        }
    }

    private func configureKeyHandling() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, panel.isKeyWindow, event.keyCode == 53 else {
                return event
            }
            requestClose()
            return nil
        }
    }

    private static func adjustedRegion(
        from start: CGRect,
        zone: ScreenTranslationDragZone,
        delta: CGSize,
        bounds: CGRect
    ) -> CGRect {
        let minimumSize = CGSize(width: 48, height: 28)
        var region = start
        switch zone {
        case .move:
            region.origin.x += delta.width
            region.origin.y += delta.height
            region.origin.x = min(
                max(region.origin.x, bounds.minX),
                bounds.maxX - region.width
            )
            region.origin.y = min(
                max(region.origin.y, bounds.minY),
                bounds.maxY - region.height
            )
        case let .resize(top, bottom, left, right):
            var minX = start.minX
            var maxX = start.maxX
            var minY = start.minY
            var maxY = start.maxY
            if left { minX = min(start.minX + delta.width, maxX - minimumSize.width) }
            if right { maxX = max(start.maxX + delta.width, minX + minimumSize.width) }
            if bottom { minY = min(start.minY + delta.height, maxY - minimumSize.height) }
            if top { maxY = max(start.maxY + delta.height, minY + minimumSize.height) }
            region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            region = region.intersection(bounds)
            if region.width < minimumSize.width || region.height < minimumSize.height {
                region = CGRect(
                    x: min(max(region.minX, bounds.minX), bounds.maxX - minimumSize.width),
                    y: min(max(region.minY, bounds.minY), bounds.maxY - minimumSize.height),
                    width: max(region.width, minimumSize.width),
                    height: max(region.height, minimumSize.height)
                )
            }
        }
        return region
    }

    private func apply(region: CGRect) {
        self.region = region
        panel.setFrame(Self.panelFrame(for: region), display: true)
        positionToolbar()
    }

    private func positionToolbar() {
        let gap: CGFloat = 8
        let visibleFrame = targetScreen()?.visibleFrame ?? screenBounds
        let toolbarSize = toolbarPanel.contentView?.fittingSize ?? CGSize(width: 420, height: 42)
        var origin = CGPoint(
            x: region.midX - (toolbarSize.width / 2),
            y: region.minY - toolbarSize.height - gap
        )
        if origin.y < visibleFrame.minY {
            origin.y = region.maxY + gap
        }
        origin.x = max(visibleFrame.minX + gap, min(origin.x, visibleFrame.maxX - toolbarSize.width - gap))
        toolbarPanel.setFrame(CGRect(origin: origin, size: toolbarSize), display: true)
    }

    private func targetScreen() -> NSScreen? {
        let center = CGPoint(x: screenBounds.midX, y: screenBounds.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(screenBounds) })
    }

    private func requestClose() {
        close()
        onClosed?()
    }

    private func toggleCompare() {
        toolbarState.isComparing.toggle()
        updatePresentation()
    }

    private func updatePresentation() {
        guard toolbarState.hasTranslation else {
            overlayView.showsTranslation = false
            comparePanel.orderOut(nil)
            return
        }
        overlayView.showsTranslation = !toolbarState.isComparing
        if toolbarState.isComparing {
            positionComparePanel()
            comparePanel.orderFrontRegardless()
        } else {
            comparePanel.orderOut(nil)
        }
    }

    private func positionComparePanel() {
        let gap: CGFloat = 8
        let visibleFrame = targetScreen()?.visibleFrame ?? screenBounds
        var origin = CGPoint(x: region.minX, y: region.maxY + gap)
        if origin.y + region.height > visibleFrame.maxY {
            let toolbarBottom = toolbarPanel.isVisible
                ? min(region.minY, toolbarPanel.frame.minY)
                : region.minY
            origin.y = max(visibleFrame.minY, toolbarBottom - gap - region.height)
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX),
            max(visibleFrame.minX, visibleFrame.maxX - region.width)
        )
        comparePanel.setFrame(
            CGRect(origin: origin, size: region.size),
            display: true
        )
    }

    private func copyTranslation() {
        copyToPasteboard(translatedText)
    }

    private func extractText() {
        onExtractText?()
    }

    private func reselect() {
        close()
        onReselect?()
    }

    private func pinResult() {
        guard toolbarState.hasTranslation,
              let exported = ScreenTranslationRenderer.exportImage(
                  image: overlayView.image,
                  paragraphs: overlayView.paragraphs,
                  showsTranslation: true,
                  size: region.size,
                  scale: panel.backingScaleFactor
              ) else {
            return
        }
        onPin?(exported, region)
    }

    private func refresh() {
        onRefresh?()
    }

    private func closeFromToolbar() {
        requestClose()
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
