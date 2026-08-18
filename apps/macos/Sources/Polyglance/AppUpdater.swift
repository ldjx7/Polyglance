import AppKit
import Foundation
import Sparkle

struct AppUpdateConfiguration: Equatable {
    let feedURL: URL?
    let publicKey: String?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        if let rawFeedURL = infoDictionary["SUFeedURL"] as? String,
           let url = URL(string: rawFeedURL),
           url.scheme?.lowercased() == "https" {
            feedURL = url
        } else {
            feedURL = nil
        }

        if let rawPublicKey = infoDictionary["SUPublicEDKey"] as? String {
            let trimmedKey = rawPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            publicKey = trimmedKey.isEmpty ? nil : trimmedKey
        } else {
            publicKey = nil
        }
    }

    var isConfigured: Bool {
        feedURL != nil && publicKey != nil
    }
}

@MainActor
final class AppUpdater {
    private let configuration: AppUpdateConfiguration
    private let updaterController: SPUStandardUpdaterController

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        updaterController = SPUStandardUpdaterController(
            startingUpdater: configuration.isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard configuration.isConfigured else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "当前构建未配置更新源"
            alert.informativeText = "正式发布构建会通过 GitHub Release 自动配置安全更新。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        updaterController.checkForUpdates(nil)
    }
}
