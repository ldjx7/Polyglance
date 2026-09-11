import AppKit
import Foundation
import NaturalLanguage
import PolyglanceKit

@MainActor
final class OCRWorkspacePanel: NSPanel {
    static weak var activeContinuousInstance: OCRWorkspacePanel?

    private var sourceImage: NSImage
    private var document: OCRDocument?
    private var rawText: String = ""
    private var currentMode: TextFormattingMode = .smartMerge
    private var isContinuous: Bool = false
    private let configurationStore: AppConfigurationStore?
    private let translateHandler: (String) -> Void

    // UI elements
    private let copyAllButton = NSButton()
    private let translateButton = NSButton()
    private let formattingButton = NSPopUpButton()
    private let continuousButton = NSButton()
    private let showImageCheckbox = NSButton()
    private let textView = NSTextView()
    private let textScrollView = NSScrollView()
    private let previewContainer = NSView()
    private let interactiveImageView = OCRInteractiveImageView()
    private let autoCopyCheckbox = NSButton()
    private let statsLabel = NSTextField(labelWithString: "")
    private let engineLabel = NSTextField(labelWithString: "")
    private let pinButton = NSButton()
    private var isPinned: Bool = true

    // Loading Overlay
    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "正在识别中...")

    // Multi-image paging overlay
    private let pagingOverlay = NSStackView()
    private let prevPageButton = NSButton()
    private let pageLabel = NSTextField(labelWithString: "1 / 1")
    private let nextPageButton = NSButton()

    // Image history
    private var previewImages: [NSImage] = []
    private var currentImageIndex: Int = 0

    private var previewHeightConstraint: NSLayoutConstraint?

    init(
        image: NSImage,
        document: OCRDocument? = nil,
        configurationStore: AppConfigurationStore? = nil,
        translateHandler: @escaping (String) -> Void = { _ in }
    ) {
        self.sourceImage = image
        self.document = document
        self.rawText = document?.plainText ?? ""
        self.configurationStore = configurationStore
        self.translateHandler = translateHandler

        let contentRect = CGRect(x: 100, y: 100, width: 640, height: 480)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        title = "Polyglance 文字识别"
        titleVisibility = .visible
        titlebarAppearsTransparent = false
        hidesOnDeactivate = false
        minSize = CGSize(width: 480, height: 360)
        isReleasedWhenClosed = false
        isFloatingPanel = true

        if let config = try? configurationStore?.load() {
            currentMode = TextFormattingMode(rawValue: config.ocrDefaultFormatting) ?? .smartMerge
            autoCopyCheckbox.state = config.ocrAutoCopyNextTime ? .on : .off
        }

        setupTitlebarAccessory()
        setupUI()
        updatePinButtonState()
        updateFormattingMenuSelection()
        if let doc = document {
            loadDocument(image: image, document: doc)
        } else {
            loadInitialImage(image: image)
        }
    }

    private func setupTitlebarAccessory() {
        let titlebarAccessory = NSTitlebarAccessoryViewController()
        titlebarAccessory.layoutAttribute = .trailing

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.imagePosition = .imageOnly
        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.target = self
        pinButton.action = #selector(pinToggled)

        let pinContainer = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
        pinContainer.addSubview(pinButton)
        NSLayoutConstraint.activate([
            pinButton.centerXAnchor.constraint(equalTo: pinContainer.centerXAnchor),
            pinButton.centerYAnchor.constraint(equalTo: pinContainer.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
        ])

        titlebarAccessory.view = pinContainer
        addTitlebarAccessoryViewController(titlebarAccessory)
    }

    func startPendingAppend(image: NSImage) {
        sourceImage = image
        previewImages.append(image)
        currentImageIndex = previewImages.count - 1
        interactiveImageView.image = image
        updatePagingUI()
        statsLabel.stringValue = "正在识别追加内容..."
    }

    func finishPendingAppend(image: NSImage, document: OCRDocument) {
        self.sourceImage = image
        self.document = document
        interactiveImageView.image = image
        updatePagingUI()

        let lines = document.lines.map { (text: $0.text, boundingBox: $0.boundingBox) }
        let newFormatted = TextFormattingService.format(lines: lines, mode: currentMode)
        let currentText = textView.string
        if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textView.string = newFormatted
            rawText = document.plainText
        } else {
            textView.string = currentText + "\n\n" + newFormatted
            rawText += "\n\n" + document.plainText
        }

        updateStats()
        textView.scrollToEndOfDocument(nil)
    }

    func cancelPendingAppend(error: Error) {
        statsLabel.stringValue = "追加识别失败"
    }

    func append(image: NSImage, document: OCRDocument) {
        finishPendingAppend(image: image, document: document)
    }

    private func setupUI() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentView = root

        // --- Toolbar ---
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        copyAllButton.title = "复制全部"
        copyAllButton.bezelStyle = .rounded
        copyAllButton.keyEquivalent = "\r"
        copyAllButton.target = self
        copyAllButton.action = #selector(copyAllAction)
        toolbar.addArrangedSubview(copyAllButton)

        translateButton.title = "翻译"
        translateButton.bezelStyle = .rounded
        translateButton.target = self
        translateButton.action = #selector(translateAction)
        toolbar.addArrangedSubview(translateButton)

        formattingButton.pullsDown = true
        formattingButton.bezelStyle = .rounded
        formattingButton.addItem(withTitle: "排版设置 ▾")
        for mode in TextFormattingMode.allCases {
            formattingButton.addItem(withTitle: mode.title)
        }
        formattingButton.target = self
        formattingButton.action = #selector(formattingChanged)
        toolbar.addArrangedSubview(formattingButton)

        continuousButton.setButtonType(.pushOnPushOff)
        continuousButton.title = "连续识别"
        continuousButton.bezelStyle = .rounded
        continuousButton.target = self
        continuousButton.action = #selector(continuousToggled)
        toolbar.addArrangedSubview(continuousButton)

        showImageCheckbox.setButtonType(.switch)
        showImageCheckbox.title = "显示原始图片"
        showImageCheckbox.state = .on
        showImageCheckbox.target = self
        showImageCheckbox.action = #selector(showImageToggled)
        toolbar.addArrangedSubview(showImageCheckbox)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)

        root.addSubview(toolbar)

        // --- Bounded Image Viewport (Does not expand on zoom) ---
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor(calibratedRed: 245/255.0, green: 245/255.0, blue: 247/255.0, alpha: 1.0).cgColor
        previewContainer.layer?.borderColor = NSColor(calibratedRed: 229/255.0, green: 231/255.0, blue: 235/255.0, alpha: 1.0).cgColor
        previewContainer.layer?.borderWidth = 1.0
        previewContainer.layer?.cornerRadius = 6
        previewContainer.layer?.masksToBounds = true
        previewContainer.isHidden = false

        interactiveImageView.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(interactiveImageView)

        // --- Paging Overlay ---
        pagingOverlay.orientation = .horizontal
        pagingOverlay.alignment = .centerY
        pagingOverlay.spacing = 6
        pagingOverlay.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        pagingOverlay.wantsLayer = true
        pagingOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        pagingOverlay.layer?.cornerRadius = 12
        pagingOverlay.layer?.masksToBounds = true
        pagingOverlay.translatesAutoresizingMaskIntoConstraints = false
        pagingOverlay.isHidden = true

        prevPageButton.title = "◀"
        prevPageButton.bezelStyle = .inline
        prevPageButton.isBordered = false
        prevPageButton.target = self
        prevPageButton.action = #selector(prevImageAction)
        pagingOverlay.addArrangedSubview(prevPageButton)

        pageLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        pageLabel.textColor = .white
        pagingOverlay.addArrangedSubview(pageLabel)

        nextPageButton.title = "▶"
        nextPageButton.bezelStyle = .inline
        nextPageButton.isBordered = false
        nextPageButton.target = self
        nextPageButton.action = #selector(nextImageAction)
        pagingOverlay.addArrangedSubview(nextPageButton)

        previewContainer.addSubview(pagingOverlay)
        root.addSubview(previewContainer)

        // --- Text Editor ---
        textScrollView.translatesAutoresizingMaskIntoConstraints = false
        textScrollView.hasVerticalScroller = true
        textScrollView.hasHorizontalScroller = false
        textScrollView.borderType = .noBorder

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainer?.containerSize = CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.delegate = self
        textScrollView.documentView = textView

        root.addSubview(textScrollView)

        // --- Bottom Bar ---
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 16
        bottomBar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        autoCopyCheckbox.setButtonType(.switch)
        autoCopyCheckbox.title = "下次直接复制文本"
        autoCopyCheckbox.target = self
        autoCopyCheckbox.action = #selector(autoCopyToggled)
        bottomBar.addArrangedSubview(autoCopyCheckbox)

        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomBar.addArrangedSubview(bottomSpacer)

        statsLabel.font = NSFont.systemFont(ofSize: 12)
        statsLabel.textColor = .secondaryLabelColor
        bottomBar.addArrangedSubview(statsLabel)

        engineLabel.font = NSFont.systemFont(ofSize: 12)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.stringValue = "引擎: Apple Vision (系统原生) | 语言: 自动检测"
        bottomBar.addArrangedSubview(engineLabel)

        root.addSubview(bottomBar)

        // --- Loading Overlay Setup ---
        loadingOverlay.wantsLayer = true
        loadingOverlay.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.85).cgColor
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.isHidden = true
        root.addSubview(loadingOverlay)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        // --- Layout Constraints ---
        let previewHeight = previewContainer.heightAnchor.constraint(equalToConstant: 180)
        self.previewHeightConstraint = previewHeight

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),

            previewContainer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            previewContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            previewHeight,

            interactiveImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            interactiveImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            interactiveImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            interactiveImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),

            pagingOverlay.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: -8),
            pagingOverlay.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            pagingOverlay.heightAnchor.constraint(equalToConstant: 24),

            textScrollView.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 6),
            textScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            textScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            textScrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),

            loadingOverlay.topAnchor.constraint(equalTo: textScrollView.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: textScrollView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: textScrollView.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: textScrollView.bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -12),

            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 8),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func loadInitialImage(image: NSImage) {
        sourceImage = image
        previewImages = [image]
        currentImageIndex = 0
        interactiveImageView.image = image
        updatePagingUI()
        showLoading(true)
        statsLabel.stringValue = "字符数: 0 | 行数: 0"
        engineLabel.stringValue = "引擎: Apple Vision (系统原生) | 语言: 自动检测"
        copyAllButton.isEnabled = false
        formattingButton.isEnabled = false
    }

    private func showLoading(_ show: Bool) {
        loadingOverlay.isHidden = !show
        if show {
            loadingSpinner.startAnimation(nil)
        } else {
            loadingSpinner.stopAnimation(nil)
        }
    }

    func setDocument(_ document: OCRDocument) {
        self.document = document
        self.rawText = document.plainText
        showLoading(false)
        copyAllButton.isEnabled = true
        formattingButton.isEnabled = true
        applyFormatting()
        updateStats()
    }

    func setError(_ message: String) {
        showLoading(false)
        copyAllButton.isEnabled = false
        statsLabel.stringValue = "识别失败"
        textView.string = message
    }

    private func loadDocument(image: NSImage, document: OCRDocument) {
        sourceImage = image
        self.document = document
        rawText = document.plainText
        previewImages = [image]
        currentImageIndex = 0
        interactiveImageView.image = image
        updatePagingUI()

        applyFormatting()
        updateStats()
    }

    private func updatePagingUI() {
        if previewImages.count > 1 {
            pagingOverlay.isHidden = false
            pageLabel.stringValue = "\(currentImageIndex + 1) / \(previewImages.count)"
        } else {
            pagingOverlay.isHidden = true
        }
    }

    @objc private func prevImageAction() {
        guard currentImageIndex > 0 else { return }
        currentImageIndex -= 1
        interactiveImageView.image = previewImages[currentImageIndex]
        updatePagingUI()
    }

    @objc private func nextImageAction() {
        guard currentImageIndex < previewImages.count - 1 else { return }
        currentImageIndex += 1
        interactiveImageView.image = previewImages[currentImageIndex]
        updatePagingUI()
    }

    private func applyFormatting() {
        guard let doc = document else { return }
        let lines = doc.lines.map { (text: $0.text, boundingBox: $0.boundingBox) }
        let formatted = TextFormattingService.format(lines: lines, mode: currentMode)
        textView.string = formatted
        updateStats()
    }

    private func updateStats() {
        let text = textView.string
        let chars = text.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        statsLabel.stringValue = "字符数: \(chars) | 行数: \(lines)"
        let lang = detectLanguageName(for: text)
        engineLabel.stringValue = "引擎: Apple Vision (系统原生) | 语言: \(lang)"
    }

    private func detectLanguageName(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "自动检测" }

        if trimmed.range(of: "[\\u3040-\\u30FF]", options: .regularExpression) != nil { return "日语" }
        if trimmed.range(of: "[\\uAC00-\\uD7AF]", options: .regularExpression) != nil { return "韩语" }
        if trimmed.range(of: "[\\u4E00-\\u9FA5]", options: .regularExpression) != nil { return "简体中文" }
        if trimmed.range(of: "[\\u0400-\\u04FF]", options: .regularExpression) != nil { return "俄语" }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)

        let isPureASCII = trimmed.allSatisfy { $0.isASCII }
        let wordCount = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

        if isPureASCII && wordCount <= 2 {
            let dominantConf = recognizer.dominantLanguage.flatMap { hypotheses[$0] } ?? 0
            if dominantConf < 0.75 {
                return "英语"
            }
        }

        guard let lang = recognizer.dominantLanguage else {
            return "英语"
        }

        switch lang {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .english: return "英语"
        case .japanese: return "日语"
        case .korean: return "韩语"
        case .french: return "法语"
        case .german: return "德语"
        case .spanish: return "西班牙语"
        case .russian: return "俄语"
        case .italian: return "意大利语"
        case .portuguese: return "葡萄牙语"
        default:
            if isPureASCII && (hypotheses[lang] ?? 0) < 0.85 {
                return "英语"
            }
            return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: lang.rawValue) ?? lang.rawValue
        }
    }

    @objc private func copyAllAction() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView.string, forType: .string)

        copyAllButton.title = "已复制 ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyAllButton.title = "复制全部"
        }
    }

    @objc private func formattingChanged() {
        let index = formattingButton.indexOfSelectedItem - 1
        guard index >= 0, let mode = TextFormattingMode(rawValue: index) else { return }
        currentMode = mode
        updateFormattingMenuSelection()
        applyFormatting()
        if var config = try? configurationStore?.load() {
            config.ocrDefaultFormatting = mode.rawValue
            try? configurationStore?.save(config)
        }
    }

    private func updateFormattingMenuSelection() {
        for (index, mode) in TextFormattingMode.allCases.enumerated() {
            let item = formattingButton.item(at: index + 1)
            item?.state = (mode == currentMode) ? .on : .off
        }
    }

    private func updatePinButtonState() {
        if isPinned {
            isFloatingPanel = true
            level = .floating
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            pinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "置顶")
            pinButton.contentTintColor = .controlAccentColor
            pinButton.toolTip = "取消置顶"
        } else {
            isFloatingPanel = false
            level = .normal
            collectionBehavior = [.managed, .participatesInCycle]
            pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "置顶")
            pinButton.contentTintColor = .secondaryLabelColor
            pinButton.toolTip = "置顶窗口"
        }
    }

    @objc private func pinToggled() {
        isPinned.toggle()
        updatePinButtonState()
    }

    @objc private func continuousToggled() {
        isContinuous = continuousButton.state == .on
        if isContinuous {
            Self.activeContinuousInstance = self
            isPinned = true
            updatePinButtonState()
        } else if Self.activeContinuousInstance === self {
            Self.activeContinuousInstance = nil
        }
    }

    @objc private func showImageToggled() {
        let isVisible = showImageCheckbox.state == .on
        previewContainer.isHidden = !isVisible
        previewHeightConstraint?.constant = isVisible ? 180 : 0
        layoutIfNeeded()
        if isVisible {
            interactiveImageView.resetZoomAndPan()
        }
    }

    @objc private func autoCopyToggled() {
        if var config = try? configurationStore?.load() {
            config.ocrAutoCopyNextTime = autoCopyCheckbox.state == .on
            try? configurationStore?.save(config)
        }
    }

    @objc private func translateAction() {
        let selected = textView.selectedRange()
        let textToSend: String
        if selected.length > 0, let range = Range(selected, in: textView.string) {
            textToSend = String(textView.string[range])
        } else {
            textToSend = textView.string
        }
        let trimmed = textToSend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        translateHandler(trimmed)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func performClose(_ sender: Any?) {
        close()
    }

    override func close() {
        if Self.activeContinuousInstance === self {
            Self.activeContinuousInstance = nil
        }
        super.close()
    }
}

extension OCRWorkspacePanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updateStats()
    }
}

final class OCRInteractiveImageView: NSView {
    var image: NSImage? {
        didSet {
            resetZoomAndPan()
            needsDisplay = true
        }
    }

    private var zoomScale: CGFloat = 1.0
    private var contentOffset: CGPoint = .zero
    private var isDragging = false
    private var lastDragPoint: CGPoint = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedRed: 245/255.0, green: 245/255.0, blue: 247/255.0, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    func resetZoomAndPan() {
        guard let image = image, image.size.width > 0, image.size.height > 0 else {
            zoomScale = 1.0
            contentOffset = .zero
            needsDisplay = true
            return
        }

        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else {
            zoomScale = 1.0
            contentOffset = .zero
            return
        }

        let scaleX = viewSize.width / image.size.width
        let scaleY = viewSize.height / image.size.height
        let fit = min(scaleX, scaleY)
        zoomScale = fit >= 1.0 ? 1.0 : fit
        if zoomScale < 0.05 { zoomScale = fit }

        let scaledW = image.size.width * zoomScale
        let scaledH = image.size.height * zoomScale
        contentOffset = CGPoint(
            x: round((viewSize.width - scaledW) / 2.0),
            y: round((viewSize.height - scaledH) / 2.0)
        )
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if zoomScale == 1.0 || contentOffset == .zero {
            resetZoomAndPan()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }

        let drawRect = NSRect(
            x: contentOffset.x,
            y: contentOffset.y,
            width: image.size.width * zoomScale,
            height: image.size.height * zoomScale
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(rect: drawRect).fill()
        NSGraphicsContext.restoreGraphicsState()

        if abs(zoomScale - 1.0) < 0.001 {
            NSGraphicsContext.current?.imageInterpolation = .none
        } else {
            NSGraphicsContext.current?.imageInterpolation = .high
        }
        image.draw(in: drawRect)

        let border = NSBezierPath(rect: drawRect)
        border.lineWidth = 1.0
        NSColor(calibratedWhite: 0.85, alpha: 0.8).setStroke()
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoomAndPan()
            return
        }
        isDragging = true
        lastDragPoint = convert(event.locationInWindow, from: nil)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = currentPoint.x - lastDragPoint.x
        let dy = currentPoint.y - lastDragPoint.y
        lastDragPoint = currentPoint

        contentOffset.x += dx
        contentOffset.y += dy
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        let mousePoint = convert(event.locationInWindow, from: nil)
        let zoomFactor: CGFloat
        if event.hasPreciseScrollingDeltas {
            zoomFactor = 1.0 - (event.scrollingDeltaY * 0.015)
        } else {
            zoomFactor = event.deltaY > 0 ? 1.15 : 0.85
        }

        applyZoom(factor: zoomFactor, center: mousePoint)
    }

    override func magnify(with event: NSEvent) {
        let mousePoint = convert(event.locationInWindow, from: nil)
        let zoomFactor = 1.0 + event.magnification
        applyZoom(factor: zoomFactor, center: mousePoint)
    }

    private func applyZoom(factor: CGFloat, center: CGPoint) {
        guard let image = image, image.size.width > 0, image.size.height > 0 else { return }

        let oldScale = zoomScale
        let newScale = max(0.1, min(10.0, oldScale * factor))
        guard abs(newScale - oldScale) > 0.0001 else { return }

        let imgX = (center.x - contentOffset.x) / oldScale
        let imgY = (center.y - contentOffset.y) / oldScale

        zoomScale = newScale
        contentOffset.x = center.x - imgX * newScale
        contentOffset.y = center.y - imgY * newScale
        needsDisplay = true
    }
}
