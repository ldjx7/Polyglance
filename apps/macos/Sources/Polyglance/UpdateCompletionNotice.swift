import AppKit
import Sparkle

@MainActor
enum UpdateCompletionNotice {
    static func presentIfNeeded() {
        let defaults = UserDefaults.standard
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !version.isEmpty, !build.isEmpty else { return }
        let previousVersion = defaults.string(forKey: "update.lastLaunchedVersion")
        let previousBuild = defaults.string(forKey: "update.lastLaunchedBuild") ?? "0"
        defaults.set(version, forKey: "update.lastLaunchedVersion")
        defaults.set(build, forKey: "update.lastLaunchedBuild")
        guard let previousVersion, !defaults.bool(forKey: "update.suppressSuccessNotice") else { return }
        let comparator = SUStandardVersionComparator()
        let versionOrder = comparator.compareVersion(version, toVersion: previousVersion)
        guard versionOrder == .orderedDescending
                || (versionOrder == .orderedSame && comparator.compareVersion(build, toVersion: previousBuild) == .orderedDescending) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let alert = NSAlert()
            alert.messageText = "Polyglance 升级成功"
            alert.informativeText = "Polyglance 已成功升级至 \(version)"
            alert.addButton(withTitle: "更新详情")
            alert.addButton(withTitle: "关闭")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "不再提示"
            let response = alert.runModal()
            defaults.set(alert.suppressionButton?.state == .on, forKey: "update.suppressSuccessNotice")
            if response == .alertFirstButtonReturn {
                let url = URL(string: "https://github.com/ldjx7/Polyglance/releases/tag/")!
                    .appendingPathComponent("v" + version)
                NSWorkspace.shared.open(url)
            }
        }
    }
}
