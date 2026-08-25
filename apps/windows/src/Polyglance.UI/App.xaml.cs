using System;
using System.Drawing;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Forms;
using System.Windows.Interop;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Capture;
using Polyglance.Platform.HotKey;
using Polyglance.Platform.Interop;
using Polyglance.Platform.Text;
using Polyglance.Platform.Update;
using Polyglance.UI.Views;
using Application = System.Windows.Application;

namespace Polyglance.UI;

public partial class App : Application
{
    private static Mutex? _mutex;
    private NotifyIcon? _notifyIcon;
    private GlobalHotKeyManager? _hotKeyManager;
    private TranslationService? _translationService;
    private ConfigurationStore? _configStore;
    private MainWindow? _mainWindow;
    private HwndSource? _hiddenHwndSource;

    protected override void OnStartup(StartupEventArgs e)
    {
        const string appName = "Polyglance_SingleInstance_Mutex";
        _mutex = new Mutex(true, appName, out bool createdNew);

        if (!createdNew)
        {
            System.Windows.MessageBox.Show("Polyglance 已经在运行中。", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        base.OnStartup(e);

        try
        {
            _configStore = new ConfigurationStore();
            _translationService = new TranslationService();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"初始化核心服务失败: {ex.Message}", "Polyglance 错误", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        _mainWindow = new MainWindow(_translationService, _configStore);

        CreateHiddenMessageWindow();
        InitializeNotifyIcon();
        RegisterDynamicHotKeys();

        var config = LoadConfigurationOrDefault();
        if (config.AutoCheckUpdates)
        {
            _ = CheckBackgroundUpdateAsync(config.AppcastUrl);
        }
    }

    private void CreateHiddenMessageWindow()
    {
        var parameters = new HwndSourceParameters("PolyglanceHiddenMessageWindow")
        {
            WindowStyle = 0,
            ExtendedWindowStyle = 0,
            Width = 0,
            Height = 0,
            PositionX = 0,
            PositionY = 0
        };
        _hiddenHwndSource = new HwndSource(parameters);
        _hotKeyManager = new GlobalHotKeyManager(_hiddenHwndSource.Handle);
    }

    private void InitializeNotifyIcon()
    {
        Icon appIcon;
        try
        {
            var iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/Polyglance.UI;component/Resources/Polyglance.ico"))?.Stream;
            appIcon = iconStream != null ? new Icon(iconStream) : SystemIcons.Application;
        }
        catch
        {
            appIcon = SystemIcons.Application;
        }

        string versionStr = AppVersionDisplay.FromAssembly(Assembly.GetEntryAssembly());

        _notifyIcon = new NotifyIcon
        {
            Icon = appIcon,
            Visible = true,
            Text = versionStr
        };

        var contextMenu = new ContextMenuStrip();
        contextMenu.RenderMode = ToolStripRenderMode.System;
        contextMenu.ShowImageMargin = true;

        // Group 1: 截图与屏幕录制
        contextMenu.Items.Add("截图", null, (s, e) => TriggerScreenshot());
        contextMenu.Items.Add("长截图", null, (s, e) => TriggerLongScreenshot());
        contextMenu.Items.Add("区域录屏", null, (s, e) => TriggerScreenRecording());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 2: 文本翻译
        contextMenu.Items.Add("截图翻译", null, (s, e) => TriggerScreenTranslate());
        contextMenu.Items.Add("读取选区并翻译", null, (s, e) => TriggerSelectedTextTranslate());
        contextMenu.Items.Add("打开主翻译窗口", null, (s, e) => ShowMainWindow());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 3: 贴图管理
        var pinMenu = new ToolStripMenuItem("贴图管理");
        pinMenu.DropDownItems.Add("贴出剪贴板图片", null, (s, e) => PinClipboardImage());
        pinMenu.DropDownItems.Add(new ToolStripSeparator());
        pinMenu.DropDownItems.Add("隐藏全部贴图", null, (s, e) => HideAllPins());
        pinMenu.DropDownItems.Add("显示全部贴图", null, (s, e) => ShowAllPins());
        pinMenu.DropDownItems.Add(new ToolStripSeparator());
        pinMenu.DropDownItems.Add("关闭全部贴图", null, (s, e) => CloseAllPins());
        contextMenu.Items.Add(pinMenu);

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 4: 设置与更新
        contextMenu.Items.Add("偏好设置…", null, (s, e) => ShowSettings());
        contextMenu.Items.Add("检查更新…", null, (s, e) => TriggerCheckUpdate());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 5: 版本信息（只读置灰）与退出
        var versionItem = new ToolStripMenuItem(versionStr) { Enabled = false };
        contextMenu.Items.Add(versionItem);

        contextMenu.Items.Add("退出 Polyglance", null, (s, e) => ShutdownApp());

        _notifyIcon.ContextMenuStrip = contextMenu;
        _notifyIcon.DoubleClick += (s, e) => ShowMainWindow();
    }

    public void RegisterDynamicHotKeys()
    {
        if (_hotKeyManager == null || _configStore == null) return;

        // Dispose previous manager and re-create
        _hotKeyManager.Dispose();
        if (_hiddenHwndSource != null)
        {
            _hotKeyManager = new GlobalHotKeyManager(_hiddenHwndSource.Handle);
        }

        var config = LoadConfigurationOrDefault();

        RegisterSingleHotKey(config.HotkeyScreenshotPin, TriggerScreenshot);
        RegisterSingleHotKey(config.HotkeyScreenTranslate, TriggerScreenTranslate);
        RegisterSingleHotKey(config.HotkeyMainTranslator, ShowMainWindow);
        RegisterSingleHotKey(config.HotkeySelectedText, TriggerSelectedTextTranslate);
        RegisterSingleHotKey(config.HotkeyLongScreenshot, TriggerLongScreenshot);
    }

    private void RegisterSingleHotKey(string hotkeyStr, Action action)
    {
        if (string.IsNullOrWhiteSpace(hotkeyStr) || _hotKeyManager == null) return;

        uint modifiers = 0;
        uint key = 0;

        string[] parts = hotkeyStr.Split('+');
        foreach (var p in parts)
        {
            string part = p.Trim();
            if (part.Equals("Ctrl", StringComparison.OrdinalIgnoreCase))
                modifiers |= NativeWin32.MOD_CONTROL;
            else if (part.Equals("Alt", StringComparison.OrdinalIgnoreCase))
                modifiers |= NativeWin32.MOD_ALT;
            else if (part.Equals("Shift", StringComparison.OrdinalIgnoreCase))
                modifiers |= NativeWin32.MOD_SHIFT;
            else if (part.Equals("Win", StringComparison.OrdinalIgnoreCase))
                modifiers |= NativeWin32.MOD_WIN;
            else if (Enum.TryParse<Keys>(part, true, out var parsedKey))
            {
                key = (uint)parsedKey;
            }
        }

        if (key != 0)
        {
            _hotKeyManager.Register(modifiers, key, action);
        }
    }

    public void TriggerScreenshot()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.Standard);
    }

    private void BeginScreenshotSelection(ScreenshotCaptureIntent intent)
    {
        Dispatcher.Invoke(() =>
        {
            if (_translationService == null || _configStore == null) return;

            var (bitmap, bounds) = ScreenCapture.CaptureVirtualScreen();
            var config = LoadConfigurationOrDefault();

            var win = new ScreenSelectionWindow(bitmap, bounds, _translationService, config, intent);
            win.Show();
            win.Activate();
        });
    }

    public void TriggerScreenTranslate()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenTranslation);
    }

    private AppConfiguration LoadConfigurationOrDefault()
    {
        if (_configStore == null)
            return new AppConfiguration();

        try
        {
            return _configStore.Load();
        }
        catch (ConfigurationStoreException error)
        {
            System.Windows.MessageBox.Show(
                error.Message,
                "Polyglance 设置",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return new AppConfiguration();
        }
    }

    public async void TriggerSelectedTextTranslate()
    {
        string? text = await SelectedTextReader.GetSelectedTextAsync();
        if (!string.IsNullOrWhiteSpace(text))
        {
            Dispatcher.Invoke(() =>
            {
                if (_mainWindow != null)
                {
                    _mainWindow.SetAndTranslate(text);
                }
            });
        }
    }

    public void TriggerLongScreenshot()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.LongScreenshot);
    }

    public void TriggerScreenRecording()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenRecording);
    }

    public void PinClipboardImage()
    {
        Dispatcher.Invoke(() =>
        {
            if (System.Windows.Clipboard.ContainsImage())
            {
                var image = System.Windows.Clipboard.GetImage();
                if (image != null)
                {
                    var pin = new PinWindow(
                        image,
                        _translationService,
                        LoadConfigurationOrDefault());
                    pin.Show();
                }
            }
            else
            {
                System.Windows.MessageBox.Show("剪贴板中没有图片。", "贴图", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        });
    }

    public void HideAllPins()
    {
        Dispatcher.Invoke(() =>
        {
            foreach (Window window in Application.Current.Windows)
            {
                if (window is PinWindow pin)
                {
                    pin.Hide();
                }
            }
        });
    }

    public void ShowAllPins()
    {
        Dispatcher.Invoke(() =>
        {
            foreach (Window window in Application.Current.Windows)
            {
                if (window is PinWindow pin)
                {
                    pin.Show();
                }
            }
        });
    }

    public void CloseAllPins()
    {
        Dispatcher.Invoke(() =>
        {
            foreach (Window window in Application.Current.Windows)
            {
                if (window is PinWindow pin)
                {
                    pin.Close();
                }
            }
        });
    }

    public async void TriggerCheckUpdate()
    {
        var config = LoadConfigurationOrDefault();
        try
        {
            var update = await AppUpdater.CheckForUpdatesAsync(config.AppcastUrl);
            if (update != null)
            {
                var result = System.Windows.MessageBox.Show(
                    $"发现新版本 v{update.Version}！\n\n更新内容:\n{update.ReleaseNotes}\n\n是否立即下载并更新？",
                    "Polyglance 自动更新",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information
                );

                if (result == System.Windows.MessageBoxResult.Yes)
                {
                    await AppUpdater.DownloadAndApplyUpdateAsync(update.DownloadUrl);
                }
            }
            else
            {
                System.Windows.MessageBox.Show("当前已是最新版本！", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"检查更新失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    public void ShowMainWindow()
    {
        Dispatcher.Invoke(() =>
        {
            if (_mainWindow != null)
            {
                _mainWindow.Show();
                _mainWindow.WindowState = WindowState.Normal;
                _mainWindow.Activate();
            }
        });
    }

    public void ShowSettings()
    {
        Dispatcher.Invoke(() =>
        {
            if (_configStore != null)
            {
                var settings = new SettingsWindow(_configStore);
                if (settings.ShowDialog() == true)
                {
                    RegisterDynamicHotKeys();
                }
            }
        });
    }

    private async Task CheckBackgroundUpdateAsync(string appcastUrl)
    {
        try
        {
            await Task.Delay(3000);
            var update = await AppUpdater.CheckForUpdatesAsync(appcastUrl);
            if (update != null)
            {
                Dispatcher.Invoke(() =>
                {
                    _notifyIcon?.ShowBalloonTip(
                        5000,
                        "Polyglance 发现新版本",
                        $"v{update.Version} 已发布，点击偏好设置可一键更新。",
                        ToolTipIcon.Info
                    );
                });
            }
        }
        catch { }
    }

    private void ShutdownApp()
    {
        _notifyIcon?.Dispose();
        _hotKeyManager?.Dispose();
        _translationService?.Dispose();
        _hiddenHwndSource?.Dispose();
        _mutex?.Dispose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        ShutdownApp();
        base.OnExit(e);
    }
}
