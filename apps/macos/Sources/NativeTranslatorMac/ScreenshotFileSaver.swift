import AppKit
import UniformTypeIdentifiers

@MainActor
struct ScreenshotFileSaver {
    typealias DestinationChooser = @MainActor (_ suggestedFilename: String) -> URL?

    private let now: @MainActor () -> Date
    private let timeZone: TimeZone
    private let chooseDestination: DestinationChooser

    init() {
        self.init(
            now: Date.init,
            timeZone: .current,
            chooseDestination: Self.presentSavePanel
        )
    }

    init(chooseDestination: @escaping DestinationChooser) {
        self.init(now: Date.init, timeZone: .current, chooseDestination: chooseDestination)
    }

    init(
        now: @escaping @MainActor () -> Date,
        timeZone: TimeZone,
        chooseDestination: @escaping DestinationChooser
    ) {
        self.now = now
        self.timeZone = timeZone
        self.chooseDestination = chooseDestination
    }

    static func suggestedFilename(at date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return "Polyglance Screenshot \(formatter.string(from: date)).png"
    }

    @discardableResult
    func save(_ image: NSImage) throws -> Bool {
        let filename = Self.suggestedFilename(at: now(), timeZone: timeZone)
        guard let destination = chooseDestination(filename) else {
            return false
        }
        guard let data = ImagePasteboard.pngData(for: image) else {
            throw ScreenshotFileSaveError.imageEncodingFailed
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ScreenshotFileSaveError.writeFailed(error.localizedDescription)
        }
        return true
    }

    private static func presentSavePanel(suggestedFilename: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedFilename
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url
    }
}

private enum ScreenshotFileSaveError: LocalizedError {
    case imageEncodingFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "无法将截图编码为 PNG"
        case let .writeFailed(message):
            return "无法保存截图：\(message)"
        }
    }
}
