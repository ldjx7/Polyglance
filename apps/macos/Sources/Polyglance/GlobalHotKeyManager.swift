import Carbon.HIToolbox
import Foundation
import PolyglanceKit

@MainActor
final class GlobalHotKeyManager {
    var onTranslateSelection: (() -> Void)?
    var onCaptureSelection: ((CFAbsoluteTime) -> Void)?
    var onScreenshotAndPin: ((CFAbsoluteTime) -> Void)?
    var onPinClipboardImage: (() -> Void)?
    var onLongScreenshot: ((CFAbsoluteTime) -> Void)?
    var onScreenRecording: ((CFAbsoluteTime) -> Void)?
    var onRestoreMostRecentPin: (() -> Void)?
    var onScreenTranslation: ((CFAbsoluteTime) -> Void)?
    var onOpenTranslator: (() -> Void)?
    var onOcrTranslate: ((CFAbsoluteTime) -> Void)?
    var onOcrWorkspace: ((CFAbsoluteTime) -> Void)?
    var onOcrTranslationCard: ((CFAbsoluteTime) -> Void)?
    var onScreenshotAndCopy: ((CFAbsoluteTime) -> Void)?
    var onTranslateAndReplace: (() -> Void)?

    public private(set) var failedActions: [GlobalShortcutAction: String] = [:]

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var pressedHotKeyIDs: Set<UInt32> = []
    private var activeConfiguration: GlobalShortcutConfiguration?

    func register(_ configuration: GlobalShortcutConfiguration) throws {
        try configuration.validate()
        if activeConfiguration == configuration, !hotKeys.isEmpty, failedActions.isEmpty {
            return
        }

        unregisterAll()
        failedActions.removeAll()
        try installEventHandler()
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = configuration[action] else {
                continue
            }
            do {
                try registerHotKey(shortcut, action: action)
            } catch {
                failedActions[action] = "已被占用"
            }
        }
        activeConfiguration = configuration
    }

    deinit {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installEventHandler() throws {
        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                let pressTime = CFAbsoluteTimeGetCurrent()
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
                let eventKind = GetEventKind(event)
                DispatchQueue.main.async {
                    if eventKind == UInt32(kEventHotKeyReleased) {
                        manager.pressedHotKeyIDs.remove(hotKeyID.id)
                        return
                    }
                    // Holding a shortcut must not repeat actions or permission prompts.
                    guard manager.pressedHotKeyIDs.insert(hotKeyID.id).inserted else {
                        return
                    }
                    manager.handleHotKey(id: hotKeyID.id, pressTime: pressTime)
                }
                return noErr
            },
            eventTypes.count,
            eventTypes,
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
            signature: fourCharacterCode("PGLC"),
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

    private func handleHotKey(id: UInt32, pressTime: CFAbsoluteTime) {
        guard let action = GlobalShortcutAction.allCases.first(where: { $0.eventID == id }) else {
            return
        }
        switch action {
        case .translateSelection:
            onTranslateSelection?()
        case .captureSelection:
            onCaptureSelection?(pressTime)
        case .screenshotAndPin:
            onScreenshotAndPin?(pressTime)
        case .pinClipboardImage:
            onPinClipboardImage?()
        case .longScreenshot:
            onLongScreenshot?(pressTime)
        case .screenRecording:
            onScreenRecording?(pressTime)
        case .restoreMostRecentPin:
            onRestoreMostRecentPin?()
        case .screenTranslation:
            onScreenTranslation?(pressTime)
        case .openTranslator:
            onOpenTranslator?()
        case .ocrTranslate:
            onOcrTranslate?(pressTime)
        case .ocrWorkspace:
            onOcrWorkspace?(pressTime)
        case .ocrTranslationCard:
            onOcrTranslationCard?(pressTime)
        case .screenshotAndCopy:
            onScreenshotAndCopy?(pressTime)
        case .translateAndReplace:
            onTranslateAndReplace?()
        }
    }

    private func unregisterAll() {
        pressedHotKeyIDs.removeAll()
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
            return "无法注册 [\(action.title)] 快捷键，可能已被其他应用占用（错误码：\(status)）"
        }
    }
}
