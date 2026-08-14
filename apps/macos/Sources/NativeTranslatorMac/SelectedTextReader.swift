import AppKit
import ApplicationServices
import NativeTranslatorMacKit

enum SelectedTextReadResult: Equatable {
    case text(String)
    case noSelection
    case permissionRequired
}

@MainActor
struct SelectedTextReader {
    private let accessibilityTrustCheck: () -> Bool
    private let accessibilityPermissionRequest: () -> Void
    private let directReaderOverride: (() -> String?)?
    private let copyReaderOverride: (() async -> String?)?

    init(
        accessibilityTrustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        accessibilityPermissionRequest: @escaping () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        },
        directReader: (() -> String?)? = nil,
        copyReader: (() async -> String?)? = nil
    ) {
        self.accessibilityTrustCheck = accessibilityTrustCheck
        self.accessibilityPermissionRequest = accessibilityPermissionRequest
        directReaderOverride = directReader
        copyReaderOverride = copyReader
    }

    func read() async -> SelectedTextReadResult {
        guard accessibilityTrustCheck() else {
            return .permissionRequired
        }
        let pipeline = SelectionCapturePipeline(
            directReader: directReaderOverride ?? readAccessibilitySelection,
            copyReader: copyReaderOverride ?? readSelectionByCopying
        )
        guard let text = await pipeline.read() else {
            return .noSelection
        }
        return .text(text)
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionRequest()
    }

    private func readAccessibilitySelection() -> String? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success,
              let focusedElement = focusedValue,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }

        var selectedValue: CFTypeRef?
        let selectedStatus = AXUIElementCopyAttributeValue(
            unsafeBitCast(focusedElement, to: AXUIElement.self),
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedStatus == .success,
              let selectedText = selectedValue as? String else {
            return nil
        }

        let trimmedText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    private func readSelectionByCopying() async -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        let clearedChangeCount = pasteboard.changeCount

        guard postCopyShortcut() else {
            snapshot.restore(to: pasteboard)
            return nil
        }

        let timeout = Date().addingTimeInterval(0.5)
        while pasteboard.changeCount == clearedChangeCount,
              Date() < timeout,
              !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let copiedChangeCount = pasteboard.changeCount
        let copiedText = pasteboard.string(forType: .string)
        let trimmedText = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only restore if nobody changed the clipboard after our simulated copy.
        if pasteboard.changeCount == copiedChangeCount,
           pasteboard.string(forType: .string) == copiedText {
            snapshot.restore(to: pasteboard)
        }

        guard copiedChangeCount != clearedChangeCount,
              let trimmedText,
              !trimmedText.isEmpty else {
            return nil
        }
        return trimmedText
    }

    private func postCopyShortcut() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 8,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 8,
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { storedItem in
            let item = NSPasteboardItem()
            for (type, data) in storedItem {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
