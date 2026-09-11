import AppKit
import SwiftUI

@main
struct PolyglanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button {
                appDelegate.captureScreenshotAndPin()
            } label: {
                Label("截图", systemImage: "viewfinder")
            }

            Button {
                appDelegate.captureLongScreenshot()
            } label: {
                Label("长截图", systemImage: "rectangle.stack.badge.plus")
            }

            Button {
                appDelegate.captureScreenRecordingRegion()
            } label: {
                Label("区域录屏", systemImage: "record.circle")
            }

            Button {
                appDelegate.captureOCRWorkspace()
            } label: {
                Label("文字识别", systemImage: "doc.text.viewfinder")
            }

            Divider()

            Button {
                appDelegate.captureScreenTranslation()
            } label: {
                Label("截图翻译", systemImage: "photo.badge.checkmark")
            }

            Button {
                appDelegate.showTranslator(capturingSelection: true, translateImmediately: true)
            } label: {
                Label("划词翻译", systemImage: "character.book.closed")
            }

            Button {
                appDelegate.showTranslator()
            } label: {
                Label("输入翻译", systemImage: "translate")
            }

            Divider()

            Menu {
                Button {
                    appDelegate.pinClipboardImage()
                } label: {
                    Label("贴出剪贴板内容", systemImage: "doc.on.clipboard")
                }

                Button {
                    appDelegate.restoreMostRecentPin()
                } label: {
                    Label("恢复最近关闭的贴图", systemImage: "arrow.uturn.backward")
                }

                Button {
                    appDelegate.showPinHistory()
                } label: {
                    Label("贴图历史…", systemImage: "clock.arrow.circlepath")
                }

                Divider()

                Button {
                    appDelegate.hideAllPins()
                } label: {
                    Label("隐藏全部贴图", systemImage: "eye.slash")
                }

                Button {
                    appDelegate.showAllPins()
                } label: {
                    Label("显示全部贴图", systemImage: "eye")
                }

                Divider()

                Button {
                    appDelegate.closeAllPins()
                } label: {
                    Label("关闭全部贴图", systemImage: "xmark.circle")
                }

                Button {
                    appDelegate.destroyAllPins()
                } label: {
                    Label("彻底销毁全部贴图", systemImage: "trash")
                }
            } label: {
                Label("贴图管理", systemImage: "pin")
            }

            Divider()

            Button {
                appDelegate.showSettings()
            } label: {
                Label("偏好设置…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button {
                appDelegate.checkForUpdates()
            } label: {
                Label("检查更新…", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button {
                appDelegate.showSettings()
            } label: {
                Text(AppVersionInfo.displayString)
            }
            .disabled(true)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Polyglance", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: [.command])
        } label: {
            Image(nsImage: PolyglanceMenuBarIcon.image)
                .accessibilityLabel("Polyglance")
        }

    }
}
