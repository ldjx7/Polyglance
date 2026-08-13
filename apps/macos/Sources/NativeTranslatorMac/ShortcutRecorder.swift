import AppKit
import NativeTranslatorMacKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: RecordedShortcut

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.shortcut = shortcut
        button.onChange = { shortcut = $0 }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = { shortcut = $0 }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut = RecordedShortcut(keyCode: 0, modifiers: []) {
        didSet {
            if !isRecording {
                title = ShortcutFormatter.string(for: shortcut)
                setAccessibilityValue(title)
            }
        }
    }
    var onChange: ((RecordedShortcut) -> Void)?

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        setAccessibilityLabel("录制快捷键")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func beginRecording() {
        isRecording = true
        title = "请按快捷键…"
        setAccessibilityValue(title)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            finishRecording(with: nil)
            return
        }

        let modifiers = ShortcutModifiers(event.modifierFlags)
        guard !modifiers.intersection(.primary).isEmpty else {
            NSSound.beep()
            title = "需包含 ⌘ / ⌥ / ⌃"
            setAccessibilityValue(title)
            return
        }

        finishRecording(
            with: RecordedShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers
            )
        )
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign, isRecording {
            finishRecording(with: nil)
        }
        return didResign
    }

    private func finishRecording(with recordedShortcut: RecordedShortcut?) {
        isRecording = false
        if let recordedShortcut {
            shortcut = recordedShortcut
            onChange?(recordedShortcut)
        } else {
            title = ShortcutFormatter.string(for: shortcut)
            setAccessibilityValue(title)
        }
        window?.makeFirstResponder(nil)
    }
}

private extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var result: ShortcutModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

enum ShortcutFormatter {
    static func string(for shortcut: RecordedShortcut) -> String {
        var result = ""
        if shortcut.modifiers.contains(.control) { result += "⌃" }
        if shortcut.modifiers.contains(.option) { result += "⌥" }
        if shortcut.modifiers.contains(.shift) { result += "⇧" }
        if shortcut.modifiers.contains(.command) { result += "⌘" }
        result += keyNames[shortcut.keyCode] ?? "Key (shortcut.keyCode)"
        return result
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩︎",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 65: ".", 67: "*", 69: "+", 71: "Clear",
        75: "/", 76: "⌤", 78: "-", 81: "=", 82: "0", 83: "1", 84: "2",
        85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 115: "↖", 116: "⇞", 117: "⌦",
        118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1", 123: "←",
        124: "→", 125: "↓", 126: "↑",
    ]
}
