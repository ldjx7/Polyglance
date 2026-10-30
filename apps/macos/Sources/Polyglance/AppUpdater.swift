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
    var didFinishCycle: ((Error?) -> Void)?
    var localPackageURL: URL?

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        if let localPackageURL { request.url = localPackageURL }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        didFinishCycle?(error)
    }

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
        updater?.clearCheckTimeout()
        if updater?.installingCachedUpdate == true {
            reply(.install)
            return
        }
        let automatic = updater?.isAutomaticSession == true
        updater?.foundUpdate(appcastItem, automatically: automatic)
        reply(.dismiss)
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
        updater?.clearCheckTimeout()
        updater?.state = updater?.hasPreparedUpdate == true ? .readyToRelaunch : .upToDate(checkedAt: Date())
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        updater?.clearCheckTimeout()
        updater?.state = .failed(message: error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.downloadCancellation = cancellation
        self.bytesDownloaded = 0
        self.expectedContentLength = 0
        if updater?.installingCachedUpdate == true { return }
        updater?.state = .downloading(progress: 0, receivedBytes: 0, totalBytes: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = Int64(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        self.bytesDownloaded += Int64(length)
        if updater?.installingCachedUpdate == true { return }
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
        if updater?.installingCachedUpdate == true {
            reply(.install)
        } else {
            self.readyToInstallReply = reply
            updater?.state = .readyToRelaunch
        }
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
        updater?.clearCheckTimeout()
        if case .checking = updater?.state { updater?.state = .idle }
    }

    func showUpdateInFocus() {
        guard updater?.isAutomaticSession != true, updater?.installingCachedUpdate != true else { return }
        SettingsNavigation.shared.selectedTab = .about
        guard let appDelegate = (AppDelegate.shared ?? (NSApp.delegate as? AppDelegate)) else { return }
        if appDelegate.isSettingsWindowVisible {
            return
        }
        appDelegate.showSettings(tab: .about)
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
    private var checkTimeoutTask: Task<Void, Never>?
    private var automaticTask: Task<Void, Never>?
    private var automaticChecksEnabled = false
    private var nextAutomaticCheck = Date.distantPast
    private var canPresentUpdatePrompt: () -> Bool = { false }
    private var cachedUpdate: CachedAppUpdate?
    private var downloadTask: Task<Void, Never>?
    private var foundItem: SUAppcastItem?
    private var updateWindow: NSPanel?
    private var notifiedVersions = Set<String>()
    private var cacheServer: CachedUpdateServer?
    private(set) var installingCachedUpdate = false
    private(set) var isAutomaticSession = false
    private var checkGeneration = 0
    var hasPreparedUpdate: Bool {
        guard let cachedUpdate else { return false }
        return accepts(cachedUpdate.item) && FileManager.default.fileExists(atPath: cachedUpdate.package.path)
    }

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        let delegate = AppUpdaterDelegateHelper()
        delegate.defaultFeedURL = configuration.feedURL?.absoluteString
        self.updaterDelegate = delegate
        super.init()
        delegate.didFinishCycle = { [weak self] error in
            guard let self else { return }
            if self.installingCachedUpdate {
                self.installingCachedUpdate = false
                self.cacheServer?.stop()
                self.cacheServer = nil
                self.updaterDelegate.localPackageURL = nil
                self.updaterDelegate.customFeedURL = nil
                if let error { self.state = .failed(message: error.localizedDescription) }
                return
            }
            guard self.isAutomaticSession else { return }
            self.clearCheckTimeout()
            self.isAutomaticSession = false
            if let error {
                if (error as NSError).code == Int(SUError.noUpdateError.rawValue) {
                    self.state = self.hasPreparedUpdate ? .readyToRelaunch : .upToDate(checkedAt: Date())
                } else {
                    self.state = .failed(message: error.localizedDescription)
                }
            } else if case .checking = self.state {
                self.state = .idle
            }
        }

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
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            updater.updateCheckInterval = 21600
            do {
                try updater.start()
            } catch {
                NSLog("[AppUpdater] Failed to start updater: %@", error.localizedDescription)
            }
        }
    }

    func clearCheckTimeout() {
        checkTimeoutTask?.cancel()
        checkTimeoutTask = nil
    }

    private func armCheckTimeout() {
        clearCheckTimeout()
        checkTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            if case .checking = self?.state {
                self?.state = .failed(message: "检查更新超时，请稍后重试")
            }
        }
    }

    func checkForUpdates() {
        guard configuration.isConfigured else {
            state = .failed(message: "当前构建未配置更新源（正式发布构建会通过 GitHub Release 自动配置安全更新）")
            return
        }

        if let cachedUpdate, downloadTask == nil, accepts(cachedUpdate.item),
           FileManager.default.fileExists(atPath: cachedUpdate.package.path) {
            showPreparedUpdatePrompt(userInitiated: true)
            return
        }
        if case .checking = state { return }
        guard downloadTask == nil, !installingCachedUpdate, updater?.canCheckForUpdates == true else { return }
        isAutomaticSession = false
        Task { await performCheck(automatically: false) }
    }

    private func performCheck(automatically: Bool) async {
        checkGeneration += 1
        let generation = checkGeneration
        state = .checking
        armCheckTimeout()

        let store = AppConfigurationStore()
        let includeBeta = (try? store.load())?.includeBetaUpdates ?? false

        if includeBeta, let baseFeedURL = configuration.feedURL?.absoluteString {
            updaterDelegate.customFeedURL = await resolveGitHubReleaseAsset(baseFeedURL: baseFeedURL, assetName: "appcast.xml")
        } else {
            updaterDelegate.customFeedURL = nil
        }
        guard generation == checkGeneration else { return }
        guard !automatically || automaticChecksEnabled else {
            clearCheckTimeout()
            state = .idle
            return
        }
        guard updater?.canCheckForUpdates == true else { return }
        isAutomaticSession = automatically
        if automatically {
            updater?.checkForUpdatesInBackground()
        } else {
            updater?.checkForUpdates()
        }
    }

    func cancelCheck() {
        checkGeneration += 1
        clearCheckTimeout()
        driver?.checkCancellation?()
        driver?.checkCancellation = nil
        state = .idle
    }

    func foundUpdate(_ item: SUAppcastItem, automatically: Bool) {
        guard accepts(item) else { state = cachedUpdate == nil ? .idle : .readyToRelaunch; return }
        foundItem = item
        if let cachedUpdate,
           SUStandardVersionComparator.default.compareVersion(item.versionString, toVersion: cachedUpdate.item.versionString) != .orderedDescending {
            state = .readyToRelaunch
            if !automatically { showPreparedUpdatePrompt(userInitiated: true) }
            return
        }
        state = .updateAvailable(version: item.versionString, displayVersion: item.displayVersionString,
                                 releaseNotes: item.itemDescription, isCritical: item.isCriticalUpdate)
        if automatically, !item.isInformationOnlyUpdate { installUpdate() }
    }

    func installUpdate() {
        guard downloadTask == nil, !installingCachedUpdate else { return }
        if let cachedUpdate, foundItem?.versionString == cachedUpdate.item.versionString {
            showPreparedUpdatePrompt(userInitiated: true)
            return
        }
        guard let item = foundItem, let url = item.fileURL, url.scheme == "https",
              let publicKey = configuration.publicKey else { return }
        let userInitiated = !isAutomaticSession
        var feedURL = URL(string: updaterDelegate.customFeedURL ?? "") ?? configuration.feedURL
        if url.host == "github.com", url.pathComponents.contains("download") {
            feedURL = url.deletingLastPathComponent().appendingPathComponent("appcast.xml")
        }
        guard let feedURL else { return }
        state = .downloading(progress: 0, receivedBytes: 0, totalBytes: 0)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let owner = self
            let delegate = UpdateDownloadProgress { received, total in
                Task { @MainActor in
                    owner.state = .downloading(progress: total > 0 ? min(1, Double(received) / Double(total)) : 0,
                                               receivedBytes: received, totalBytes: total)
                }
            }
            let settings = URLSessionConfiguration.default
            settings.timeoutIntervalForResource = 900
            let session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel(); self.downloadTask = nil }
            var package: URL?
            do {
                let (feed, feedResponse) = try await session.data(from: feedURL)
                guard (feedResponse as? HTTPURLResponse)?.statusCode == 200, feed.count < 4_194_304 else { throw URLError(.badServerResponse) }
                let (temporary, response) = try await session.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: CachedAppUpdate.directory, withIntermediateDirectories: true)
                let destination = CachedAppUpdate.directory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                package = destination
                try FileManager.default.moveItem(at: temporary, to: destination)
                let prepared = CachedAppUpdate(item: item, package: destination, feed: feed)
                try await Task.detached { try prepared.validate(publicKey: publicKey) }.value
                try Task.checkCancellation()
                try prepared.save()
                let previous = self.cachedUpdate
                self.cachedUpdate = prepared
                if previous?.item.versionString != item.versionString { self.updateWindow?.close() }
                package = nil
                if let previous, previous.package != destination { try? FileManager.default.removeItem(at: previous.package) }
                self.state = .readyToRelaunch
                if userInitiated || self.canPresentUpdatePrompt() { self.showPreparedUpdatePrompt(userInitiated: userInitiated) }
            } catch {
                if let package { try? FileManager.default.removeItem(at: package) }
                if Task.isCancelled { self.state = self.cachedUpdate == nil ? .idle : .readyToRelaunch }
                else { self.state = .failed(message: error.localizedDescription) }
            }
        }
    }

    func skipUpdate() {
        isAutomaticSession = false
        if let foundItem { UserDefaults.standard.set(foundItem.versionString, forKey: "update.skippedBuild") }
        state = .idle
    }

    func dismissUpdate() { isAutomaticSession = false; state = .idle }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func relaunchAndInstall() {
        guard !installingCachedUpdate, downloadTask == nil, let cachedUpdate else { return }
        updateWindow?.close()
        updateWindow = nil
        installingCachedUpdate = true
        state = .extracting(progress: 0)
        Task { [weak self] in
            guard let self, let publicKey = self.configuration.publicKey else { return }
            do {
                try await Task.detached { try cachedUpdate.validate(publicKey: publicKey) }.value
                let server = CachedUpdateServer(update: cachedUpdate)
                self.cacheServer = server
                self.updaterDelegate.customFeedURL = try await server.start().absoluteString
                self.updaterDelegate.localPackageURL = server.packageURL
                self.isAutomaticSession = false
                self.updater?.checkForUpdates()
            } catch {
                self.installingCachedUpdate = false
                self.cacheServer?.stop()
                self.cacheServer = nil
                self.updaterDelegate.localPackageURL = nil
                self.updaterDelegate.customFeedURL = nil
                if (try? cachedUpdate.validate(publicKey: publicKey)) == nil {
                    CachedAppUpdate.clear()
                    self.cachedUpdate = nil
                }
                self.state = .failed(message: error.localizedDescription)
            }
        }
    }

    func postponeInstall() {
        updateWindow?.close()
        updateWindow = nil
        state = .readyToRelaunch
    }

    func showPreparedUpdatePrompt(userInitiated: Bool = false) {
        guard let cachedUpdate, !installingCachedUpdate else { return }
        if let updateWindow {
            if userInitiated { updateWindow.makeKeyAndOrderFront(nil) }
            return
        }
        notifiedVersions.insert(cachedUpdate.item.versionString)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 145),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Polyglance 更新已就绪"
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "版本 \(cachedUpdate.item.displayVersionString) 已下载并校验完成。")
        title.frame = NSRect(x: 20, y: 88, width: 430, height: 24)
        title.font = .systemFont(ofSize: 15)
        let details = NSButton(title: "更新详情", target: self, action: #selector(openUpdateDetails))
        details.frame = NSRect(x: 16, y: 25, width: 100, height: 32)
        let later = NSButton(title: "下次启动安装", target: self, action: #selector(closeUpdatePrompt))
        later.frame = NSRect(x: 178, y: 25, width: 130, height: 32)
        later.keyEquivalent = "\r"
        let restart = NSButton(title: "立即重启更新", target: self, action: #selector(restartFromPrompt))
        restart.frame = NSRect(x: 318, y: 25, width: 132, height: 32)
        for button in [details, later, restart] { button.bezelStyle = .rounded; panel.contentView?.addSubview(button) }
        panel.contentView?.addSubview(title)
        panel.center()
        updateWindow = panel
        NotificationCenter.default.addObserver(self, selector: #selector(updatePromptClosed), name: NSWindow.willCloseNotification, object: panel)
        if userInitiated { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
    }

    @objc private func openUpdateDetails() {
        guard let version = cachedUpdate?.item.displayVersionString,
              let url = URL(string: "https://github.com/ldjx7/Polyglance/releases/tag/")?.appendingPathComponent("v" + version) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func closeUpdatePrompt() { postponeInstall() }
    @objc private func restartFromPrompt() { relaunchAndInstall() }
    @objc private func updatePromptClosed(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: notification.object)
        if let window = notification.object as? NSPanel, window === updateWindow { updateWindow = nil }
    }

    func setAutomaticChecks(enabled: Bool) {
        if enabled && !automaticChecksEnabled { nextAutomaticCheck = .distantPast }
        automaticChecksEnabled = enabled
    }

    private func accepts(_ item: SUAppcastItem) -> Bool {
        let config = try? AppConfigurationStore().load()
        return (config?.includeBetaUpdates == true || !item.displayVersionString.localizedCaseInsensitiveContains("beta"))
            && UserDefaults.standard.string(forKey: "update.skippedBuild") != item.versionString
    }

    func startAutomaticUpdates(enabled: Bool, canPresent: @escaping () -> Bool) {
        setAutomaticChecks(enabled: enabled)
        canPresentUpdatePrompt = canPresent
        guard configuration.isConfigured, automaticTask == nil,
              Bundle.main.bundleIdentifier != "io.polyglance.macos.dev" else { return }
        automaticTask = Task { [weak self] in
            guard let self, let publicKey = self.configuration.publicKey else { return }
            if let saved = try? await Task.detached(operation: { try CachedAppUpdate.load(publicKey: publicKey) }).value {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                if SUStandardVersionComparator.default.compareVersion(saved.item.versionString, toVersion: build) == .orderedDescending,
                   self.accepts(saved.item) {
                    self.cachedUpdate = saved
                    self.relaunchAndInstall()
                } else {
                    CachedAppUpdate.clear()
                    try? FileManager.default.removeItem(at: saved.package)
                }
            }
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                if self.automaticChecksEnabled, !self.installingCachedUpdate, self.downloadTask == nil {
                    if let cached = self.cachedUpdate, self.accepts(cached.item),
                       !self.notifiedVersions.contains(cached.item.versionString), self.canPresentUpdatePrompt() {
                        self.showPreparedUpdatePrompt()
                    }
                    if Date() >= self.nextAutomaticCheck, self.updater?.canCheckForUpdates == true {
                        if case .checking = self.state {} else {
                            self.nextAutomaticCheck = Date().addingTimeInterval(21600)
                            await self.performCheck(automatically: true)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
        request.timeoutInterval = 8

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
