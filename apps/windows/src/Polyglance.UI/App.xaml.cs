using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
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
using Polyglance.Platform.Pin;
using Polyglance.Platform.Startup;
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
    private CancellationTokenSource? _updateCts;
    private ToolStripMenuItem? _dynamicUpdateMenuItem;
    private ToolStripSeparator? _dynamicUpdateSeparator;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Polyglance is a tray application. Floating screenshot/result windows
        // are disposable UI and closing the final one must never stop the app.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

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
            RefreshStartupRegistration();
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
            _updateCts = new CancellationTokenSource();
            _ = StartBackgroundUpdateLoopAsync(_updateCts.Token);
        }
    }

    private static void RefreshStartupRegistration()
    {
        try
        {
            string executablePath = Environment.ProcessPath
                ?? Process.GetCurrentProcess().MainModule?.FileName
                ?? throw new InvalidOperationException("无法确定 Polyglance 可执行文件路径。");
            var startupRegistration = new StartupRegistrationManager(
                new RegistryStartupValueStore(),
                executablePath);
            startupRegistration.RefreshRegistration();
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Unable to refresh startup registration: {error}");
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
            var iconStream = Application.GetResourceStream(new Uri("pack://application:,,,/Polyglance;component/Resources/Polyglance.ico"))?.Stream;
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
            Text = TrayIconPresentation.TooltipText
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
        pinMenu.DropDownItems.Add("恢复最近贴图", null, (s, e) => RestoreMostRecentPin());
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

        var failures = new List<string>();
        RegisterSingleHotKey("截图贴图", config.HotkeyScreenshotPin, TriggerScreenshot, failures);
        RegisterSingleHotKey("剪贴板贴图", config.HotkeyPinClipboardImage, PinClipboardImage, failures);
        RegisterSingleHotKey("划词翻译", config.HotkeySelectedText, TriggerSelectedTextTranslate, failures);
        RegisterSingleHotKey("截图翻译", config.HotkeyScreenTranslate, TriggerScreenTranslate, failures);
        RegisterSingleHotKey("长截图", config.HotkeyLongScreenshot, TriggerLongScreenshot, failures);
        RegisterSingleHotKey("屏幕录制", config.HotkeyScreenRecording, TriggerScreenRecording, failures);
        RegisterSingleHotKey("恢复最近贴图", config.HotkeyRestoreMostRecentPin, RestoreMostRecentPin, failures);
        RegisterSingleHotKey("主窗口", config.HotkeyMainTranslator, ShowMainWindow, failures);

        // A shortcut that Windows refuses is the single most confusing failure
        // here: the settings dialog saved it, the box shows it, and nothing
        // happens when it is pressed. Say which ones did not take.
        if (failures.Count > 0 && _notifyIcon != null)
        {
            _notifyIcon.ShowBalloonTip(
                5000,
                "快捷键未生效",
                string.Join("\n", failures),
                ToolTipIcon.Warning);
        }
    }

    private void RegisterSingleHotKey(
        string label,
        string hotkeyStr,
        Action action,
        List<string> failures)
    {
        // An unassigned shortcut is a deliberate choice, not a failure.
        if (string.IsNullOrWhiteSpace(hotkeyStr) || _hotKeyManager == null) return;

        if (!ShortcutDefinition.TryParse(hotkeyStr, out ShortcutDefinition? definition, out string? error)
            || definition == null)
        {
            failures.Add($"{label}（{hotkeyStr}）：{error}");
            return;
        }

        if (_hotKeyManager.Register(definition.Modifiers, definition.VirtualKey, action) < 0)
        {
            failures.Add($"{label}（{hotkeyStr}）：已被其他程序占用");
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

    public void RestoreMostRecentPin()
    {
        Dispatcher.Invoke(() =>
        {
            string? recentPath = PinHistoryManager.GetRecentPins().FirstOrDefault()?.FilePath;
            if (string.IsNullOrWhiteSpace(recentPath) || !File.Exists(recentPath))
            {
                System.Windows.MessageBox.Show(
                    "没有可恢复的贴图。",
                    "恢复贴图",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var bitmap = new System.Windows.Media.Imaging.BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(recentPath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();

            var pin = new PinWindow(
                bitmap,
                _translationService!,
                LoadConfigurationOrDefault(),
                Clipboard.SetText,
                capturedDisplaySize: null,
                saveToHistory: false);
            pin.Show();
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
        _notifyIcon?.ShowBalloonTip(2500, "Polyglance", "正在检查更新，请稍候...", ToolTipIcon.Info);

        try
        {
            UpdateCheckResult check = await AppUpdater.CheckForUpdatesAsync(
                config.AppcastUrl,
                config.IncludeBetaUpdates,
                config.SkippedUpdateVersion);
            if (check.Status == UpdateCheckStatus.UpdateAvailable)
            {
                UpdateInfo update = check.Update!;
                _notifyIcon?.ShowBalloonTip(
                    5000,
                    "Polyglance 发现新版本",
                    $"发现新版本 v{update.Version}，正在后台下载更新...",
                    ToolTipIcon.Info);

                bool started = await AppUpdater.DownloadAndApplyUpdateAsync(update.DownloadUrl);
                if (!started)
                {
                    _notifyIcon?.ShowBalloonTip(
                        5000,
                        "Polyglance 自动更新",
                        "更新包下载或替换失败，请稍后重试，或从 GitHub Release 手动安装。",
                        ToolTipIcon.Warning);
                }
            }
            else if (check.Status == UpdateCheckStatus.UpToDate)
            {
                _notifyIcon?.ShowBalloonTip(4000, "Polyglance", "当前已是最新版本！", ToolTipIcon.Info);
            }
            else
            {
                _notifyIcon?.ShowBalloonTip(
                    4000,
                    "Polyglance 检查更新",
                    string.IsNullOrWhiteSpace(check.ErrorMessage) ? "检查更新失败" : check.ErrorMessage,
                    ToolTipIcon.Warning);
            }
        }
        catch (Exception ex)
        {
            _notifyIcon?.ShowBalloonTip(4000, "Polyglance 检查更新", $"检查更新失败: {ex.Message}", ToolTipIcon.Warning);
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

    public void ShowSettings(string initialTab = "General")
    {
        Dispatcher.Invoke(() =>
        {
            if (_configStore != null)
            {
                var settings = new SettingsWindow(_configStore, initialTab: initialTab);
                if (settings.ShowDialog() == true)
                {
                    RegisterDynamicHotKeys();
                }
            }
        });
    }

    private async Task StartBackgroundUpdateLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(10), cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var config = LoadConfigurationOrDefault();
                if (config.AutoCheckUpdates)
                {
                    UpdateCheckResult check = await AppUpdater.CheckForUpdatesAsync(
                        config.AppcastUrl,
                        config.IncludeBetaUpdates,
                        config.SkippedUpdateVersion);

                    if (check.Status == UpdateCheckStatus.UpdateAvailable && check.Update != null)
                    {
                        UpdateInfo update = check.Update;
                        Dispatcher.Invoke(() =>
                        {
                            ApplyUpdateNotification(update);
                        });
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Background update check failed: {ex.Message}");
            }

            try
            {
                await Task.Delay(TimeSpan.FromHours(6), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private void ApplyUpdateNotification(UpdateInfo update)
    {
        if (_notifyIcon?.ContextMenuStrip == null) return;

        string updateTitle = update.IsBeta
            ? $"🧪 发现新测试版 v{update.Version}"
            : $"🚀 发现新版本 v{update.Version}";

        if (_dynamicUpdateMenuItem == null)
        {
            _dynamicUpdateMenuItem = new ToolStripMenuItem(updateTitle, null, (s, e) => ShowSettings(initialTab: "About"))
            {
                Font = new System.Drawing.Font(System.Drawing.SystemFonts.MenuFont?.FontFamily ?? System.Drawing.FontFamily.GenericSansSerif, 9f, System.Drawing.FontStyle.Bold)
            };
            _dynamicUpdateSeparator = new ToolStripSeparator();

            _notifyIcon.ContextMenuStrip.Items.Insert(0, _dynamicUpdateMenuItem);
            _notifyIcon.ContextMenuStrip.Items.Insert(1, _dynamicUpdateSeparator);
        }
        else
        {
            _dynamicUpdateMenuItem.Text = updateTitle;
        }

        _notifyIcon.ShowBalloonTip(
            6000,
            update.IsBeta ? "Polyglance 发现新测试版" : "Polyglance 发现新版本",
            $"v{update.Version} ({(update.IsBeta ? "测试版" : "正式版")}) 已发布，点击偏好设置可一键更新。",
            ToolTipIcon.Info
        );
    }

    private void ShutdownApp()
    {
        _updateCts?.Cancel();
        _updateCts?.Dispose();
        _updateCts = null;
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
