import CoreGraphics
import Foundation

enum ScreenRecordingFormat: String, CaseIterable, Codable, Sendable {
    case mp4
    case gif

    var displayName: String {
        switch self {
        case .mp4:
            return "MP4"
        case .gif:
            return "GIF"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var supportsAudio: Bool {
        self == .mp4
    }

    var detail: String {
        switch self {
        case .mp4:
            return "通用视频，可包含系统声音和麦克风"
        case .gif:
            return "无声音动画，适合短操作演示"
        }
    }
}

enum ScreenRecordingQuality: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case high

    var displayName: String {
        switch self {
        case .compact:
            return "体积优先"
        case .standard:
            return "标准"
        case .high:
            return "高质量"
        }
    }

    var detail: String {
        switch self {
        case .compact:
            return "较低帧率与分辨率，文件更小"
        case .standard:
            return "画质、流畅度和体积均衡"
        case .high:
            return "更高帧率与分辨率，文件更大"
        }
    }

    func profile(for format: ScreenRecordingFormat) -> ScreenRecordingEncodingProfile {
        switch (self, format) {
        case (.compact, .mp4):
            return ScreenRecordingEncodingProfile(
                frameRate: 24,
                maxDimension: 1_920,
                bitsPerPixelPerFrame: 0.07,
                minimumVideoBitrate: 1_000_000,
                maximumVideoBitrate: 12_000_000
            )
        case (.standard, .mp4):
            return ScreenRecordingEncodingProfile(
                frameRate: 30,
                maxDimension: 2_560,
                bitsPerPixelPerFrame: 0.10,
                minimumVideoBitrate: 2_000_000,
                maximumVideoBitrate: 24_000_000
            )
        case (.high, .mp4):
            return ScreenRecordingEncodingProfile(
                frameRate: 60,
                maxDimension: 3_840,
                bitsPerPixelPerFrame: 0.13,
                minimumVideoBitrate: 4_000_000,
                maximumVideoBitrate: 50_000_000
            )
        case (.compact, .gif):
            return ScreenRecordingEncodingProfile(
                frameRate: 8,
                maxDimension: 960,
                maximumDuration: 90,
                maximumFrameCount: 720
            )
        case (.standard, .gif):
            return ScreenRecordingEncodingProfile(
                frameRate: 12,
                maxDimension: 1_280,
                maximumDuration: 60,
                maximumFrameCount: 720
            )
        case (.high, .gif):
            return ScreenRecordingEncodingProfile(
                frameRate: 15,
                maxDimension: 1_600,
                maximumDuration: 45,
                maximumFrameCount: 675
            )
        }
    }
}

enum ScreenRecordingDelay: Int, CaseIterable, Codable, Sendable {
    case immediate = 0
    case threeSeconds = 3
    case fiveSeconds = 5

    var displayName: String {
        switch self {
        case .immediate:
            return "无延时"
        case .threeSeconds:
            return "3 秒"
        case .fiveSeconds:
            return "5 秒"
        }
    }
}

enum ScreenRecordingFrameRateChoice: Int, CaseIterable, Sendable {
    case five = 5
    case sixteen = 16
    case twentyFour = 24
    case thirty = 30
    case sixty = 60
}

enum ScreenRecordingFrameRatePolicy {
    static func choices(for format: ScreenRecordingFormat) -> [Int] {
        switch format {
        case .mp4:
            return ScreenRecordingFrameRateChoice.allCases.map(\.rawValue)
        case .gif:
            return [
                ScreenRecordingFrameRateChoice.five.rawValue,
                ScreenRecordingFrameRateChoice.sixteen.rawValue,
            ]
        }
    }

    static func normalized(_ requested: Int, for format: ScreenRecordingFormat) -> Int {
        let supported = choices(for: format)
        return supported.min { left, right in
            let leftDistance = abs(left - requested)
            let rightDistance = abs(right - requested)
            return leftDistance == rightDistance ? left > right : leftDistance < rightDistance
        } ?? ScreenRecordingFrameRateChoice.thirty.rawValue
    }
}

enum RecordingSettingsPresentation {
    static let saveLocationToggleTitle = "点击保存时询问保存位置"

    static func qualitySummary(_ settings: RecordingSettings) -> String {
        let profile = settings.quality.profile(for: settings.format)
        if let duration = profile.maximumDuration {
            return "\(settings.quality.detail)：\(settings.frameRate) FPS、最长边 \(profile.maxDimension) px、最长 \(Int(duration)) 秒。"
        }
        return "\(settings.quality.detail)：\(settings.frameRate) FPS、最长边 \(profile.maxDimension) px。"
    }
}

enum RecordingReviewSaveAction: Equatable {
    case save
    case quickSave
}

enum RecordingReviewDestinationMode: Equatable {
    case prompt
    case defaultDirectory
}

enum RecordingReviewDestinationPolicy {
    static func mode(
        for action: RecordingReviewSaveAction,
        asksForSaveLocation: Bool
    ) -> RecordingReviewDestinationMode {
        switch action {
        case .save where asksForSaveLocation:
            return .prompt
        case .save, .quickSave:
            return .defaultDirectory
        }
    }

    static func revealsInFinder(after action: RecordingReviewSaveAction) -> Bool {
        action == .save
    }
}

struct RecordingReviewArtifactStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func persistForClipboard(
        sourceURL: URL,
        directory: URL,
        format: ScreenRecordingFormat
    ) throws -> URL {
        let destination = try RecordingDestinationPolicy.availableURL(
            directory: directory,
            suggestedFilename: RecordingDestinationPolicy.suggestedFilename(format: format),
            fileManager: fileManager
        )
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }
}

struct RecordingFileInstaller {
    typealias Replace = (_ stagedURL: URL, _ destinationURL: URL) throws -> Void

    private let fileManager: FileManager
    private let replace: Replace

    init(
        fileManager: FileManager = .default,
        replace: Replace? = nil
    ) {
        self.fileManager = fileManager
        self.replace = replace ?? { stagedURL, destinationURL in
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: stagedURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagedURL, to: destinationURL)
            }
        }
    }

    /// Copies into the destination directory first, then atomically swaps the
    /// completed sibling into place. A failed copy or replacement never removes
    /// an existing user file.
    func install(source: URL, at destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).native-translator-staging-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: source, to: stagingURL)
        try replace(stagingURL, destination)
    }
}

struct ScreenRecordingEncodingProfile: Equatable, Sendable {
    let frameRate: Int
    let maxDimension: Int
    let bitsPerPixelPerFrame: Double
    let minimumVideoBitrate: Int
    let maximumVideoBitrate: Int
    let maximumDuration: TimeInterval?
    let maximumFrameCount: Int?

    init(
        frameRate: Int,
        maxDimension: Int,
        bitsPerPixelPerFrame: Double = 0,
        minimumVideoBitrate: Int = 0,
        maximumVideoBitrate: Int = 0,
        maximumDuration: TimeInterval? = nil,
        maximumFrameCount: Int? = nil
    ) {
        self.frameRate = frameRate
        self.maxDimension = maxDimension
        self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
        self.minimumVideoBitrate = minimumVideoBitrate
        self.maximumVideoBitrate = maximumVideoBitrate
        self.maximumDuration = maximumDuration
        self.maximumFrameCount = maximumFrameCount
    }

    func outputSize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return .zero
        }
        let longestSide = max(sourceSize.width, sourceSize.height)
        let scale = min(1, CGFloat(maxDimension) / longestSide)
        return CGSize(
            width: Self.evenDimension(sourceSize.width * scale),
            height: Self.evenDimension(sourceSize.height * scale)
        )
    }

    func videoBitrate(for outputSize: CGSize, frameRate overrideFrameRate: Int? = nil) -> Int {
        guard bitsPerPixelPerFrame > 0,
              minimumVideoBitrate > 0,
              maximumVideoBitrate >= minimumVideoBitrate else {
            return 0
        }
        let fps = max(1, overrideFrameRate ?? frameRate)
        let estimate = Int(
            (Double(outputSize.width) * Double(outputSize.height) * Double(fps) * bitsPerPixelPerFrame)
                .rounded()
        )
        return min(maximumVideoBitrate, max(minimumVideoBitrate, estimate))
    }

    private static func evenDimension(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded()))
        return CGFloat(rounded - rounded % 2)
    }
}

struct RecordingSettings: Codable, Equatable, Sendable {
    var format: ScreenRecordingFormat
    var quality: ScreenRecordingQuality
    var asksForSaveLocation: Bool
    var saveDirectoryPath: String?
    var capturesSystemAudio: Bool
    var capturesMicrophone: Bool
    var showsCursor: Bool
    var countdownDelay: ScreenRecordingDelay
    var frameRate: Int

    init(
        format: ScreenRecordingFormat,
        quality: ScreenRecordingQuality,
        asksForSaveLocation: Bool,
        saveDirectoryPath: String?,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool,
        showsCursor: Bool,
        countdownDelay: ScreenRecordingDelay = .threeSeconds,
        frameRate: Int? = nil
    ) {
        self.format = format
        self.quality = quality
        self.asksForSaveLocation = asksForSaveLocation
        self.saveDirectoryPath = saveDirectoryPath
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.countdownDelay = countdownDelay
        self.frameRate = frameRate ?? quality.profile(for: format).frameRate
    }

    static let `default` = RecordingSettings(
        format: .mp4,
        quality: .standard,
        asksForSaveLocation: true,
        saveDirectoryPath: nil,
        capturesSystemAudio: true,
        capturesMicrophone: false,
        showsCursor: true,
        countdownDelay: .threeSeconds,
        frameRate: 30
    )

    private enum CodingKeys: String, CodingKey {
        case format
        case quality
        case asksForSaveLocation
        case saveDirectoryPath
        case capturesSystemAudio
        case capturesMicrophone
        case showsCursor
        case countdownDelay
        case frameRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(ScreenRecordingFormat.self, forKey: .format)
        quality = try container.decode(ScreenRecordingQuality.self, forKey: .quality)
        asksForSaveLocation = try container.decode(Bool.self, forKey: .asksForSaveLocation)
        saveDirectoryPath = try container.decodeIfPresent(String.self, forKey: .saveDirectoryPath)
        capturesSystemAudio = try container.decode(Bool.self, forKey: .capturesSystemAudio)
        capturesMicrophone = try container.decode(Bool.self, forKey: .capturesMicrophone)
        showsCursor = try container.decode(Bool.self, forKey: .showsCursor)
        countdownDelay = try container.decodeIfPresent(
            ScreenRecordingDelay.self,
            forKey: .countdownDelay
        ) ?? .threeSeconds
        frameRate = try container.decodeIfPresent(Int.self, forKey: .frameRate)
            ?? quality.profile(for: format).frameRate
    }
}

final class RecordingSettingsStore: @unchecked Sendable {
    static let storageKey = "screen-recording.settings.v1"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.storageKey),
              let settings = try? decoder.decode(RecordingSettings.self, from: data) else {
            return .default
        }
        return settings
    }

    func save(_ settings: RecordingSettings) throws {
        defaults.set(try encoder.encode(settings), forKey: Self.storageKey)
    }

    func resolvedSaveDirectory(fileManager: FileManager = .default) -> URL {
        let settings = load()
        if let path = settings.saveDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
    }
}

enum RecordingDestinationPolicy {
    static func suggestedFilename(
        format: ScreenRecordingFormat,
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Polyglance Recording \(formatter.string(from: date)).\(format.fileExtension)"
    }

    static func availableURL(
        directory: URL,
        suggestedFilename: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let requested = directory.appendingPathComponent(suggestedFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: requested.path) else {
            return requested
        }

        let filename = requested.deletingPathExtension().lastPathComponent
        let pathExtension = requested.pathExtension
        var suffix = 2
        while true {
            let candidateName = pathExtension.isEmpty
                ? "\(filename) \(suffix)"
                : "\(filename) \(suffix).\(pathExtension)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
