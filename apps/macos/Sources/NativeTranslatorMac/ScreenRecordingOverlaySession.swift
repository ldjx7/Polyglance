import AppKit

enum ScreenRecordingOverlayAction: Equatable {
    case start
    case pauseOrResume
    case stop
    case close
}

@MainActor
final class ScreenRecordingToolbarButton: NSButton {
    var onHoverChanged: ((ScreenRecordingToolbarButton, Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

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
        onHoverChanged?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(self, false)
    }
}

@MainActor
final class ScreenRecordingToolbarHelpBubble: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class ScreenRecordingToolbarView: NSView {
    let statusLabel = NSTextField(labelWithString: "待录制")
    let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let qualityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let frameRatePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let delayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var systemAudioButton: NSButton!
    private(set) var microphoneButton: NSButton!
    private(set) var cursorButton: NSButton!
    private(set) var startButton: NSButton!
    private(set) var pauseResumeButton: NSButton!
    private(set) var stopButton: NSButton!
    private(set) var closeButton: NSButton!
    private(set) var helpBubble: ScreenRecordingToolbarHelpBubble!

    var onAction: ((ScreenRecordingOverlayAction) -> Void)?
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    private(set) var settings: RecordingSettings
    private var helpLabel: NSTextField!
    private weak var hoveredButton: NSButton?

    var visibleHelpText: String? {
        guard helpBubble.isHidden == false else { return nil }
        return helpLabel.stringValue
    }

    init(settings: RecordingSettings) {
        self.settings = settings
        super.init(frame: CGRect(x: 0, y: 0, width: 720, height: 80))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        configurePopUps()
        systemAudioButton = makeIconButton(
            title: "录制系统声音",
            symbol: "speaker.wave.2.fill",
            action: #selector(toggleSystemAudio)
        )
        systemAudioButton.setButtonType(.toggle)
        microphoneButton = makeIconButton(
            title: "录制麦克风",
            symbol: "mic.fill",
            action: #selector(toggleMicrophone)
        )
        microphoneButton.setButtonType(.toggle)
        cursorButton = makeIconButton(
            title: "显示鼠标指针",
            symbol: "cursorarrow",
            action: #selector(toggleCursor)
        )
        cursorButton.setButtonType(.toggle)
        startButton = makeIconButton(
            title: "开始录制",
            symbol: "record.circle",
            action: #selector(startRecording)
        )
        pauseResumeButton = makeIconButton(
            title: "暂停录制",
            symbol: "pause.fill",
            action: #selector(pauseOrResume)
        )
        stopButton = makeIconButton(
            title: "停止并预览",
            symbol: "stop.fill",
            action: #selector(stopRecording)
        )
        closeButton = makeIconButton(
            title: "关闭录屏",
            symbol: "xmark",
            action: #selector(closeRecording)
        )

        let controls = NSStackView(views: [
            statusLabel,
            formatPopUp,
            qualityPopUp,
            frameRatePopUp,
            delayPopUp,
            systemAudioButton,
            microphoneButton,
            cursorButton,
            startButton,
            pauseResumeButton,
            stopButton,
            closeButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 7
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        helpBubble = ScreenRecordingToolbarHelpBubble(frame: .zero)
        helpBubble.wantsLayer = true
        helpBubble.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        helpBubble.layer?.cornerRadius = 7
        helpBubble.isHidden = true
        helpLabel = NSTextField(labelWithString: "")
        helpLabel.font = .systemFont(ofSize: 11, weight: .medium)
        helpLabel.textColor = .white
        helpLabel.alignment = .center
        helpBubble.addSubview(helpLabel)
        addSubview(helpBubble, positioned: .above, relativeTo: controls)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            formatPopUp.widthAnchor.constraint(equalToConstant: 68),
            qualityPopUp.widthAnchor.constraint(equalToConstant: 78),
            frameRatePopUp.widthAnchor.constraint(equalToConstant: 76),
            delayPopUp.widthAnchor.constraint(equalToConstant: 70),
        ])
        updateSelectionsFromSettings()
        update(state: .ready)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: ScreenRecordingSessionState) {
        hideHelp()
        let isReady = state == .ready
        formatPopUp.isEnabled = isReady
        qualityPopUp.isEnabled = isReady
        frameRatePopUp.isEnabled = isReady
        delayPopUp.isEnabled = isReady
        systemAudioButton.isEnabled = isReady && settings.format.supportsAudio
        microphoneButton.isEnabled = isReady && settings.format.supportsAudio
        cursorButton.isEnabled = isReady
        startButton.isEnabled = isReady
        pauseResumeButton.isEnabled = state == .recording || state == .paused
        stopButton.isEnabled = state == .recording || state == .paused
        closeButton.isEnabled = state != .finalizing && state != .starting
        switch state {
        case .idle:
            statusLabel.stringValue = "已关闭"
        case .ready:
            statusLabel.stringValue = "待录制"
        case let .countingDown(remaining):
            statusLabel.stringValue = "\(remaining)"
        case .starting:
            statusLabel.stringValue = "启动中"
        case .recording:
            statusLabel.stringValue = "● 录制中"
            statusLabel.textColor = .systemRed
        case .paused:
            statusLabel.stringValue = "Ⅱ 暂停"
            statusLabel.textColor = .systemOrange
        case .finalizing:
            statusLabel.stringValue = "生成中"
        case .reviewing:
            statusLabel.stringValue = "预览"
        }
        if state != .recording && state != .paused {
            statusLabel.textColor = .labelColor
        }
        let isPaused = state == .paused
        pauseResumeButton.toolTip = isPaused ? "继续录制" : "暂停录制"
        pauseResumeButton.setAccessibilityLabel(isPaused ? "继续录制" : "暂停录制")
        pauseResumeButton.image = symbol(isPaused ? "play.fill" : "pause.fill")
    }

    func update(settings: RecordingSettings) {
        self.settings = settings
        updateSelectionsFromSettings()
    }

    @objc func applyCurrentSettingsSelection() {
        guard formatPopUp.indexOfSelectedItem >= 0,
              qualityPopUp.indexOfSelectedItem >= 0,
              frameRatePopUp.indexOfSelectedItem >= 0,
              delayPopUp.indexOfSelectedItem >= 0 else {
            return
        }
        settings.format = ScreenRecordingFormat.allCases[formatPopUp.indexOfSelectedItem]
        settings.quality = ScreenRecordingQuality.allCases[qualityPopUp.indexOfSelectedItem]
        settings.frameRate = ScreenRecordingFrameRatePolicy.normalized(
            frameRatePopUp.selectedTag(),
            for: settings.format
        )
        rebuildFrameRateItems()
        selectFrameRate(settings.frameRate)
        settings.countdownDelay = ScreenRecordingDelay.allCases[delayPopUp.indexOfSelectedItem]
        rebuildQualityTitles()
        systemAudioButton.isEnabled = settings.format.supportsAudio
        microphoneButton.isEnabled = settings.format.supportsAudio
        updateTogglePresentation()
        onSettingsChanged?(settings)
    }

    private func configurePopUps() {
        formatPopUp.addItems(withTitles: ScreenRecordingFormat.allCases.map(\.displayName))
        qualityPopUp.addItems(withTitles: ScreenRecordingQuality.allCases.map(\.displayName))
        rebuildFrameRateItems()
        delayPopUp.addItems(withTitles: ScreenRecordingDelay.allCases.map(\.displayName))
        for popUp in [formatPopUp, qualityPopUp, frameRatePopUp, delayPopUp] {
            popUp.controlSize = .small
            popUp.target = self
            popUp.action = #selector(applyCurrentSettingsSelection)
        }
        formatPopUp.toolTip = "输出格式"
        qualityPopUp.toolTip = "录制帧率与质量"
        frameRatePopUp.toolTip = "录制帧率"
        delayPopUp.toolTip = "开始录制前的倒计时"
    }

    private func updateSelectionsFromSettings() {
        formatPopUp.selectItem(at: ScreenRecordingFormat.allCases.firstIndex(of: settings.format) ?? 0)
        qualityPopUp.selectItem(at: ScreenRecordingQuality.allCases.firstIndex(of: settings.quality) ?? 1)
        rebuildFrameRateItems()
        selectFrameRate(settings.frameRate)
        delayPopUp.selectItem(at: ScreenRecordingDelay.allCases.firstIndex(of: settings.countdownDelay) ?? 1)
        rebuildQualityTitles()
        updateTogglePresentation()
    }

    private func rebuildQualityTitles() {
        let selectedIndex = ScreenRecordingQuality.allCases.firstIndex(of: settings.quality) ?? 1
        qualityPopUp.removeAllItems()
        qualityPopUp.addItems(withTitles: ScreenRecordingQuality.allCases.map(\.displayName))
        qualityPopUp.selectItem(at: selectedIndex)
    }

    private func rebuildFrameRateItems() {
        frameRatePopUp.removeAllItems()
        for choice in ScreenRecordingFrameRatePolicy.choices(for: settings.format) {
            frameRatePopUp.addItem(withTitle: "\(choice) FPS")
            frameRatePopUp.lastItem?.tag = choice
        }
    }

    private func selectFrameRate(_ frameRate: Int) {
        if !frameRatePopUp.itemArray.contains(where: { $0.tag == frameRate }) {
            frameRatePopUp.addItem(withTitle: "\(frameRate) FPS")
            frameRatePopUp.lastItem?.tag = frameRate
        }
        frameRatePopUp.selectItem(withTag: frameRate)
    }

    private func updateTogglePresentation() {
        systemAudioButton.state = settings.capturesSystemAudio ? .on : .off
        microphoneButton.state = settings.capturesMicrophone ? .on : .off
        cursorButton.state = settings.showsCursor ? .on : .off
        systemAudioButton.contentTintColor = settings.capturesSystemAudio ? .controlAccentColor : .secondaryLabelColor
        microphoneButton.contentTintColor = settings.capturesMicrophone ? .controlAccentColor : .secondaryLabelColor
        cursorButton.contentTintColor = settings.showsCursor ? .controlAccentColor : .secondaryLabelColor
    }

    private func makeIconButton(title: String, symbol symbolName: String, action: Selector) -> NSButton {
        let button = ScreenRecordingToolbarButton(title: title, target: self, action: action)
        button.bezelStyle = .toolbar
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .large
        button.image = symbol(symbolName)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(title)
        button.onHoverChanged = { [weak self] button, hovering in
            hovering ? self?.showHelp(for: button) : self?.hideHelp(for: button)
        }
        return button
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        )
    }

    private func showHelp(for button: NSButton) {
        guard let text = button.toolTip, !text.isEmpty else { return }
        hoveredButton = button
        helpLabel.stringValue = text
        let textWidth = text.size(withAttributes: [.font: helpLabel.font as Any]).width
        let width = min(max(88, textWidth + 18), bounds.width - 16)
        let buttonFrame = button.convert(button.bounds, to: self)
        let x = min(max(8, buttonFrame.midX - width / 2), bounds.width - width - 8)
        helpBubble.frame = CGRect(x: x, y: 48, width: width, height: 26)
        helpLabel.frame = helpBubble.bounds.insetBy(dx: 7, dy: 4)
        helpBubble.isHidden = false
    }

    private func hideHelp(for button: NSButton? = nil) {
        if let button, hoveredButton !== button { return }
        hoveredButton = nil
        helpBubble.isHidden = true
        helpLabel.stringValue = ""
    }

    @objc private func toggleSystemAudio() {
        settings.capturesSystemAudio.toggle()
        updateTogglePresentation()
        onSettingsChanged?(settings)
    }

    @objc private func toggleMicrophone() {
        settings.capturesMicrophone.toggle()
        updateTogglePresentation()
        onSettingsChanged?(settings)
    }

    @objc private func toggleCursor() {
        settings.showsCursor.toggle()
        updateTogglePresentation()
        onSettingsChanged?(settings)
    }

    @objc private func startRecording() { onAction?(.start) }
    @objc private func pauseOrResume() { onAction?(.pauseOrResume) }
    @objc private func stopRecording() { onAction?(.stop) }
    @objc private func closeRecording() { onAction?(.close) }
}

@MainActor
final class ScreenRecordingRegionView: NSView {
    var onRegionChanged: ((CGRect) -> Void)?
    var screenBounds: CGRect = .zero
    var isEditable = true
    var borderColor: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }
    private var editTarget: ScreenRecordingRegionEditTarget?
    private var originalRegion: CGRect = .zero
    private var dragStart: CGPoint = .zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        borderColor.withAlphaComponent(0.96).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 4
        path.stroke()
        guard isEditable else { return }
        borderColor.setFill()
        for point in handleCenters {
            NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable, let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        editTarget = ScreenRecordingRegionGeometry.editTarget(at: local, in: bounds)
        originalRegion = window.frame
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable, let editTarget else { return }
        onRegionChanged?(ScreenRecordingRegionGeometry.edited(
            originalRegion,
            target: editTarget,
            dragStart: dragStart,
            current: NSEvent.mouseLocation,
            screenBounds: screenBounds
        ))
    }

    override func mouseUp(with event: NSEvent) {
        editTarget = nil
    }

    override func mouseMoved(with event: NSEvent) {
        guard isEditable else {
            NSCursor.arrow.set()
            return
        }
        let target = ScreenRecordingRegionGeometry.editTarget(
            at: convert(event.locationInWindow, from: nil),
            in: bounds
        )
        switch target {
        case .move:
            NSCursor.openHand.set()
        case .left, .right:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight:
            NSCursor.closedHand.set()
        case .topRight, .bottomLeft:
            NSCursor.crosshair.set()
        }
    }

    private var handleCenters: [CGPoint] {
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
}

@MainActor
final class ScreenRecordingRegionPanel: NSPanel {
    let regionView: ScreenRecordingRegionView

    init(region: CGRect, screenBounds: CGRect) {
        regionView = ScreenRecordingRegionView(frame: CGRect(origin: .zero, size: region.size))
        regionView.screenBounds = screenBounds
        super.init(
            contentRect: region,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = regionView
    }
}

@MainActor
final class ScreenRecordingToolbarPanel: NSPanel {
    let toolbarView: ScreenRecordingToolbarView

    init(settings: RecordingSettings) {
        toolbarView = ScreenRecordingToolbarView(settings: settings)
        super.init(
            contentRect: toolbarView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = toolbarView
    }

    func position(near region: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let proposedBelow = region.minY - frame.height - 8
        let y = proposedBelow >= visible.minY + 8
            ? proposedBelow
            : min(region.maxY + 8, visible.maxY - frame.height - 8)
        let x = min(
            max(region.midX - frame.width / 2, visible.minX + 8),
            visible.maxX - frame.width - 8
        )
        setFrameOrigin(CGPoint(x: x, y: y))
    }
}

@MainActor
final class ScreenRecordingOverlaySession {
    private(set) var state: ScreenRecordingSessionState = .ready
    private(set) var region: CGRect
    private(set) var settings: RecordingSettings
    let screen: NSScreen
    let regionPanel: ScreenRecordingRegionPanel
    let toolbarPanel: ScreenRecordingToolbarPanel

    var onAction: ((ScreenRecordingOverlayAction) -> Void)?
    var onSettingsChanged: ((RecordingSettings) -> Void)?
    var onRegionChanged: ((CGRect) -> Void)?

    var toolbarView: ScreenRecordingToolbarView { toolbarPanel.toolbarView }
    var isRegionEditable: Bool { regionPanel.regionView.isEditable }
    var borderColor: NSColor { regionPanel.regionView.borderColor }

    init(region: CGRect, screen: NSScreen, settings: RecordingSettings) {
        let clipped = region.standardized.intersection(screen.frame.standardized)
        self.region = clipped.isNull || clipped.isEmpty ? screen.frame.insetBy(dx: 80, dy: 80) : clipped
        self.screen = screen
        self.settings = settings
        regionPanel = ScreenRecordingRegionPanel(region: self.region, screenBounds: screen.frame)
        toolbarPanel = ScreenRecordingToolbarPanel(settings: settings)

        regionPanel.regionView.onRegionChanged = { [weak self] region in
            self?.setRegion(region)
        }
        toolbarPanel.toolbarView.onAction = { [weak self] action in
            self?.onAction?(action)
        }
        toolbarPanel.toolbarView.onSettingsChanged = { [weak self] settings in
            guard let self else { return }
            self.settings = settings
            self.onSettingsChanged?(settings)
        }
    }

    func present() {
        regionPanel.orderFrontRegardless()
        toolbarPanel.position(near: region, on: screen)
        toolbarPanel.orderFrontRegardless()
    }

    func update(state: ScreenRecordingSessionState) {
        self.state = state
        let editable = state == .ready
        regionPanel.regionView.isEditable = editable
        regionPanel.ignoresMouseEvents = !editable
        switch state {
        case .ready, .countingDown, .starting:
            regionPanel.regionView.borderColor = .systemBlue
        case .recording:
            regionPanel.regionView.borderColor = .systemRed
        case .paused:
            regionPanel.regionView.borderColor = .systemOrange
        case .finalizing:
            regionPanel.regionView.borderColor = .secondaryLabelColor
        case .idle, .reviewing:
            break
        }
        regionPanel.regionView.needsDisplay = true
        toolbarView.update(state: state)
    }

    func update(settings: RecordingSettings) {
        self.settings = settings
        toolbarView.update(settings: settings)
    }

    func hideForReview() {
        regionPanel.orderOut(nil)
        toolbarPanel.orderOut(nil)
    }

    func restoreReady() {
        update(state: .ready)
        present()
    }

    func close() {
        regionPanel.orderOut(nil)
        toolbarPanel.orderOut(nil)
    }

    private func setRegion(_ newRegion: CGRect) {
        region = newRegion.standardized.intersection(screen.frame)
        regionPanel.setFrame(region, display: true)
        toolbarPanel.position(near: region, on: screen)
        onRegionChanged?(region)
    }
}
