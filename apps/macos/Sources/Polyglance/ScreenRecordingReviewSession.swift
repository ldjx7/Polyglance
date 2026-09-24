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
    let progressSlider = NSSlider()
    let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private(set) var playPauseButton: NSButton!
    private(set) var saveButton: NSButton!
    private(set) var quickSaveButton: NSButton!
    private(set) var copyButton: NSButton!
    private(set) var restartButton: NSButton!
    private(set) var closeButton: NSButton!
    let format: ScreenRecordingFormat
    var onAction: ((ScreenRecordingReviewAction) -> Void)?
    var onSeek: ((Double) -> Void)?

    init(format: ScreenRecordingFormat) {
        self.format = format
        super.init(frame: CGRect(x: 0, y: 0, width: 720, height: 530))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        previewContainer.wantsLayer = true
        previewContainer.layer?.backgroundColor = NSColor.black.cgColor
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewContainer)

        progressSlider.minValue = 0
        progressSlider.maxValue = 1
        progressSlider.doubleValue = 0
        progressSlider.target = self
        progressSlider.action = #selector(sliderChanged)
        progressSlider.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        let progressRow = NSStackView(views: [progressSlider, timeLabel])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = 10
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressRow)

        playPauseButton = makeButton("播放", #selector(playPause))
        if format == .gif {
            playPauseButton.isEnabled = false
            playPauseButton.toolTip = playPauseButton.title
            playPauseButton.setAccessibilityHelp(playPauseButton.title)
            progressSlider.isEnabled = false
        }
        saveButton = makeButton("保存为", #selector(save))
        quickSaveButton = makeButton("快速保存", #selector(quickSave))
        copyButton = makeButton("复制并关闭", #selector(copyFile))
        restartButton = makeButton("重新录制", #selector(restart))
        closeButton = makeButton("丢弃", #selector(closeReview))
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
            previewContainer.bottomAnchor.constraint(equalTo: progressRow.topAnchor, constant: -8),

            progressRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressRow.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),
            progressRow.heightAnchor.constraint(equalToConstant: 20),

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

    func updateTime(current: Double, total: Double) {
        let curSec = Int(current)
        let totSec = Int(total)
        timeLabel.stringValue = String(format: "%02d:%02d / %02d:%02d", curSec / 60, curSec % 60, totSec / 60, totSec % 60)
    }

    @objc private func sliderChanged() {
        onSeek?(progressSlider.doubleValue)
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
    private var timeObserverToken: Any?
    private var isSeeking = false
    private var keyEventMonitor: Any?
    private var loopObserver: NSObjectProtocol?

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
        panel.hidesOnDeactivate = false
        panel.contentView = reviewView

        reviewView.onAction = { [weak self] action in
            guard let self else { return }
            if action == .playPause {
                self.togglePlayback()
            }
            self.onAction?(action)
        }

        reviewView.onSeek = { [weak self] progress in
            guard let self, self.format == .mp4, let player = self.player,
                  let duration = player.currentItem?.duration, duration.isNumeric else { return }
            let totalSeconds = CMTimeGetSeconds(duration)
            let targetSeconds = progress * totalSeconds
            let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            self.isSeeking = true
            player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSeeking = false
                }
            }
            self.reviewView.updateTime(current: targetSeconds, total: totalSeconds)
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window == self.panel else { return event }
            if event.keyCode == 49 { // 49 = Space
                self.togglePlayback()
                return nil
            }
            return event
        }

        configurePreview()
    }

    func present() {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        if let timeObserverToken {
            player?.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
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

            // 播放完毕停止，不自动循环播放
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.player?.pause()
                    self.isPlaying = false
                    self.reviewView.setPlaying(false)
                    self.reviewView.progressSlider.doubleValue = 1.0
                    if let duration = self.player?.currentItem?.duration, duration.isNumeric {
                        let totalSeconds = CMTimeGetSeconds(duration)
                        self.reviewView.updateTime(current: totalSeconds, total: totalSeconds)
                    }
                }
            }

            // 监听播放时间并更新进度条
            let interval = CMTime(value: 1, timescale: 30)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self, !self.isSeeking,
                      let duration = self.player?.currentItem?.duration, duration.isNumeric else { return }
                let currentSeconds = CMTimeGetSeconds(time)
                let totalSeconds = CMTimeGetSeconds(duration)
                if totalSeconds > 0 {
                    self.reviewView.progressSlider.doubleValue = currentSeconds / totalSeconds
                    self.reviewView.updateTime(current: currentSeconds, total: totalSeconds)
                }
            }

            player.play()
            isPlaying = true
            reviewView.setPlaying(true)

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
                if let item = player?.currentItem, item.currentTime() >= item.duration {
                    player?.seek(to: .zero)
                }
                player?.play()
            } else {
                player?.pause()
            }
            reviewView.setPlaying(isPlaying)
        case .gif:
            isPlaying.toggle()
            reviewView.setPlaying(isPlaying)
        }
    }
}
