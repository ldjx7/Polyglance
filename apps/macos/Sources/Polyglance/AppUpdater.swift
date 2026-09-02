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
final class AppUpdaterDelegateHelper: NSObject, SPUUpdaterDelegate {
    var customFeedURL: String?
    var defaultFeedURL: String?

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let store = AppConfigurationStore()
        let includeBeta = (try? store.load())?.includeBetaUpdates ?? false
        return includeBeta ? ["beta"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        if let custom = customFeedURL {
            return custom
        }
        return defaultFeedURL
    }
}

@MainActor
final class AppUpdater: NSObject {
    private let configuration: AppUpdateConfiguration
    private let updaterDelegate: AppUpdaterDelegateHelper
    private let updaterController: SPUStandardUpdaterController

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        let delegate = AppUpdaterDelegateHelper()
        delegate.defaultFeedURL = configuration.feedURL?.absoluteString
        self.updaterDelegate = delegate
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.updaterController = controller
        super.init()

        if configuration.isConfigured {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.updateCheckInterval = 21600
            controller.startUpdater()
        }
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

        let store = AppConfigurationStore()
        let includeBeta = (try? store.load())?.includeBetaUpdates ?? false

        if includeBeta, let baseFeedURL = configuration.feedURL?.absoluteString {
            Task {
                if let betaFeedURL = await resolveGitHubReleaseAsset(baseFeedURL: baseFeedURL, assetName: "appcast.xml") {
                    self.updaterDelegate.customFeedURL = betaFeedURL
                }
                self.updaterController.checkForUpdates(nil)
            }
            return
        }

        self.updaterDelegate.customFeedURL = nil
        updaterController.checkForUpdates(nil)
    }

    private func resolveGitHubReleaseAsset(baseFeedURL: String, assetName: String) async -> String? {
        guard let url = URL(string: baseFeedURL),
              url.host?.lowercased() == "github.com" else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 6,
              segments[2].lowercased() == "releases",
              segments[3].lowercased() == "latest",
              segments[4].lowercased() == "download" else {
            return nil
        }
        let owner = segments[0]
        let repo = segments[1]
        guard let apiUrl = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20") else {
            return nil
        }

        var request = URLRequest(url: apiUrl)
        request.setValue("Polyglance-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for release in releases {
            if (release["draft"] as? Bool) == true {
                continue
            }
            guard let assets = release["assets"] as? [[String: Any]] else {
                continue
            }
            for asset in assets {
                if let name = asset["name"] as? String,
                   name.caseInsensitiveCompare(assetName) == .orderedSame,
                   let downloadUrl = asset["browser_download_url"] as? String {
                    return downloadUrl
                }
            }
        }
        return nil
    }
}
