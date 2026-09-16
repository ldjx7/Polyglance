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
        let rawX = visibleFrame.midX - windowSize.width / 2
        let rawY = visibleFrame.midY - windowSize.height / 2
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - windowSize.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - windowSize.height)
        return CGPoint(
            x: min(max(rawX, visibleFrame.minX), maxX),
            y: min(max(rawY, visibleFrame.minY), maxY)
        )
    }

    @MainActor
    static func center(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }
        let visibleFrame = screen.visibleFrame
        var size = window.frame.size

        if size.width > visibleFrame.width - 20 {
            size.width = max(window.minSize.width > 0 ? window.minSize.width : 760, visibleFrame.width - 20)
        }
        if size.height > visibleFrame.height - 30 {
            size.height = max(window.minSize.height > 0 ? window.minSize.height : 480, visibleFrame.height - 30)
        }

        let origin = centeredOrigin(
            windowSize: size,
            visibleFrame: visibleFrame
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
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

        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let undoItem = NSMenuItem(
            title: "撤销",
            action: #selector(UndoManager.undo),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(
            title: "重做",
            action: #selector(UndoManager.redo),
            keyEquivalent: "Z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(
            title: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        cutItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(
            title: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        copyItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        pasteItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(
            title: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        selectAllItem.keyEquivalentModifierMask = [.command]
        editMenu.addItem(selectAllItem)

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
