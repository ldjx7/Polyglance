import AppKit
import SwiftUI

@main
struct NativeTranslatorMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Polyglance", systemImage: "character.book.closed") {
            Button("截图工具") {
                appDelegate.captureScreenshotAndPin()
            }

            Button("长截图") {
                appDelegate.captureLongScreenshot()
            }

            Button("区域录屏") {
                appDelegate.captureScreenRecordingRegion()
            }

            Button("贴出剪贴板图片") {
                appDelegate.pinClipboardImage()
            }

            Button("恢复最近关闭的贴图") {
                appDelegate.restoreMostRecentPin()
            }

            Button("隐藏全部贴图") {
                appDelegate.hideAllPins()
            }

            Button("显示全部贴图") {
                appDelegate.showAllPins()
            }

            Button("关闭全部贴图（可恢复）") {
                appDelegate.closeAllPins()
            }

            Button("彻底销毁全部贴图") {
                appDelegate.destroyAllPins()
            }

            Divider()
            Button("打开翻译窗口") {
                appDelegate.showTranslator()
            }

            Button("读取选区并翻译") {
                appDelegate.showTranslator(capturingSelection: true, translateImmediately: true)
            }

            Button("读取选区（不翻译）") {
                appDelegate.showTranslator(capturingSelection: true, translateImmediately: false)
            }

            Divider()
            Button("设置…") {
                appDelegate.showSettings()
            }

            Button("检查更新…") {
                appDelegate.checkForUpdates()
            }
            Divider()

            Button("退出 Polyglance") {
                NSApp.terminate(nil)
            }
        }

    }
}
