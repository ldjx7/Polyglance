import AppKit

enum SettingsBranding {
    static let name = "Polyglance"
    static let tagline = "原生翻译与截图工具"
}

enum SettingsApplicationPresentation {
    static let visibleActivationPolicy = NSApplication.ActivationPolicy.regular
    static let backgroundActivationPolicy = NSApplication.ActivationPolicy.accessory
}

enum SettingsWindowPlacement {
    static func centeredOrigin(windowSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - windowSize.width / 2,
            y: visibleFrame.midY - windowSize.height / 2
        )
    }

    @MainActor
    static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        window.setFrameOrigin(centeredOrigin(
            windowSize: window.frame.size,
            visibleFrame: screen.visibleFrame
        ))
    }
}

@MainActor
enum PolyglanceApplicationMenu {
    static func make(settingsTarget: AnyObject?) -> NSMenu {
        let mainMenu = NSMenu(title: "Main Menu")
        let applicationItem = NSMenuItem(title: SettingsBranding.name, action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: SettingsBranding.name)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let aboutItem = NSMenuItem(
            title: "关于 \(SettingsBranding.name)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)

        applicationMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(AppDelegate.showSettingsFromApplicationMenu),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = settingsTarget
        applicationMenu.addItem(settingsItem)

        applicationMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 \(SettingsBranding.name)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "全部显示",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        applicationMenu.addItem(showAllItem)

        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 \(SettingsBranding.name)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)

        return mainMenu
    }
}

@MainActor
final class SettingsWindowLifecycleDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
