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

enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case updateAvailable(version: String, displayVersion: String, releaseNotes: String?, isCritical: Bool)
    case downloading(progress: Double, receivedBytes: Int64, totalBytes: Int64)
    case extracting(progress: Double)
    case readyToRelaunch
    case failed(message: String)
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
final class InlineAppUpdateDriver: NSObject, SPUUserDriver {
    weak var updater: AppUpdater?

    var checkCancellation: (() -> Void)?
    var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    var readyToInstallReply: ((SPUUserUpdateChoice) -> Void)?
    var downloadCancellation: (() -> Void)?
    var expectedContentLength: Int64 = 0
    var bytesDownloaded: Int64 = 0

    init(updater: AppUpdater) {
        self.updater = updater
        super.init()
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.checkCancellation = cancellation
        updater?.state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.updateFoundReply = reply
        updater?.state = .updateAvailable(
            version: appcastItem.versionString,
            displayVersion: appcastItem.displayVersionString,
            releaseNotes: appcastItem.itemDescription,
            isCritical: appcastItem.isCriticalUpdate
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        var text: String?
        if let encodingName = downloadData.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let stringEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                text = String(data: downloadData.data, encoding: String.Encoding(rawValue: stringEncoding))
            }
        }
        if text == nil {
            text = String(data: downloadData.data, encoding: .utf8)
        }
        if let text, case .updateAvailable(let version, let displayVersion, _, let isCritical) = updater?.state {
            updater?.state = .updateAvailable(
                version: version,
                displayVersion: displayVersion,
                releaseNotes: text,
                isCritical: isCritical
            )
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updater?.state = .upToDate(checkedAt: Date())
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updater?.state = .failed(message: error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.downloadCancellation = cancellation
        self.bytesDownloaded = 0
        self.expectedContentLength = 0
        updater?.state = .downloading(progress: 0, receivedBytes: 0, totalBytes: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = Int64(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        self.bytesDownloaded += Int64(length)
        let progress = expectedContentLength > 0 ? min(1.0, Double(bytesDownloaded) / Double(expectedContentLength)) : 0.0
        updater?.state = .downloading(
            progress: progress,
            receivedBytes: bytesDownloaded,
            totalBytes: expectedContentLength
        )
    }

    func showDownloadDidStartExtractingUpdate() {
        updater?.state = .extracting(progress: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        updater?.state = .extracting(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.readyToInstallReply = reply
        updater?.state = .readyToRelaunch
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        updater?.state = .idle
    }

    func dismissUpdateInstallation() {
        checkCancellation = nil
        downloadCancellation = nil
        updateFoundReply = nil
        readyToInstallReply = nil
        switch updater?.state {
        case .upToDate, .failed:
            break
        default:
            updater?.state = .idle
        }
    }

    func showUpdateInFocus() {
        SettingsNavigation.shared.selectedTab = .about
        (AppDelegate.shared ?? (NSApp.delegate as? AppDelegate))?.showSettings(tab: .about)
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    @Published var state: AppUpdateState = .idle

    private let configuration: AppUpdateConfiguration
    private let updaterDelegate: AppUpdaterDelegateHelper
    private var driver: InlineAppUpdateDriver?
    private var updater: SPUUpdater?

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        let delegate = AppUpdaterDelegateHelper()
        delegate.defaultFeedURL = configuration.feedURL?.absoluteString
        self.updaterDelegate = delegate
        super.init()

        let driver = InlineAppUpdateDriver(updater: self)
        self.driver = driver
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: delegate
        )
        self.updater = updater

        if configuration.isConfigured {
            updater.automaticallyChecksForUpdates = true
            updater.updateCheckInterval = 21600
            do {
                try updater.start()
            } catch {
                NSLog("[AppUpdater] Failed to start updater: %@", error.localizedDescription)
            }
        }
    }

    func checkForUpdates() {
        guard configuration.isConfigured else {
            state = .failed(message: "当前构建未配置更新源（正式发布构建会通过 GitHub Release 自动配置安全更新）")
            return
        }

        state = .checking

        let store = AppConfigurationStore()
        let includeBeta = (try? store.load())?.includeBetaUpdates ?? false

        if includeBeta, let baseFeedURL = configuration.feedURL?.absoluteString {
            Task {
                if let betaFeedURL = await resolveGitHubReleaseAsset(baseFeedURL: baseFeedURL, assetName: "appcast.xml") {
                    self.updaterDelegate.customFeedURL = betaFeedURL
                }
                self.updater?.checkForUpdates()
            }
            return
        }

        self.updaterDelegate.customFeedURL = nil
        updater?.checkForUpdates()
    }

    func cancelCheck() {
        driver?.checkCancellation?()
        driver?.checkCancellation = nil
        state = .idle
    }

    func installUpdate() {
        driver?.updateFoundReply?(.install)
        driver?.updateFoundReply = nil
    }

    func skipUpdate() {
        driver?.updateFoundReply?(.skip)
        driver?.updateFoundReply = nil
        state = .idle
    }

    func dismissUpdate() {
        driver?.updateFoundReply?(.dismiss)
        driver?.updateFoundReply = nil
        state = .idle
    }

    func cancelDownload() {
        driver?.downloadCancellation?()
        driver?.downloadCancellation = nil
        state = .idle
    }

    func relaunchAndInstall() {
        driver?.readyToInstallReply?(.install)
        driver?.readyToInstallReply = nil
    }

    func postponeInstall() {
        driver?.readyToInstallReply?(.dismiss)
        driver?.readyToInstallReply = nil
        state = .idle
    }

    func setAutomaticChecks(enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
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
