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
    case openTranslator
    case ocrTranslate
    case ocrWorkspace
    case ocrTranslationCard
    case screenshotAndCopy
    case translateAndReplace

    public var title: String {
        switch self {
        case .translateSelection:
            return "划词翻译"
        case .captureSelection:
            return "读取选区，不自动翻译"
        case .screenshotAndPin:
            return "截图工具"
        case .screenshotAndCopy:
            return "截图并复制"
        case .translateAndReplace:
            return "划词翻译并替换"
        case .pinClipboardImage:
            return "贴出剪贴板图片"
        case .longScreenshot:
            return "长截图"
        case .screenRecording:
            return "区域录屏"
        case .restoreMostRecentPin:
            return "恢复最近关闭的贴图"
        case .screenTranslation:
            return "截图翻译"
        case .openTranslator:
            return "输入翻译 (主窗口)"
        case .ocrTranslate:
            return "OCR翻译"
        case .ocrWorkspace:
            return "文字识别"
        case .ocrTranslationCard:
            return "双语对照卡"
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
        case .openTranslator: return 9
        case .ocrTranslate: return 10
        case .ocrWorkspace: return 11
        case .ocrTranslationCard: return 12
        case .screenshotAndCopy: return 13
        case .translateAndReplace: return 14
        }
    }
}

public struct GlobalShortcutConfiguration: Codable, Equatable, Sendable {
    public var translateSelection: RecordedShortcut?
    public var captureSelection: RecordedShortcut?
    public var screenshotAndPin: RecordedShortcut?
    public var screenshotAndCopy: RecordedShortcut?
    public var pinClipboardImage: RecordedShortcut?
    public var longScreenshot: RecordedShortcut?
    public var screenRecording: RecordedShortcut?
    public var restoreMostRecentPin: RecordedShortcut?
    public var screenTranslation: RecordedShortcut?
    public var openTranslator: RecordedShortcut?
    public var ocrTranslate: RecordedShortcut?
    public var ocrWorkspace: RecordedShortcut?
    public var ocrTranslationCard: RecordedShortcut?
    public var translateAndReplace: RecordedShortcut?

    public init(
        translateSelection: RecordedShortcut?,
        captureSelection: RecordedShortcut?,
        screenshotAndPin: RecordedShortcut?,
        screenshotAndCopy: RecordedShortcut? = nil,
        translateAndReplace: RecordedShortcut? = nil,
        pinClipboardImage: RecordedShortcut?,
        longScreenshot: RecordedShortcut?,
        screenRecording: RecordedShortcut?,
        restoreMostRecentPin: RecordedShortcut?,
        screenTranslation: RecordedShortcut?,
        openTranslator: RecordedShortcut? = nil,
        ocrTranslate: RecordedShortcut? = nil,
        ocrWorkspace: RecordedShortcut? = nil,
        ocrTranslationCard: RecordedShortcut? = nil
    ) {
        self.translateSelection = translateSelection
        self.captureSelection = captureSelection
        self.screenshotAndPin = screenshotAndPin
        self.screenshotAndCopy = screenshotAndCopy
        self.translateAndReplace = translateAndReplace
        self.pinClipboardImage = pinClipboardImage
        self.longScreenshot = longScreenshot
        self.screenRecording = screenRecording
        self.restoreMostRecentPin = restoreMostRecentPin
        self.screenTranslation = screenTranslation
        self.openTranslator = openTranslator
        self.ocrTranslate = ocrTranslate
        self.ocrWorkspace = ocrWorkspace
        self.ocrTranslationCard = ocrTranslationCard
    }

    public static let `default` = GlobalShortcutConfiguration(
        translateSelection: RecordedShortcut(keyCode: 20, modifiers: [.control, .shift]),
        captureSelection: nil,
        screenshotAndPin: RecordedShortcut(keyCode: 18, modifiers: [.control, .shift]),
        screenshotAndCopy: nil,
        translateAndReplace: nil,
        pinClipboardImage: RecordedShortcut(keyCode: 19, modifiers: [.control, .shift]),
        longScreenshot: nil,
        screenRecording: nil,
        restoreMostRecentPin: RecordedShortcut(keyCode: 23, modifiers: [.control, .shift]),
        screenTranslation: RecordedShortcut(keyCode: 21, modifiers: [.control, .shift]),
        openTranslator: nil,
        ocrTranslate: nil,
        ocrWorkspace: nil,
        ocrTranslationCard: nil
    )

    public static let legacyDefault = GlobalShortcutConfiguration(
        translateSelection: RecordedShortcut(keyCode: 2, modifiers: [.option]),
        captureSelection: RecordedShortcut(keyCode: 2, modifiers: [.option, .shift]),
        screenshotAndPin: RecordedShortcut(keyCode: 18, modifiers: [.option]),
        screenshotAndCopy: nil,
        translateAndReplace: nil,
        pinClipboardImage: RecordedShortcut(keyCode: 19, modifiers: [.option]),
        longScreenshot: RecordedShortcut(keyCode: 20, modifiers: [.option]),
        screenRecording: RecordedShortcut(keyCode: 21, modifiers: [.option]),
        restoreMostRecentPin: RecordedShortcut(keyCode: 23, modifiers: [.option]),
        screenTranslation: RecordedShortcut(keyCode: 22, modifiers: [.option]),
        openTranslator: nil,
        ocrTranslate: nil,
        ocrWorkspace: nil,
        ocrTranslationCard: nil
    )

    public subscript(action: GlobalShortcutAction) -> RecordedShortcut? {
        get {
            switch action {
            case .translateSelection: return translateSelection
            case .captureSelection: return captureSelection
            case .screenshotAndPin: return screenshotAndPin
            case .screenshotAndCopy: return screenshotAndCopy
            case .translateAndReplace: return translateAndReplace
            case .pinClipboardImage: return pinClipboardImage
            case .longScreenshot: return longScreenshot
            case .screenRecording: return screenRecording
            case .restoreMostRecentPin: return restoreMostRecentPin
            case .screenTranslation: return screenTranslation
            case .openTranslator: return openTranslator
            case .ocrTranslate: return ocrTranslate
            case .ocrWorkspace: return ocrWorkspace
            case .ocrTranslationCard: return ocrTranslationCard
            }
        }
        set {
            switch action {
            case .translateSelection: translateSelection = newValue
            case .captureSelection: captureSelection = newValue
            case .screenshotAndPin: screenshotAndPin = newValue
            case .screenshotAndCopy: screenshotAndCopy = newValue
            case .translateAndReplace: translateAndReplace = newValue
            case .pinClipboardImage: pinClipboardImage = newValue
            case .longScreenshot: longScreenshot = newValue
            case .screenRecording: screenRecording = newValue
            case .restoreMostRecentPin: restoreMostRecentPin = newValue
            case .screenTranslation: screenTranslation = newValue
            case .openTranslator: openTranslator = newValue
            case .ocrTranslate: ocrTranslate = newValue
            case .ocrWorkspace: ocrWorkspace = newValue
            case .ocrTranslationCard: ocrTranslationCard = newValue
            }
        }
    }

    public var allShortcuts: [RecordedShortcut] {
        GlobalShortcutAction.allCases.compactMap { self[$0] }
    }

    private enum CodingKeys: String, CodingKey {
        case translateSelection
        case captureSelection
        case screenshotAndPin
        case screenshotAndCopy
        case translateAndReplace
        case pinClipboardImage
        case longScreenshot
        case screenRecording
        case restoreMostRecentPin
        case screenTranslation
        case openTranslator
        case ocrTranslate
        case ocrWorkspace
        case ocrTranslationCard
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translateSelection = try container.decodeIfPresent(RecordedShortcut.self, forKey: .translateSelection)
        captureSelection = try container.decodeIfPresent(RecordedShortcut.self, forKey: .captureSelection)
        screenshotAndPin = try container.decodeIfPresent(RecordedShortcut.self, forKey: .screenshotAndPin)
        screenshotAndCopy = try container.decodeIfPresent(RecordedShortcut.self, forKey: .screenshotAndCopy)
        translateAndReplace = try container.decodeIfPresent(RecordedShortcut.self, forKey: .translateAndReplace)
        pinClipboardImage = try container.decodeIfPresent(RecordedShortcut.self, forKey: .pinClipboardImage)
        longScreenshot = try container.decodeIfPresent(RecordedShortcut.self, forKey: .longScreenshot)
        screenRecording = try container.decodeIfPresent(RecordedShortcut.self, forKey: .screenRecording)
        if container.contains(.restoreMostRecentPin) {
            restoreMostRecentPin = try container.decodeIfPresent(
                RecordedShortcut.self,
                forKey: .restoreMostRecentPin
            )
        } else {
            restoreMostRecentPin = Self.default.restoreMostRecentPin
        }
        screenTranslation = try container.decodeIfPresent(RecordedShortcut.self, forKey: .screenTranslation)
        openTranslator = try container.decodeIfPresent(RecordedShortcut.self, forKey: .openTranslator)
        ocrTranslate = try container.decodeIfPresent(RecordedShortcut.self, forKey: .ocrTranslate)
        ocrWorkspace = try container.decodeIfPresent(RecordedShortcut.self, forKey: .ocrWorkspace)
        ocrTranslationCard = try container.decodeIfPresent(RecordedShortcut.self, forKey: .ocrTranslationCard)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(translateSelection, forKey: .translateSelection)
        try container.encodeIfPresent(captureSelection, forKey: .captureSelection)
        try container.encodeIfPresent(screenshotAndPin, forKey: .screenshotAndPin)
        try container.encodeIfPresent(screenshotAndCopy, forKey: .screenshotAndCopy)
        try container.encodeIfPresent(translateAndReplace, forKey: .translateAndReplace)
        try container.encodeIfPresent(pinClipboardImage, forKey: .pinClipboardImage)
        try container.encodeIfPresent(longScreenshot, forKey: .longScreenshot)
        try container.encodeIfPresent(screenRecording, forKey: .screenRecording)
        try container.encode(restoreMostRecentPin, forKey: .restoreMostRecentPin)
        try container.encodeIfPresent(screenTranslation, forKey: .screenTranslation)
        try container.encodeIfPresent(openTranslator, forKey: .openTranslator)
        try container.encodeIfPresent(ocrTranslate, forKey: .ocrTranslate)
        try container.encodeIfPresent(ocrWorkspace, forKey: .ocrWorkspace)
        try container.encodeIfPresent(ocrTranslationCard, forKey: .ocrTranslationCard)
    }

    public func validate() throws {
        var owners: [RecordedShortcut: GlobalShortcutAction] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = self[action] else {
                continue
            }
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
        if configuration == .legacyDefault {
            let migrated = GlobalShortcutConfiguration.default
            defaults.set(try? JSONEncoder().encode(migrated), forKey: Self.storageKey)
            return migrated
        }
        return configuration
    }

    public func save(_ configuration: GlobalShortcutConfiguration) throws {
        try configuration.validate()
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.storageKey)
    }
}
