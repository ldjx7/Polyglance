import AppKit

@MainActor
enum ClipboardFocusRestoration {
    static func canRestore(target: NSRunningApplication, frontmost: NSRunningApplication?) -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !target.isTerminated, target.processIdentifier != ownPID, let frontmost else { return false }
        return frontmost.processIdentifier == target.processIdentifier || frontmost.processIdentifier == ownPID
    }

    static func restore(_ target: NSRunningApplication) {
        // The history window has released its editor and key-window ownership.
        // Opening history activated Polyglance, so this is a real app handoff.
        NSApp.yieldActivation(to: target)
        target.activate(options: [.activateIgnoringOtherApps])
    }
}
