import AppKit

enum ClipboardPresentationMode: Equatable {
    case quick
    case management
}

/// One action table for row clicks, Return and numbered/pinned shortcuts.
enum ClipboardSelectionAction: Equatable {
    case copy
    case paste
    case pastePlainText

    var pastes: Bool { self != .copy }
    var plainTextOnly: Bool { self == .pastePlainText }

    static func resolve(modifiers: NSEvent.ModifierFlags, automaticPaste: Bool) -> Self? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        switch flags {
        case [], .command: return automaticPaste ? .paste : .copy
        case .option: return automaticPaste ? .copy : .paste
        case [.option, .shift] where !automaticPaste: return .pastePlainText
        case [.command, .shift] where automaticPaste: return .pastePlainText
        default: return nil
        }
    }

    static func hint(automaticPaste: Bool) -> String {
        automaticPaste
            ? "Enter 粘贴 · ⌥Enter 仅复制 · ⌘⇧Enter 纯文本粘贴"
            : "Enter 复制 · ⌥Enter 粘贴 · ⌥⇧Enter 纯文本粘贴"
    }
}

/// Opening the popup alone never commits a selection on modifier release.
struct ClipboardCycleState {
    enum Phase: Equatable { case idle, opening, cycling }
    private(set) var phase: Phase = .idle
    private(set) var keyCode: UInt16?
    private(set) var requiredModifiers: NSEvent.ModifierFlags = []
    var isActive: Bool { phase != .idle }

    mutating func begin(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        requiredModifiers = modifiers.intersection([.command, .option, .shift, .control])
        phase = requiredModifiers.isEmpty ? .idle : .opening
    }

    mutating func advance() -> Bool {
        guard isActive else { return false }
        phase = .cycling
        return true
    }

    /// Returns true once, only after cycling and releasing every modifier.
    mutating func release(modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isActive, modifiers.intersection([.command, .option, .shift, .control]).isEmpty else { return false }
        let shouldCommit = phase == .cycling
        cancel()
        return shouldCommit
    }

    mutating func cancel() { phase = .idle; keyCode = nil; requiredModifiers = [] }
}
