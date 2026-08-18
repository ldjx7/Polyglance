import Foundation

public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let control = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)

    public static let supported: ShortcutModifiers = [.command, .option, .control, .shift]
    public static let primary: ShortcutModifiers = [.command, .option, .control]
}

public struct RecordedShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum GlobalShortcutAction: String, Codable, CaseIterable, Sendable {
    case translateSelection
    case captureSelection
    case screenshotAndPin
    case pinClipboardImage
    case longScreenshot
    case screenRecording
    case restoreMostRecentPin
    case screenTranslation

    public var title: String {
        switch self {
        case .translateSelection:
            return "读取选区并翻译"
        case .captureSelection:
            return "读取选区，不自动翻译"
        case .screenshotAndPin:
            return "截图工具"
        case .pinClipboardImage:
            return "贴出剪贴板图片"
        case .longScreenshot:
            return "长截图"
        case .screenRecording:
            return "区域录屏"
        case .restoreMostRecentPin:
            return "恢复最近关闭的贴图"
        case .screenTranslation:
            return "截屏翻译"
        }
    }

    public var eventID: UInt32 {
        switch self {
        case .translateSelection: return 1
        case .captureSelection: return 2
        case .screenshotAndPin: return 3
        case .pinClipboardImage: return 4
        case .longScreenshot: return 5
        case .screenRecording: return 6
        case .restoreMostRecentPin: return 7
        case .screenTranslation: return 8
        }
    }
}

public struct GlobalShortcutConfiguration: Codable, Equatable, Sendable {
    public var translateSelection: RecordedShortcut
    public var captureSelection: RecordedShortcut
    public var screenshotAndPin: RecordedShortcut
    public var pinClipboardImage: RecordedShortcut
    public var longScreenshot: RecordedShortcut
    public var screenRecording: RecordedShortcut
    public var restoreMostRecentPin: RecordedShortcut
    public var screenTranslation: RecordedShortcut

    public init(
        translateSelection: RecordedShortcut,
        captureSelection: RecordedShortcut,
        screenshotAndPin: RecordedShortcut,
        pinClipboardImage: RecordedShortcut,
        longScreenshot: RecordedShortcut,
        screenRecording: RecordedShortcut,
        restoreMostRecentPin: RecordedShortcut,
        screenTranslation: RecordedShortcut
    ) {
        self.translateSelection = translateSelection
        self.captureSelection = captureSelection
        self.screenshotAndPin = screenshotAndPin
        self.pinClipboardImage = pinClipboardImage
        self.longScreenshot = longScreenshot
        self.screenRecording = screenRecording
        self.restoreMostRecentPin = restoreMostRecentPin
        self.screenTranslation = screenTranslation
    }

    public static let `default` = GlobalShortcutConfiguration(
        translateSelection: RecordedShortcut(keyCode: 2, modifiers: [.option]),
        captureSelection: RecordedShortcut(keyCode: 2, modifiers: [.option, .shift]),
        screenshotAndPin: RecordedShortcut(keyCode: 18, modifiers: [.option]),
        pinClipboardImage: RecordedShortcut(keyCode: 19, modifiers: [.option]),
        longScreenshot: RecordedShortcut(keyCode: 20, modifiers: [.option]),
        screenRecording: RecordedShortcut(keyCode: 21, modifiers: [.option]),
        restoreMostRecentPin: RecordedShortcut(keyCode: 23, modifiers: [.option]),
        screenTranslation: RecordedShortcut(keyCode: 22, modifiers: [.option])
    )

    public subscript(action: GlobalShortcutAction) -> RecordedShortcut {
        get {
            switch action {
            case .translateSelection: return translateSelection
            case .captureSelection: return captureSelection
            case .screenshotAndPin: return screenshotAndPin
            case .pinClipboardImage: return pinClipboardImage
            case .longScreenshot: return longScreenshot
            case .screenRecording: return screenRecording
            case .restoreMostRecentPin: return restoreMostRecentPin
            case .screenTranslation: return screenTranslation
            }
        }
        set {
            switch action {
            case .translateSelection: translateSelection = newValue
            case .captureSelection: captureSelection = newValue
            case .screenshotAndPin: screenshotAndPin = newValue
            case .pinClipboardImage: pinClipboardImage = newValue
            case .longScreenshot: longScreenshot = newValue
            case .screenRecording: screenRecording = newValue
            case .restoreMostRecentPin: restoreMostRecentPin = newValue
            case .screenTranslation: screenTranslation = newValue
            }
        }
    }

    public var allShortcuts: [RecordedShortcut] {
        GlobalShortcutAction.allCases.map { self[$0] }
    }

    private enum CodingKeys: String, CodingKey {
        case translateSelection
        case captureSelection
        case screenshotAndPin
        case pinClipboardImage
        case longScreenshot
        case screenRecording
        case restoreMostRecentPin
        case screenTranslation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translateSelection = try container.decode(RecordedShortcut.self, forKey: .translateSelection)
        captureSelection = try container.decode(RecordedShortcut.self, forKey: .captureSelection)
        screenshotAndPin = try container.decode(RecordedShortcut.self, forKey: .screenshotAndPin)
        pinClipboardImage = try container.decode(RecordedShortcut.self, forKey: .pinClipboardImage)
        longScreenshot = try container.decodeIfPresent(
            RecordedShortcut.self,
            forKey: .longScreenshot
        ) ?? Self.default.longScreenshot
        screenRecording = try container.decodeIfPresent(
            RecordedShortcut.self,
            forKey: .screenRecording
        ) ?? Self.default.screenRecording
        restoreMostRecentPin = try container.decodeIfPresent(
            RecordedShortcut.self,
            forKey: .restoreMostRecentPin
        ) ?? Self.default.restoreMostRecentPin
        screenTranslation = try container.decodeIfPresent(
            RecordedShortcut.self,
            forKey: .screenTranslation
        ) ?? Self.default.screenTranslation
    }

    public func validate() throws {
        var owners: [RecordedShortcut: GlobalShortcutAction] = [:]
        for action in GlobalShortcutAction.allCases {
            let shortcut = self[action]
            guard shortcut.keyCode <= 127 else {
                throw GlobalShortcutValidationError.invalidKey(action)
            }
            guard !shortcut.modifiers.intersection(.primary).isEmpty else {
                throw GlobalShortcutValidationError.missingPrimaryModifier(action)
            }
            guard shortcut.modifiers.subtracting(.supported).isEmpty else {
                throw GlobalShortcutValidationError.unsupportedModifier(action)
            }
            if let existingAction = owners[shortcut] {
                throw GlobalShortcutValidationError.duplicate(existingAction, action)
            }
            owners[shortcut] = action
        }
    }
}

public enum GlobalShortcutValidationError: LocalizedError, Equatable {
    case invalidKey(GlobalShortcutAction)
    case missingPrimaryModifier(GlobalShortcutAction)
    case unsupportedModifier(GlobalShortcutAction)
    case duplicate(GlobalShortcutAction, GlobalShortcutAction)

    public var errorDescription: String? {
        switch self {
        case let .invalidKey(action):
            return "“\(action.title)”使用了不支持的按键"
        case let .missingPrimaryModifier(action):
            return "“\(action.title)”至少需要包含 Command、Option 或 Control"
        case let .unsupportedModifier(action):
            return "“\(action.title)”包含不支持的修饰键"
        case let .duplicate(first, second):
            return "“\(first.title)”和“\(second.title)”不能使用相同快捷键"
        }
    }
}

public final class GlobalShortcutConfigurationStore: @unchecked Sendable {
    public static let storageKey = "global-shortcuts.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> GlobalShortcutConfiguration {
        guard let data = defaults.data(forKey: Self.storageKey),
              let configuration = try? JSONDecoder().decode(
                  GlobalShortcutConfiguration.self,
                  from: data
              ),
              (try? configuration.validate()) != nil else {
            return .default
        }
        return configuration
    }

    public func save(_ configuration: GlobalShortcutConfiguration) throws {
        try configuration.validate()
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.storageKey)
    }
}
