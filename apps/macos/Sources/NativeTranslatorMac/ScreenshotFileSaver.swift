import AppKit
import UniformTypeIdentifiers

@MainActor
struct ScreenshotFileSaver {
    typealias DestinationChooser = @MainActor (_ suggestedFilename: String) -> URL?

    private let chooseDestination: DestinationChooser

    init(chooseDestination: @escaping DestinationChooser = Self.presentSavePanel) {
        self.chooseDestination = chooseDestination
    }

    @discardableResult
    func save(_ image: NSImage) throws -> Bool {
        guard let destination = chooseDestination("Polyglance Screenshot.png") else {
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
