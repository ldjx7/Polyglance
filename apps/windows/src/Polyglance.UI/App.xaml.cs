using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
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
using Polyglance.Platform.Packaging;
using Polyglance.Platform.Pin;
using Polyglance.Platform.Startup;
using Polyglance.Platform.Text;
using Polyglance.Platform.Translation;
using Polyglance.Platform.Update;
using Polyglance.UI.Services;
using Polyglance.UI.Views;
using Application = System.Windows.Application;

namespace Polyglance.UI;

public partial class App : Application
{
    public static App? CurrentApp => Application.Current as App;
    new public MainWindow? MainWindow => _mainWindow;

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
    private PinHistoryWindow? _pinHistoryWindow;
    private SettingsWindow? _settingsWindow;
    private IntPtr _lastActiveWindowBeforeTray = IntPtr.Zero;
    private bool _isOneShotCliMode;
    private CancellationTokenSource? _ipcServerCts;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WriteConsoleW(
        IntPtr hConsoleOutput,
        string lpBuffer,
        int nNumberOfCharsToWrite,
        out int lpNumberOfCharsWritten,
        IntPtr lpReserved);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteConsoleInputW(
        IntPtr hConsoleInput,
        [In] INPUT_RECORD[] lpBuffer,
        int nLength,
        out int lpNumberOfEventsWritten);

    private const int STD_INPUT_HANDLE = -10;
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUT_RECORD
    {
        [FieldOffset(0)]
        public ushort EventType;
        [FieldOffset(4)]
        public KEY_EVENT_RECORD KeyEvent;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEY_EVENT_RECORD
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool bKeyDown;
        public ushort wRepeatCount;
        public ushort wVirtualKeyCode;
        public ushort wVirtualScanCode;
        public char UnicodeChar;
        public uint dwControlKeyState;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        var cliOpts = CommandLineOptions.Parse(e.Args);

#if POLYGLANCE_CLI
        // 仅在 CLI 独立单文件版本中生效：双击或无参数运行默认直接唤起截图选区
        if (!cliOpts.IsCliMode)
        {
            cliOpts.IsCliMode = true;
            cliOpts.Capture = true;
        }
#endif

        if (cliOpts.ShowHelp)
        {
            ShowCliHelp();
            Shutdown(0);
            return;
        }

        if (cliOpts.DumpConfig)
        {
            DumpDefaultConfigToConsole();
            Shutdown(0);
            return;
        }

        if (cliOpts.GenerateConfig || cliOpts.InitConfig)
        {
            GenerateDefaultConfigInCurrentDirectory(cliOpts.ConfigPath);
            Shutdown(0);
            return;
        }

        const string appName = "Polyglance_SingleInstance_Mutex";
        _mutex = new Mutex(true, appName, out bool createdNew);

        if (!createdNew)
        {
            if (cliOpts.IsCliMode)
            {
                if (TrySendIpcCommand(cliOpts.SerializeToIpcCommand()))
                {
                    Shutdown(0);
                    return;
                }
            }

            System.Windows.MessageBox.Show("Polyglance 已经在运行中。", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        base.OnStartup(e);

        try
        {
            _configStore = new ConfigurationStore();
            var startupConfig = LoadConfigurationOrDefault();
            DataDirectoryManager.ApplyRootDirectory(startupConfig.DataStorageDirectory);
            Polyglance.Platform.Ocr.OcrService.DefaultPreferredEngineId = startupConfig.OcrPreferredEngine;
#if !EXCLUDE_TRANSLATION
            _translationService = new TranslationService();
            TranslationService.OfflineHandler = new OfflineTranslationEngine();
#endif
            if (!cliOpts.IsCliMode)
            {
                RefreshStartupRegistration();
            }
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show($"初始化核心服务失败: {ex.Message}", "Polyglance 错误", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown();
            return;
        }

        if (cliOpts.IsCliMode)
        {
            _isOneShotCliMode = true;
            ExecuteCliCommand(cliOpts);
            return;
        }

        _mainWindow = new MainWindow(_translationService, _configStore);

        CreateHiddenMessageWindow();
        InitializeNotifyIcon();
        RegisterDynamicHotKeys();
        StartIpcServer();

        var config = LoadConfigurationOrDefault();
        _ = PinSessionController.For().Restore(true, _translationService, config);
        if (config.AutoCheckUpdates)
        {
            _updateCts = new CancellationTokenSource();
            _ = StartBackgroundUpdateLoopAsync(_updateCts.Token);
        }
    }

    private static void WriteToConsole(string text, bool isError = false)
    {
        const int ATTACH_PARENT_PROCESS = -1;
        bool attached = AttachConsole(ATTACH_PARENT_PROCESS);
        try
        {
            IntPtr stdHandle = GetStdHandle(isError ? STD_ERROR_HANDLE : STD_OUTPUT_HANDLE);
            if (stdHandle != IntPtr.Zero && WriteConsoleW(stdHandle, text, text.Length, out _, IntPtr.Zero))
            {
                return;
            }

            using var stream = isError ? Console.OpenStandardError() : Console.OpenStandardOutput();
            using var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true };
            writer.Write(text);
        }
        catch { }
        finally
        {
            if (attached)
            {
                SendReturnToConsole();
                FreeConsole();
            }
        }
    }

    private static void SendReturnToConsole()
    {
        try
        {
            IntPtr hInput = GetStdHandle(STD_INPUT_HANDLE);
            if (hInput == IntPtr.Zero || hInput == new IntPtr(-1)) return;

            var records = new INPUT_RECORD[2];
            records[0].EventType = 1; // KEY_EVENT
            records[0].KeyEvent.bKeyDown = true;
            records[0].KeyEvent.wRepeatCount = 1;
            records[0].KeyEvent.wVirtualKeyCode = 0x0D; // VK_RETURN
            records[0].KeyEvent.UnicodeChar = '\r';

            records[1].EventType = 1; // KEY_EVENT
            records[1].KeyEvent.bKeyDown = false;
            records[1].KeyEvent.wRepeatCount = 1;
            records[1].KeyEvent.wVirtualKeyCode = 0x0D;
            records[1].KeyEvent.UnicodeChar = '\r';

            WriteConsoleInputW(hInput, records, records.Length, out _);
        }
        catch { }
    }

    private static void ShowCliHelp()
    {
        var sb = new StringBuilder();
        sb.AppendLine();
        sb.AppendLine("Polyglance 屏幕工具命令行模式");
        sb.AppendLine("用法: polyglance.exe [选项]");
        sb.AppendLine();
        sb.AppendLine("选项:");
        sb.AppendLine("  --capture, -c               启动全屏截图选区");
        sb.AppendLine("  --record, -r                启动区域录屏选区");
        sb.AppendLine("  --ocr, -o                   启动离线 OCR 文字识别");
        sb.AppendLine("  --output <path>, -out <path> 截图完成后自动保存到指定路径");
        sb.AppendLine("  --no-translate              隐藏工具栏中的翻译按钮（纯净白标模式）");
        sb.AppendLine("  --config <path>, -cfg <path> 指定自定义配置文件路径（第三方程序集成隔离）");
        sb.AppendLine("  --toolbar <items>, --tools <items> 自定义截图工具栏顺序与显隐（逗号分隔，如 rect,arrow,text,pin,save,copy）");
        sb.AppendLine("  --generate-config, -g       在终端当前工作目录下直接生成默认 config.json 并退出");
        sb.AppendLine("  --init-config               在当前工作目录下生成默认配置文件并退出");
        sb.AppendLine("  --dump-config               在控制台直接输出默认配置 JSON 内容并退出");
        sb.AppendLine("  --help, -h                  显示帮助说明");
        sb.AppendLine();
        WriteToConsole(sb.ToString());
    }

    private static void DumpDefaultConfigToConsole()
    {
        var config = new AppConfiguration();
        string json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
        WriteToConsole(json + Environment.NewLine);
    }

    private static void GenerateDefaultConfigInCurrentDirectory(string? customPath = null)
    {
        string targetPath = !string.IsNullOrWhiteSpace(customPath)
            ? Path.GetFullPath(customPath)
            : Path.Combine(Environment.CurrentDirectory, "config.json");

        try
        {
            string dir = Path.GetDirectoryName(targetPath) ?? Environment.CurrentDirectory;
            Directory.CreateDirectory(dir);
            var store = new ConfigurationStore(targetPath, new DpapiCredentialStore(Path.Combine(dir, "credentials.dat")));
            store.Save(new AppConfiguration());

            WriteToConsole($"已在当前目录下生成默认配置文件: {targetPath}{Environment.NewLine}");
        }
        catch (Exception ex)
        {
            WriteToConsole($"生成配置文件失败: {ex.Message}{Environment.NewLine}", isError: true);
        }
    }

    private void ExecuteCliCommand(CommandLineOptions opts)
    {
        bool hideTrans = opts.HideTranslation;
#if EXCLUDE_TRANSLATION
        hideTrans = true;
#endif
        if (opts.Record)
        {
            BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenRecording, opts.OutputPath, hideTrans, opts.ConfigPath, opts.ToolbarItems);
        }
        else if (opts.Ocr)
        {
            BeginScreenshotSelection(ScreenshotCaptureIntent.OcrWorkspace, opts.OutputPath, hideTrans, opts.ConfigPath, opts.ToolbarItems);
        }
        else
        {
            BeginScreenshotSelection(ScreenshotCaptureIntent.Standard, opts.OutputPath, hideTrans, opts.ConfigPath, opts.ToolbarItems);
        }
    }

    public void CheckOneShotExit()
    {
        if (!_isOneShotCliMode) return;

        Dispatcher.InvokeAsync(() =>
        {
            bool hasActiveUserWindows = false;
            foreach (Window win in Windows)
            {
                if (win.IsVisible && win is not Polyglance.UI.Views.MainWindow)
                {
                    hasActiveUserWindows = true;
                    break;
                }
            }

            if (!hasActiveUserWindows)
            {
                Shutdown(0);
            }
        });
    }

    private static bool TrySendIpcCommand(string command)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", "Polyglance_Ipc_Pipe", PipeDirection.Out);
            client.Connect(600);
            using var writer = new StreamWriter(client, Encoding.UTF8) { AutoFlush = true };
            writer.WriteLine(command);
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void StartIpcServer()
    {
        _ipcServerCts = new CancellationTokenSource();
        var token = _ipcServerCts.Token;
        Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    using var server = new NamedPipeServerStream(
                        "Polyglance_Ipc_Pipe",
                        PipeDirection.In,
                        NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);

                    await server.WaitForConnectionAsync(token);
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    string? line = await reader.ReadLineAsync(token);
                    if (!string.IsNullOrWhiteSpace(line))
                    {
                        var opts = CommandLineOptions.DeserializeFromIpcCommand(line);
                        Dispatcher.Invoke(() => ExecuteCliCommand(opts));
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch
                {
                    try { await Task.Delay(200, token); } catch { break; }
                }
            }
        }, token);
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
            appIcon = iconStream != null ? new Icon(iconStream, SystemInformation.SmallIconSize) : SystemIcons.Application;
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
        contextMenu.Opening += (s, e) => RecordActiveWindowBeforeTray();
        _notifyIcon.MouseDown += (s, e) =>
        {
            if (e.Button == MouseButtons.Right)
            {
                RecordActiveWindowBeforeTray();
            }
        };

        // Group 1: 截图与屏幕录制
        contextMenu.Items.Add("截图", null, (s, e) => TriggerScreenshot());
        contextMenu.Items.Add("长截图", null, (s, e) => TriggerLongScreenshot());
        contextMenu.Items.Add("区域录屏", null, (s, e) => TriggerScreenRecording());
        contextMenu.Items.Add("文字识别", null, (s, e) => TriggerOcrWorkspace());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 2: 文本翻译
        contextMenu.Items.Add("截图翻译", null, (s, e) => TriggerScreenTranslate());
        contextMenu.Items.Add("划词翻译", null, (s, e) => TriggerSelectedTextTranslateFromTray());
        contextMenu.Items.Add("输入翻译", null, (s, e) => ShowMainWindow());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 3: 贴图管理
        var pinMenu = new ToolStripMenuItem("贴图管理");
        pinMenu.DropDownItems.Add("贴出剪贴板内容", null, (s, e) => PinClipboardImage());
        pinMenu.DropDownItems.Add("恢复最近关闭的贴图", null, (s, e) => RestoreMostRecentPin());
        pinMenu.DropDownItems.Add("贴图历史…", null, (s, e) => ShowPinHistory());
        pinMenu.DropDownItems.Add(new ToolStripSeparator());
        pinMenu.DropDownItems.Add("隐藏全部贴图", null, (s, e) => HideAllPins());
        pinMenu.DropDownItems.Add("显示全部贴图", null, (s, e) => ShowAllPins());
        pinMenu.DropDownItems.Add(new ToolStripSeparator());
        pinMenu.DropDownItems.Add("关闭全部贴图", null, (s, e) => CloseAllPins());
        pinMenu.DropDownItems.Add("彻底销毁全部贴图", null, (s, e) => Dispatcher.Invoke(async () => await PinSessionController.For().DestroyAll()));
        contextMenu.Items.Add(pinMenu);

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 4: 设置与更新
        contextMenu.Items.Add("偏好设置…", null, (s, e) => ShowSettings());
        contextMenu.Items.Add("检查更新…", null, (s, e) => TriggerCheckUpdate());

        contextMenu.Items.Add(new ToolStripSeparator());

        // Group 5: 版本信息（只读置灰）与退出
        var versionItem = new ToolStripMenuItem(versionStr) { Enabled = false };
        contextMenu.Items.Add(versionItem);

        contextMenu.Items.Add("退出 Polyglance", null, async (s, e) => await ShutdownAppAsync());

        _notifyIcon.ContextMenuStrip = contextMenu;
        _notifyIcon.DoubleClick += (s, e) => ShowMainWindow();
    }

    public Dictionary<string, string> ActiveHotkeyFailures { get; } = new(StringComparer.OrdinalIgnoreCase);

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

        ActiveHotkeyFailures.Clear();
        var failures = new List<string>();
        RegisterSingleHotKey("截图", config.HotkeyScreenshotPin, TriggerScreenshot, failures);
        RegisterSingleHotKey("截图并复制", config.HotkeyScreenshotCopy, TriggerScreenshotCopy, failures);
        RegisterSingleHotKey("剪贴板贴图", config.HotkeyPinClipboardImage, PinClipboardImage, failures);
        RegisterSingleHotKey("划词翻译", config.HotkeySelectedText, TriggerSelectedTextTranslate, failures);
        RegisterSingleHotKey("划词翻译并替换", config.HotkeyTranslateAndReplace, TriggerTranslateAndReplace, failures);
        RegisterSingleHotKey("截图翻译", config.HotkeyScreenTranslate, TriggerScreenTranslate, failures);
        RegisterSingleHotKey("OCR翻译", config.HotkeyOcrTranslate, TriggerOcrTranslate, failures);
        RegisterSingleHotKey("文字识别", config.HotkeyOcrWorkspace, TriggerOcrWorkspace, failures);
        RegisterSingleHotKey("双语对照卡", config.HotkeyOcrTranslationCard, TriggerOcrTranslationCard, failures);
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
            ActiveHotkeyFailures[label] = error ?? "无效快捷键";
            return;
        }

        if (_hotKeyManager.Register(definition.Modifiers, definition.VirtualKey, action) < 0)
        {
            failures.Add($"{label}（{hotkeyStr}）：已被其他程序占用");
            ActiveHotkeyFailures[label] = "已被占用";
        }
    }

    public void TriggerScreenshot()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.Standard);
    }

    public void TriggerScreenshotCopy()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenshotAndCopy);
    }

    private void BeginScreenshotSelection(
        ScreenshotCaptureIntent intent,
        string? autoSavePath = null,
        bool hideTranslation = false,
        string? customConfigPath = null,
        string? customToolbarItems = null)
    {
        Dispatcher.Invoke(() =>
        {
#if !EXCLUDE_TRANSLATION
            if (_configStore == null && string.IsNullOrWhiteSpace(customConfigPath)) return;
#endif

            var (bitmap, bounds) = ScreenCapture.CaptureVirtualScreen();
            var config = LoadConfigurationOrDefault(customConfigPath);

            if (!string.IsNullOrWhiteSpace(customToolbarItems))
            {
                var customList = ParseCustomToolbarItems(customToolbarItems);
                if (customList.Count > 0)
                {
                    config.ScreenshotToolbarItems = customList;
                }
            }

            var win = new ScreenSelectionWindow(bitmap, bounds, _translationService, config, intent)
            {
                AutoSavePath = autoSavePath,
                HideTranslation = hideTranslation
            };
            win.Show();
            win.Activate();
        });
    }

    private static List<ScreenshotToolbarItemConfig> ParseCustomToolbarItems(string itemsCsv)
    {
        var tokens = itemsCsv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var list = new List<ScreenshotToolbarItemConfig>();
        foreach (var token in tokens)
        {
            list.Add(new ScreenshotToolbarItemConfig(token, true));
        }
        return ScreenshotToolbarItemConfig.Normalize(list);
    }

    public void TriggerScreenTranslate()
    {
        var config = LoadConfigurationOrDefault();
        if (string.Equals(config.ScreenshotTranslationStyle, "youdao", StringComparison.OrdinalIgnoreCase))
        {
            BeginScreenshotSelection(ScreenshotCaptureIntent.ScreenTranslation);
        }
        else
        {
            BeginScreenshotSelection(ScreenshotCaptureIntent.OcrTranslate);
        }
    }

    public void TriggerOcrTranslate()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.OcrTranslate);
    }

    public void TriggerOcrWorkspace()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.OcrWorkspace);
    }

    public void TriggerOcrTranslationCard()
    {
        BeginScreenshotSelection(ScreenshotCaptureIntent.OcrTranslationCard);
    }

    private AppConfiguration LoadConfigurationOrDefault(string? customConfigPath = null)
    {
        string? targetPath = customConfigPath;

        if (string.IsNullOrWhiteSpace(targetPath))
        {
            string? envPath = Environment.GetEnvironmentVariable("POLYGLANCE_CONFIG");
            if (!string.IsNullOrWhiteSpace(envPath) && File.Exists(envPath))
            {
                targetPath = envPath;
            }
        }

        if (string.IsNullOrWhiteSpace(targetPath))
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string portableConfig = Path.Combine(baseDir, "config.json");
            string namedConfig = Path.Combine(baseDir, "polyglance.json");
            if (File.Exists(portableConfig))
            {
                targetPath = portableConfig;
            }
            else if (File.Exists(namedConfig))
            {
                targetPath = namedConfig;
            }
        }

        if (!string.IsNullOrWhiteSpace(targetPath))
        {
            try
            {
                string fullPath = Path.GetFullPath(targetPath);
                string dir = Path.GetDirectoryName(fullPath) ?? AppDomain.CurrentDomain.BaseDirectory;
                Directory.CreateDirectory(dir);
                var customStore = new ConfigurationStore(fullPath, new DpapiCredentialStore(Path.Combine(dir, "credentials.dat")));
                return customStore.Load();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Config] Failed to load custom config from {targetPath}: {ex.Message}");
            }
        }

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

    private void RecordActiveWindowBeforeTray()
    {
        IntPtr fg = NativeWin32.GetForegroundWindow();
        if (fg != IntPtr.Zero)
        {
            NativeWin32.GetWindowThreadProcessId(fg, out uint pid);
            if (pid != (uint)Environment.ProcessId)
            {
                _lastActiveWindowBeforeTray = fg;
            }
        }
    }

    public async void TriggerSelectedTextTranslateFromTray()
    {
        if (_lastActiveWindowBeforeTray != IntPtr.Zero)
        {
            NativeWin32.SetForegroundWindow(_lastActiveWindowBeforeTray);
            _lastActiveWindowBeforeTray = IntPtr.Zero;
            await Task.Delay(150);
        }
        TriggerSelectedTextTranslate();
    }

    public async void TriggerSelectedTextTranslate()
    {
        TextReplacementService.RecordTargetWindow();
        string? text = await SelectedTextReader.GetSelectedTextAsync();
        if (!string.IsNullOrWhiteSpace(text))
        {
            Dispatcher.Invoke(() =>
            {
                if (_mainWindow != null)
                {
                    var p = System.Windows.Forms.Cursor.Position;
                    _mainWindow.SetAndTranslate(text, new Rect(p.X, p.Y, 1, 1));
                }
            });
        }
    }

    public async void TriggerTranslateAndReplace()
    {
        TextReplacementService.RecordTargetWindow();
        string? text = await SelectedTextReader.GetSelectedTextAsync();
        if (string.IsNullOrWhiteSpace(text) || _translationService == null) return;

        var config = LoadConfigurationOrDefault();
        string targetLang = DetermineTargetLanguage(
            text,
            config.TargetLanguage,
            config.SecondTargetLanguage
        );

        try
        {
            var result = await _translationService.TranslateAsync(
                text,
                targetLang,
                config.SourceLanguage,
                config
            );

            if (result != null && !string.IsNullOrWhiteSpace(result.Text))
            {
                await TextReplacementService.ReplaceSelectedTextAsync(result.Text);
            }
        }
        catch
        {
        }
    }

    private static string DetermineTargetLanguage(string text, string primary, string secondary)
    {
        bool hasChinese = false;
        foreach (char c in text)
        {
            if (c >= 0x4E00 && c <= 0x9FFF)
            {
                hasChinese = true;
                break;
            }
        }

        bool primaryIsChinese = primary.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        if (primaryIsChinese)
        {
            return hasChinese ? (string.IsNullOrWhiteSpace(secondary) ? "en" : secondary) : primary;
        }
        else
        {
            return hasChinese ? primary : (string.IsNullOrWhiteSpace(secondary) ? "zh-Hans" : secondary);
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
        Dispatcher.Invoke(async () =>
        {
            try
            {
                await PinSessionController.For().PinNextClipboardContent(null, null, _translationService, LoadConfigurationOrDefault());
            }
            catch (Exception error) { PinSessionController.Report($"无法读取剪贴板：{error.Message}"); }
        });
    }

    public void RestoreMostRecentPin()
    {
        Dispatcher.Invoke(async () =>
        {
            await PinSessionController.For().Restore(false, _translationService, LoadConfigurationOrDefault());
        });
    }

    public void ShowPinHistory()
    {
        Dispatcher.Invoke(() =>
        {
            if (_pinHistoryWindow == null)
            {
                _pinHistoryWindow = new PinHistoryWindow(_translationService, LoadConfigurationOrDefault());
            }
            _ = _pinHistoryWindow.RefreshItems();
            _pinHistoryWindow.Show();
            _pinHistoryWindow.Activate();
            if (_pinHistoryWindow.WindowState == WindowState.Minimized)
                _pinHistoryWindow.WindowState = WindowState.Normal;
        });
    }

    public void HideAllPins()
    {
        Dispatcher.Invoke(() =>
        {
            foreach (Window window in Application.Current.Windows)
            {
                if (window is PinWindow or TextPinWindow)
                {
                    window.Hide();
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
                if (window is PinWindow or TextPinWindow)
                {
                    window.Show();
                }
            }
        });
    }

    public void CloseAllPins()
    {
        Dispatcher.Invoke(() =>
        {
            foreach (Window window in Application.Current.Windows.Cast<Window>().ToArray())
            {
                if (window is PinWindow or TextPinWindow)
                {
                    window.Close();
                }
            }
        });
    }

    public void TriggerCheckUpdate()
    {
        ShowSettings(initialTab: "About", autoCheckUpdate: true);
    }

    public void ShowMainWindow()
    {
        Dispatcher.Invoke(() =>
        {
            if (_mainWindow != null)
            {
                _mainWindow.ReloadConfiguration();
                _mainWindow.Show();
                _mainWindow.WindowState = WindowState.Normal;
                _mainWindow.Activate();
            }
        });
    }

    public void ShowSettings(string initialTab = "General", bool autoCheckUpdate = false)
    {
        Dispatcher.Invoke(() =>
        {
            if (_configStore == null) return;

            if (_settingsWindow != null && _settingsWindow.IsLoaded)
            {
                if (_settingsWindow.WindowState == WindowState.Minimized)
                {
                    _settingsWindow.WindowState = WindowState.Normal;
                }
                _settingsWindow.SelectTab(initialTab, autoCheckUpdate);
                _settingsWindow.Show();
                _settingsWindow.Activate();
                _settingsWindow.Topmost = true;
                _settingsWindow.Topmost = false;
                _settingsWindow.Focus();
                return;
            }

            var settings = new SettingsWindow(_configStore, initialTab: initialTab, autoCheckUpdate: autoCheckUpdate);
            _settingsWindow = settings;
            settings.Closed += (_, _) =>
            {
                _settingsWindow = null;
                if (settings.IsSaved)
                {
                    var savedConfig = LoadConfigurationOrDefault();
                    DataDirectoryManager.ApplyRootDirectory(savedConfig.DataStorageDirectory);
                    RegisterDynamicHotKeys();
                    _mainWindow?.ReloadConfiguration();
                }
            };
            settings.Show();
            settings.Activate();
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
                    IAppUpdateProvider provider = UpdateProviderFactory.Create(() => LoadConfigurationOrDefault().AppcastUrl);
                    UpdateCheckResult check = await provider.CheckForUpdatesAsync(
                        config.IncludeBetaUpdates,
                        config.SkippedUpdateVersion,
                        cancellationToken);

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

        string updateTitle = update.Channel == DistributionChannel.MicrosoftStore
            ? "🚀 Microsoft Store 发现新版本"
            : (update.IsBeta
                ? $"🧪 发现新测试版 v{update.Version}"
                : $"🚀 发现新版本 v{update.Version}");

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

    public static void ShowNotification(string title, string text, ToolTipIcon icon = ToolTipIcon.Info, int timeoutMs = 2500)
    {
        if (Current is App app && app._notifyIcon != null)
        {
            app._notifyIcon.ShowBalloonTip(timeoutMs, title, text, icon);
        }
    }

    private bool _shuttingDown;

    private async Task ShutdownAppAsync()
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        _hotKeyManager?.Dispose();
        try
        {
            await PinSessionController.For().PrepareForTermination();
        }
        catch { }
        _updateCts?.Cancel();
        _updateCts?.Dispose();
        _updateCts = null;
        _ipcServerCts?.Cancel();
        _ipcServerCts?.Dispose();
        _ipcServerCts = null;
        _notifyIcon?.Dispose();
        if (TranslationService.OfflineHandler is IDisposable offlineDisposable)
        {
            offlineDisposable.Dispose();
            TranslationService.OfflineHandler = null;
        }
        _translationService?.Dispose();
        _hiddenHwndSource?.Dispose();
        _mutex?.Dispose();
        _pinHistoryWindow?.ExplicitClose();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (!_shuttingDown)
        {
            _shuttingDown = true;
            _hotKeyManager?.Dispose();
            try
            {
                Task.Run(() => PinSessionController.For().PrepareForTermination()).Wait(TimeSpan.FromSeconds(2));
            }
            catch { }
            _updateCts?.Cancel();
            _updateCts?.Dispose();
            _updateCts = null;
            _ipcServerCts?.Cancel();
            _ipcServerCts?.Dispose();
            _ipcServerCts = null;
            _notifyIcon?.Dispose();
            if (TranslationService.OfflineHandler is IDisposable offlineDisposable)
            {
                offlineDisposable.Dispose();
                TranslationService.OfflineHandler = null;
            }
            _translationService?.Dispose();
            _hiddenHwndSource?.Dispose();
            _mutex?.Dispose();
            _pinHistoryWindow?.ExplicitClose();
        }
        base.OnExit(e);
    }
}
