import AppKit

@MainActor
enum ClipboardFocusRestoration {
    static func canRestore(target: NSRunningApplication, frontmost: NSRunningApplication?) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !target.isTerminated, target.processIdentifier != ownPID, let frontmost else { return false }
        return frontmost.processIdentifier == target.processIdentifier || frontmost.processIdentifier == ownPID
    }

    static func restore(_ target: NSRunningApplication) {
        // The panel must release its field editor and nonactivating key focus first.
        // Yield activation explicitly when Polyglance itself was active (menu entry).
        NSApp.yieldActivation(to: target)
        target.activate()
    }
}
