import Carbon.HIToolbox
import Foundation
import NativeTranslatorMacKit

@MainActor
final class GlobalHotKeyManager {
    var onTranslateSelection: (() -> Void)?
    var onCaptureSelection: (() -> Void)?
    var onScreenshotAndPin: (() -> Void)?
    var onPinClipboardImage: (() -> Void)?
    var onLongScreenshot: (() -> Void)?
    var onScreenRecording: (() -> Void)?
    var onRestoreMostRecentPin: (() -> Void)?
    var onScreenTranslation: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var activeConfiguration: GlobalShortcutConfiguration?

    func register(_ configuration: GlobalShortcutConfiguration) throws {
        try configuration.validate()
        if activeConfiguration == configuration, !hotKeys.isEmpty {
            return
        }

        let previousConfiguration = activeConfiguration
        unregisterAll()
        do {
            try registerAll(configuration)
            activeConfiguration = configuration
        } catch {
            unregisterAll()
            if let previousConfiguration {
                do {
                    try registerAll(previousConfiguration)
                    activeConfiguration = previousConfiguration
                } catch {
                    activeConfiguration = nil
                }
            }
            throw error
        }
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func registerAll(_ configuration: GlobalShortcutConfiguration) throws {
        try installEventHandler()
        for action in GlobalShortcutAction.allCases {
            try registerHotKey(configuration[action], action: action)
        }
    }

    private func installEventHandler() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else {
                    return parameterStatus
                }
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in
                    manager.handleHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard status == noErr else {
            throw GlobalHotKeyError.handlerRegistrationFailed(status)
        }
    }

    private func registerHotKey(
        _ shortcut: RecordedShortcut,
        action: GlobalShortcutAction
    ) throws {
        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: fourCharacterCode("NTRN"),
            id: action.eventID
        )
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            carbonModifiers(shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr, let hotKey else {
            throw GlobalHotKeyError.shortcutRegistrationFailed(action, status)
        }
        hotKeys.append(hotKey)
    }

    private func handleHotKey(id: UInt32) {
        guard let action = GlobalShortcutAction.allCases.first(where: { $0.eventID == id }) else {
            return
        }
        switch action {
        case .translateSelection:
            onTranslateSelection?()
        case .captureSelection:
            onCaptureSelection?()
        case .screenshotAndPin:
            onScreenshotAndPin?()
        case .pinClipboardImage:
            onPinClipboardImage?()
        case .longScreenshot:
            onLongScreenshot?()
        case .screenRecording:
            onScreenRecording?()
        case .restoreMostRecentPin:
            onRestoreMostRecentPin?()
        case .screenTranslation:
            onScreenTranslation?()
        }
    }

    private func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}

private enum GlobalHotKeyError: LocalizedError {
    case handlerRegistrationFailed(OSStatus)
    case shortcutRegistrationFailed(GlobalShortcutAction, OSStatus)

    var errorDescription: String? {
        switch self {
        case let .handlerRegistrationFailed(status):
            return "无法启动全局快捷键监听（错误码：\(status)）"
        case let .shortcutRegistrationFailed(action, status):
            return "无法注册“\(action.title)”快捷键，可能已被其他应用占用（错误码：\(status)）"
        }
    }
}
