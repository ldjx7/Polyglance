using System;
using System.Drawing;
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
            System.Windows.MessageBox.Show($"初始化核心引擎失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        _mainWindow = new MainWindow(_translationService, _configStore);

        SetupHiddenHwnd();
        SetupTrayIcon();
        RegisterDynamicHotKeys();

        var config = LoadConfigurationOrDefault();
        if (config.AutoCheckUpdates)
        {
            _ = CheckBackgroundUpdateAsync(config.AppcastUrl);
        }
    }

    private void SetupHiddenHwnd()
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

    private void SetupTrayIcon()
    {
        Icon appIcon;
        try
        {
            var uri = new Uri("pack://application:,,,/Polyglance.UI;component/Resources/Polyglance.ico");
            var streamInfo = Application.GetResourceStream(uri);
            if (streamInfo != null)
            {
                using var stream = streamInfo.Stream;
                appIcon = new Icon(stream);
            }
            else
            {
                appIcon = SystemIcons.Application;
            }
        }
        catch
        {
            appIcon = SystemIcons.Application;
        }

        _notifyIcon = new NotifyIcon
        {
            Icon = appIcon,
            Visible = true,
            Text = "Polyglance v0.0.3"
        };

        var contextMenu = new ContextMenuStrip();
        contextMenu.Items.Add("截图并贴图", null, (s, e) => TriggerScreenshot());
        contextMenu.Items.Add("屏幕原位翻译", null, (s, e) => TriggerScreenTranslate());
        contextMenu.Items.Add("划词选中文本翻译", null, (s, e) => TriggerSelectedTextTranslate());
        contextMenu.Items.Add("滚动长截图", null, (s, e) => TriggerLongScreenshot());
        contextMenu.Items.Add(new ToolStripSeparator());
        contextMenu.Items.Add("打开主翻译窗口", null, (s, e) => ShowMainWindow());
        contextMenu.Items.Add("偏好设置…", null, (s, e) => ShowSettings());
        contextMenu.Items.Add(new ToolStripSeparator());
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
        Dispatcher.Invoke(() =>
        {
            if (_translationService == null || _configStore == null) return;

            var (bitmap, bounds) = ScreenCapture.CaptureVirtualScreen();
            var config = LoadConfigurationOrDefault();

            var win = new ScreenSelectionWindow(bitmap, bounds, _translationService, config);
            win.Show();
            win.Activate();
        });
    }

    public void TriggerScreenTranslate()
    {
        TriggerScreenshot();
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
        Dispatcher.Invoke(() =>
        {
            var (bitmap, bounds) = ScreenCapture.CaptureVirtualScreen();
            var win = new LongScreenshotSessionWindow(bitmap, bounds);
            win.Show();
            win.Activate();
        });
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
