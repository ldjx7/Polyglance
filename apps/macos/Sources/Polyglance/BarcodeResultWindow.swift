import AppKit
import SwiftUI

/// Keeps the selected screenshot in place and marks every recognized code at
/// its visual center. Hovering or clicking a marker reveals its decoded value.
@MainActor
final class BarcodeResultWindow: NSPanel {
    static let markerDiameter: CGFloat = 22
    static let markerCoreDiameter: CGFloat = 11

    /// Called after the overlay is dismissed, so the owner can drop it.
    var onClosed: (() -> Void)?

    init(
        observations: [BarcodeObservation],
        image: NSImage,
        screenFrame: CGRect
    ) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setFrame(screenFrame, display: false)
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        level = .floating

        contentView = NSHostingView(
            rootView: BarcodeRecognitionOverlayView(
                observations: observations,
                image: image,
                onOpenURL: { [weak self] url in
                    self?.confirmOpening(url)
                },
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2 {
            close()
            return
        }
        super.sendEvent(event)
    }

    override func close() {
        guard isVisible else {
            return
        }
        super.close()
        onClosed?()
    }

    /// Vision reports normalized lower-left coordinates while SwiftUI lays its
    /// content out from the upper-left. The marker sits on the visual center.
    static func markerCenter(
        for observation: BarcodeObservation,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: observation.boundingBox.midX * size.width,
            y: (1 - observation.boundingBox.midY) * size.height
        )
    }

    static func headerTitle(for observations: [BarcodeObservation]) -> String {
        guard observations.count == 1, let observation = observations.first else {
            return "识别到 \(observations.count) 个二维码"
        }
        return observation.symbology.title
    }

    /// The card displays the full URL and asks again before leaving Polyglance.
    private func confirmOpening(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "打开链接？"
        alert.informativeText = url.absoluteString
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        if NSWorkspace.shared.open(url) {
            close()
        } else {
            NSSound.beep()
        }
    }
}

/// Keeps every visible recognition overlay alive independently.
@MainActor
final class BarcodeResultWindowStore {
    private var windows: [ObjectIdentifier: BarcodeResultWindow] = [:]

    var activeWindowCount: Int { windows.count }

    func retain(_ window: BarcodeResultWindow) {
        let identifier = ObjectIdentifier(window)
        windows[identifier] = window
        window.onClosed = { [weak self, weak window] in
            guard let window else { return }
            self?.release(window)
        }
    }

    func release(_ window: BarcodeResultWindow) {
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    func contains(_ window: BarcodeResultWindow) -> Bool {
        windows[ObjectIdentifier(window)] != nil
    }
}

private struct BarcodeRecognitionOverlayView: View {
    let observations: [BarcodeObservation]
    let image: NSImage
    let onOpenURL: (URL) -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                    .allowsHitTesting(false)

                ForEach(Array(observations.enumerated()), id: \.offset) { _, observation in
                    BarcodeMarkerView(
                        observation: observation,
                        onOpenURL: onOpenURL
                    )
                    .position(
                        BarcodeResultWindow.markerCenter(
                            for: observation,
                            in: geometry.size
                        )
                    )
                }

                HStack(spacing: 6) {
                    Text(BarcodeResultWindow.headerTitle(for: observations))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.regularMaterial, in: Capsule())

                    Spacer(minLength: 4)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭二维码识别")
                }
                .padding(6)
            }
        }
    }
}

private struct BarcodeMarkerView: View {
    let observation: BarcodeObservation
    let onOpenURL: (URL) -> Void

    @State private var isPresentingContent = false
    @State private var pendingHide: Task<Void, Never>?

    var body: some View {
        Button {
            showContent()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(
                        width: BarcodeResultWindow.markerDiameter,
                        height: BarcodeResultWindow.markerDiameter
                    )
                    .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(
                        width: BarcodeResultWindow.markerCoreDiameter,
                        height: BarcodeResultWindow.markerCoreDiameter
                    )
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                showContent()
            } else {
                scheduleHide()
            }
        }
        .popover(isPresented: $isPresentingContent, arrowEdge: .bottom) {
            BarcodeHoverCard(
                observation: observation,
                onOpenURL: onOpenURL
            )
            .onHover { hovering in
                if hovering {
                    pendingHide?.cancel()
                } else {
                    scheduleHide()
                }
            }
        }
        .accessibilityLabel("查看\(observation.symbology.title)内容")
    }

    private func showContent() {
        pendingHide?.cancel()
        isPresentingContent = true
    }

    private func scheduleHide() {
        pendingHide?.cancel()
        pendingHide = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            isPresentingContent = false
        }
    }
}

private struct BarcodeHoverCard: View {
    let observation: BarcodeObservation
    let onOpenURL: (URL) -> Void

    @State private var didCopy = false

    private var content: BarcodeContent {
        observation.content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(observation.symbology.title)
                .font(.caption)
                .foregroundStyle(.secondary)

            contentView

            HStack(spacing: 8) {
                Button(didCopy ? "已复制" : copyButtonTitle) {
                    copyToPasteboard(content.copiedText)
                }
                .disabled(content.copiedText.isEmpty)

                if case let .url(url) = content {
                    Button("打开链接") {
                        onOpenURL(url)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private var copyButtonTitle: String {
        if case .wifi = content {
            return "复制密码"
        }
        return "复制"
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case let .url(url):
            scrollableText(url.absoluteString)
        case let .otp(url):
            VStack(alignment: .leading, spacing: 3) {
                scrollableText(url.absoluteString)
                Text("两步验证密钥，可导入密码管理器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .wifi(ssid, password, security):
            VStack(alignment: .leading, spacing: 3) {
                Label(ssid, systemImage: "wifi")
                    .font(.callout)
                if let password, !password.isEmpty {
                    Text("密码：\(password)")
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if let security, !security.isEmpty {
                    Text("加密方式：\(security)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .text(text):
            scrollableText(text)
        }
    }

    private func scrollableText(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 180)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            NSSound.beep()
            return
        }
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
