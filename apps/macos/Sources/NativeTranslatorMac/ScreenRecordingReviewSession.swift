import AppKit
import AVFoundation

enum ScreenRecordingReviewAction: Equatable {
    case playPause
    case save
    case quickSave
    case copy
    case restart
    case close
}

@MainActor
final class ScreenRecordingReviewView: NSView {
    let previewContainer = NSView()
    private(set) var playPauseButton: NSButton!
    private(set) var saveButton: NSButton!
    private(set) var quickSaveButton: NSButton!
    private(set) var copyButton: NSButton!
    private(set) var restartButton: NSButton!
    private(set) var closeButton: NSButton!
    let format: ScreenRecordingFormat
    var onAction: ((ScreenRecordingReviewAction) -> Void)?

    init(format: ScreenRecordingFormat) {
        self.format = format
        super.init(frame: CGRect(x: 0, y: 0, width: 720, height: 500))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewContainer)

        playPauseButton = makeButton("播放", #selector(playPause))
        if format == .gif {
            playPauseButton.isEnabled = false
            playPauseButton.toolTip = playPauseButton.title
            playPauseButton.setAccessibilityHelp(playPauseButton.title)
        }
        saveButton = makeButton("保存…", #selector(save))
        quickSaveButton = makeButton("快速保存", #selector(quickSave))
        copyButton = makeButton("复制文件", #selector(copyFile))
        restartButton = makeButton("重新录制", #selector(restart))
        closeButton = makeButton("关闭", #selector(closeReview))
        let controls = NSStackView(views: [
            playPauseButton,
            saveButton,
            quickSaveButton,
            copyButton,
            restartButton,
            closeButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        NSLayoutConstraint.activate([
            previewContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            previewContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            previewContainer.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            previewContainer.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -14),
            controls.centerXAnchor.constraint(equalTo: centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            controls.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPlaying(_ playing: Bool) {
        playPauseButton.title = playing ? "暂停" : "播放"
        playPauseButton.toolTip = playPauseButton.title
        playPauseButton.setAccessibilityLabel(playPauseButton.title)
        playPauseButton.setAccessibilityHelp(playPauseButton.title)
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(title)
        return button
    }

    @objc private func playPause() { onAction?(.playPause) }
    @objc private func save() { onAction?(.save) }
    @objc private func quickSave() { onAction?(.quickSave) }
    @objc private func copyFile() { onAction?(.copy) }
    @objc private func restart() { onAction?(.restart) }
    @objc private func closeReview() { onAction?(.close) }
}

@MainActor
final class ScreenRecordingReviewSession {
    let outputURL: URL
    let format: ScreenRecordingFormat
    let panel: NSPanel
    let reviewView: ScreenRecordingReviewView
    var onAction: ((ScreenRecordingReviewAction) -> Void)?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var imageView: NSImageView?
    private var isPlaying = false

    init(outputURL: URL, format: ScreenRecordingFormat) {
        self.outputURL = outputURL
        self.format = format
        reviewView = ScreenRecordingReviewView(format: format)
        panel = NSPanel(
            contentRect: reviewView.bounds,
            styleMask: [.titled, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "录屏预览 · \(format.displayName)"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = reviewView

        reviewView.onAction = { [weak self] action in
            guard let self else { return }
            if action == .playPause {
                self.togglePlayback()
            }
            self.onAction?(action)
        }
        configurePreview()
    }

    func present() {
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() {
        player?.pause()
        isPlaying = false
        panel.orderOut(nil)
    }

    private func configurePreview() {
        switch format {
        case .mp4:
            let player = AVPlayer(url: outputURL)
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.frame = reviewView.previewContainer.bounds
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            reviewView.previewContainer.layer?.addSublayer(playerLayer)
            self.player = player
            self.playerLayer = playerLayer
        case .gif:
            let imageView = NSImageView(frame: reviewView.previewContainer.bounds)
            imageView.autoresizingMask = [.width, .height]
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.image = NSImage(contentsOf: outputURL)
            reviewView.previewContainer.addSubview(imageView)
            self.imageView = imageView
        }
    }

    private func togglePlayback() {
        switch format {
        case .mp4:
            isPlaying.toggle()
            if isPlaying {
                player?.play()
            } else {
                player?.pause()
            }
            reviewView.setPlaying(isPlaying)
        case .gif:
            // NSImageView renders animated GIF representations automatically.
            // The button remains a semantic preview control without re-encoding.
            isPlaying.toggle()
            reviewView.setPlaying(isPlaying)
        }
    }
}
