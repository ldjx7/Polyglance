import AppKit

@MainActor
enum TextReplacementService {
    static var lastTargetApplication: NSRunningApplication?

    static func replaceSelection(with text: String, completion: (() -> Void)? = nil) {
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        if let panel = (NSApp.keyWindow ?? NSApp.windows.first(where: { ($0 as? NSPanel)?.isFloatingPanel == true && $0.isVisible }) ?? NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible })) as? NSPanel {
            panel.orderOut(nil)
            panel.close()
        }

        NSApp.hide(nil)
        if let targetApp = lastTargetApplication {
            targetApp.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            postPasteShortcut()
            completion?()
        }
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
