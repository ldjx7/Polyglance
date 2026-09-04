using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.HotKey;
using Polyglance.Platform.Startup;
using Polyglance.Platform.Update;
using Polyglance.UI.Controls;
using Wpf.Ui.Controls;
using DragEventArgs = System.Windows.DragEventArgs;
using DragDropEffects = System.Windows.DragDropEffects;
using DataObject = System.Windows.DataObject;

namespace Polyglance.UI.Views;

public partial class SettingsWindow : FluentWindow
{
    private readonly ConfigurationStore _configStore;
    private readonly AppConfiguration _config;
    private readonly StartupRegistrationManager _startupRegistration;
    private UpdateInfo? _latestFoundUpdate;
    private readonly ObservableCollection<ToolbarItemViewModel> _toolbarItems = new();
    private readonly ObservableCollection<ToolbarItemViewModel> _previewItems = new();
    private Point _capsuleDragStart;
    private ToolbarItemViewModel? _draggedCapsuleItem;
    private FrameworkElement? _capturedDragElement;
    private bool _isCapsuleDragging;

    private record ToolbarMetadata(string DisplayName, string PathData, bool IsStroke, double StrokeThickness = 1.8);

    private static readonly SolidColorBrush IconColorBrush;

    static SettingsWindow()
    {
        IconColorBrush = new SolidColorBrush(Color.FromRgb(0x2E, 0x2E, 0x2E));
        IconColorBrush.Freeze();
    }

    private static readonly Dictionary<string, ToolbarMetadata> ToolbarItemMetadata = new(StringComparer.OrdinalIgnoreCase)
    {
        ["pen"] = new("画笔", "M3,17.25 V21 H6.75 L17.81,9.94 L14.06,6.19 Z M20.71,7.04 C21.1,6.65 21.1,6.02 20.71,5.63 L18.37,3.29 C17.98,2.9 17.35,2.9 16.96,3.29 L15.13,5.12 L18.88,8.87 Z", false),
        ["rect"] = new("矩形", "M3,3 H21 V21 H3 Z", true, 1.8),
        ["ellipse"] = new("椭圆", "M 2,12 A 10,10 0 1,0 22,12 A 10,10 0 1,0 2,12", true, 1.8),
        ["line"] = new("线条", "M4,18 L18,4", true, 1.8),
        ["arrow"] = new("箭头", "M4,12 H18 M13,7 L18,12 L13,17", true, 1.8),
        ["text"] = new("文字", "M4,4 H20 V8 H13 V20 H11 V8 H4 Z", false),
        ["mosaic"] = new("马赛克", "M3,3 H9 V9 H3 Z M11,3 H17 V9 H11 Z M19,3 H21 V9 H19 Z M3,11 H9 V17 H3 Z M11,11 H17 V17 H11 Z M19,11 H21 V17 H19 Z M3,19 H9 V21 H3 Z M11,19 H17 V21 H11 Z M19,19 H21 V21 H19 Z", false),
        ["number"] = new("序号", "M12,2A10,10 0 1,0 12,22A10,10 0 1,0 12,22Z M11.5,7.5L13,6.5V17H11V9L9.5,10V8.5Z", false),
        ["undo"] = new("撤销", "M12.5,8 C9.85,8 7.45,9 5.6,10.6 L2,7 V16 H11 L7.38,12.38 C8.77,11.22 10.54,10.5 12.5,10.5 C16.04,10.5 19.05,12.81 20.1,16 L22.47,15.22 C21.08,11.01 17.15,8 12.5,8 Z", false),
        ["redo"] = new("重做", "M18.4,10.6 C16.55,9 14.15,8 11.5,8 C6.85,8 2.92,11.01 1.53,15.22 L3.9,16 C4.95,12.81 7.96,10.5 11.5,10.5 C13.46,10.5 15.23,11.22 16.62,12.38 L13,16 H22 V7 L18.4,10.6 Z", false),
        ["ocr"] = new("文字识别 (OCR)", "M3,5 V3 H5 M19,3 H21 V5 M3,19 V21 H5 M19,21 H21 V19 M7,7 H17 V9 H13 V17 H11 V9 H7 Z", true, 1.6),
        ["translate"] = new("识别并翻译", "M12.87,15.07 L10.33,12.56 L10.36,12.53 C12.1,10.59 13.34,8.36 14.07,6 H17 V4 H10 V2 H8 V4 H1 V6 H12.17 C11.5,7.92 10.44,9.75 9,11.35 C8.07,10.32 7.3,9.19 6.69,8 H4.69 C5.42,9.63 6.42,11.17 7.67,12.56 L2.58,17.58 L4,19 L9,14 L12.11,17.11 L12.87,15.07 Z M18.5,10 H16.5 L12,22 H14 L15.12,19 H19.87 L21,22 H23 L18.5,10 Z M15.88,17 L17.5,12.67 L19.12,17 H15.88 Z", false),
        ["barcode"] = new("二维码", "M2,2 H10 V10 H2 Z M4,4 H8 V8 H4 Z M14,2 H22 V10 H14 Z M16,4 H20 V8 H16 Z M2,14 H10 V22 H2 Z M4,16 H8 V20 H4 Z M14,14 H18 V18 H14 Z M18,18 H22 V22 H18 Z M14,20 H16 V22 H14 Z M20,14 H22 V16 H20 Z", false),
        ["pin"] = new("贴图", "M16,12 V4 H17 V2 H7 V4 H8 V12 L6,14 V16 H11 V22 L12,23 L13,22 V16 H18 V14 L16,12 Z", false),
        ["longScreenshot"] = new("长截图", "M6,2 H18 C19.1,2 20,2.9 20,4 V20 C20,21.1 19.1,22 18,22 H6 C4.9,22 4,21.1 4,20 V4 C4,2.9 4.9,2 6,2 Z M12,6 V18 M9,9 L12,6 L15,9 M9,15 L12,18 L15,15", true, 1.6),
        ["screenRecording"] = new("录屏", "M2,6 C2,4.9 2.9,4 4,4 H14 C15.1,4 16,4.9 16,6 V18 C16,19.1 15.1,20 14,20 H4 C2.9,20 2,19.1 2,18 Z M16,10 L22,6 V18 L16,14 Z", false),
        ["save"] = new("保存", "M4,3 H17 L20,6 V20 C20,20.6 19.6,21 19,21 H5 C4.4,21 4,20.6 4,20 Z M7,3 V8 H15 V3 Z M6,13 H18 V20 H6 Z", false),
        ["cancel"] = new("取消", "M5,5 L19,19 M19,5 L5,19", true, 1.8),
        ["copy"] = new("复制", "M16,3 H5 C3.9,3 3,3.9 3,5 V16 M8,7 H19 C20.1,7 21,7.9 21,9 V20 C21,21.1 20.1,22 19,22 H8 C6.9,22 6,21.1 6,20 V9 C6,7.9 6.9,7 8,7 Z", true, 1.7)
    };

    public SettingsWindow(
        ConfigurationStore configStore,
        StartupRegistrationManager? startupRegistration = null,
        string initialTab = "General")
    {
        InitializeComponent();
        _configStore = configStore;
        _startupRegistration = startupRegistration ?? new StartupRegistrationManager(
            new RegistryStartupValueStore(),
            Environment.ProcessPath
                ?? Process.GetCurrentProcess().MainModule?.FileName
                ?? throw new InvalidOperationException("无法确定 Polyglance 可执行文件路径。"));
        try
        {
            _config = _configStore.Load();
        }
        catch (ConfigurationStoreException error)
        {
            _config = new AppConfiguration();
            Loaded += (_, _) => ShowStatus(error.Message, isError: true);
        }

        string versionStr = AppVersionDisplay.FromAssembly(Assembly.GetEntryAssembly());
        bool isCurrentBeta = versionStr.Contains("-beta", StringComparison.OrdinalIgnoreCase);

        TxtCurrentVersion.Text = versionStr;
        TxtAboutVersion.Text = versionStr;

        if (isCurrentBeta)
        {
            TxtVersionType.Text = "Beta 尝鲜";
            TxtVersionType.Foreground = new SolidColorBrush(Color.FromRgb(0x8B, 0x5C, 0xF6));
            BadgeVersionType.Background = new SolidColorBrush(Color.FromArgb(0x20, 0x8B, 0x5C, 0xF6));
        }
        else
        {
            TxtVersionType.Text = "正式版";
            TxtVersionType.Foreground = new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));
            BadgeVersionType.Background = new SolidColorBrush(Color.FromArgb(0x20, 0x10, 0xB9, 0x81));
        }

        LoadConfigToUi();

        if (string.Equals(initialTab, "About", StringComparison.OrdinalIgnoreCase))
        {
            NavAbout.IsChecked = true;
            OnNavChanged(NavAbout, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "Toolbar", StringComparison.OrdinalIgnoreCase))
        {
            NavToolbar.IsChecked = true;
            OnNavChanged(NavToolbar, new RoutedEventArgs());
        }
    }

    private void OnNavChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton rb || rb.Tag is not string tag) return;

        PanelGeneral.Visibility = tag == "General" ? Visibility.Visible : Visibility.Collapsed;
        PanelServices.Visibility = tag == "Services" ? Visibility.Visible : Visibility.Collapsed;
        PanelShortcuts.Visibility = tag == "Shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        PanelRecording.Visibility = tag == "Recording" ? Visibility.Visible : Visibility.Collapsed;
        PanelToolbar.Visibility = tag == "Toolbar" ? Visibility.Visible : Visibility.Collapsed;
        PanelAbout.Visibility = tag == "About" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void LoadConfigToUi()
    {
        // 1. 服务提供商
        foreach (ComboBoxItem item in CmbProvider.Items)
        {
            if (item.Tag?.ToString()?.Equals(_config.Provider, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbProvider.SelectedItem = item;
                break;
            }
        }

        // 2. 默认目标语言
        string targetLang = string.IsNullOrWhiteSpace(_config.TargetLanguage) ? "zh-Hans" : _config.TargetLanguage;
        foreach (ComboBoxItem item in CmbTargetLang.Items)
        {
            if (item.Tag?.ToString()?.Equals(targetLang, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbTargetLang.SelectedItem = item;
                break;
            }
        }

        TxtEndpoint.Text = _config.Endpoint;
        TxtApiKey.Password = _config.ApiKey;
        TxtModel.Text = _config.Model;
        ChkAiStreaming.IsChecked = _config.AiStreamingEnabled;

        RecHotkeyScreenshotPin.Hotkey = _config.HotkeyScreenshotPin;
        RecHotkeyPinClipboardImage.Hotkey = _config.HotkeyPinClipboardImage;
        RecHotkeySelectedText.Hotkey = _config.HotkeySelectedText;
        RecHotkeyScreenTranslate.Hotkey = _config.HotkeyScreenTranslate;
        RecHotkeyLongScreenshot.Hotkey = _config.HotkeyLongScreenshot;
        RecHotkeyScreenRecording.Hotkey = _config.HotkeyScreenRecording;
        RecHotkeyRestoreMostRecentPin.Hotkey = _config.HotkeyRestoreMostRecentPin;
        RecHotkeyMainTranslator.Hotkey = _config.HotkeyMainTranslator;

        SwIncludeBetaUpdates.IsChecked = _config.IncludeBetaUpdates;
        SelectComboBoxItemByTag(CmbDefaultRecordFormat, _config.DefaultRecordingFormat, "MP4");
        SelectComboBoxItemByTag(CmbDefaultRecordFps, _config.DefaultRecordingFps.ToString(), "30");
        SelectComboBoxItemByTag(
            CmbDefaultRecordDelay,
            _config.DefaultRecordingDelaySeconds.ToString(),
            "0");

        try
        {
            ChkLaunchAtLogin.IsChecked = _startupRegistration.RefreshRegistration();
        }
        catch (Exception error)
        {
            ChkLaunchAtLogin.IsChecked = false;
            Loaded += (_, _) => ShowStatus($"无法读取开机自启状态：{error.Message}", isError: true);
        }

        ListToolbarItems.ItemsSource = _toolbarItems;
        PreviewToolbarItems.ItemsSource = _previewItems;
        _toolbarItems.Clear();
        foreach (var item in ScreenshotToolbarItemConfig.Normalize(_config.ScreenshotToolbarItems))
        {
            _toolbarItems.Add(CreateToolbarItemViewModel(item.Id, item.IsVisible));
        }
        UpdatePreviewItems();
    }

    private ToolbarItemViewModel CreateToolbarItemViewModel(string id, bool isVisible)
    {
        var meta = ToolbarItemMetadata.TryGetValue(id, out var m)
            ? m
            : new ToolbarMetadata(id, "M3,3 H21 V21 H3 Z", true, 1.8);

        Geometry? geometry = null;
        try
        {
            geometry = Geometry.Parse(meta.PathData);
            geometry.Freeze();
        }
        catch
        {
        }

        var vm = new ToolbarItemViewModel
        {
            Id = id,
            DisplayName = meta.DisplayName,
            IsVisible = isVisible,
            IconData = geometry,
            IconBrush = meta.IsStroke ? null : IconColorBrush,
            IconStrokeBrush = meta.IsStroke ? IconColorBrush : null,
            StrokeThickness = meta.IsStroke ? meta.StrokeThickness : 0
        };

        vm.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ToolbarItemViewModel.IsVisible))
            {
                UpdatePreviewItems();
            }
        };

        return vm;
    }

    private void UpdatePreviewItems()
    {
        _previewItems.Clear();
        foreach (var item in _toolbarItems)
        {
            if (item.IsVisible)
            {
                _previewItems.Add(item);
            }
        }
        if (TxtActiveToolbarCount != null)
        {
            TxtActiveToolbarCount.Text = $"已启用 {_previewItems.Count} / {_toolbarItems.Count}";
        }
    }

    private void OnCapsuleItemMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed && sender is FrameworkElement elem && elem.Tag is ToolbarItemViewModel item)
        {
            if (e.OriginalSource is DependencyObject dep)
            {
                var parent = dep as FrameworkElement;
                while (parent != null && parent != elem)
                {
                    if (parent is System.Windows.Controls.Button) return;
                    parent = VisualTreeHelper.GetParent(parent) as FrameworkElement;
                }
            }

            _capsuleDragStart = e.GetPosition(this);
            _draggedCapsuleItem = item;
            _capturedDragElement = elem;
            _isCapsuleDragging = false;
        }
    }

    private void OnCapsuleItemMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _draggedCapsuleItem == null || _capturedDragElement == null)
        {
            return;
        }

        Point current = e.GetPosition(this);
        if (!_isCapsuleDragging)
        {
            Vector diff = _capsuleDragStart - current;
            if (Math.Abs(diff.X) > SystemParameters.MinimumHorizontalDragDistance ||
                Math.Abs(diff.Y) > SystemParameters.MinimumVerticalDragDistance)
            {
                _isCapsuleDragging = true;
                _draggedCapsuleItem.IsDragging = true;
                _capturedDragElement.CaptureMouse();
            }
            return;
        }

        Point posInPreview = e.GetPosition(PreviewToolbarItems);
        HitTestResult hitResult = VisualTreeHelper.HitTest(PreviewToolbarItems, posInPreview);
        if (hitResult?.VisualHit is DependencyObject hit)
        {
            var element = hit as FrameworkElement;
            while (element != null && element != PreviewToolbarItems)
            {
                if (element.DataContext is ToolbarItemViewModel targetItem && targetItem != _draggedCapsuleItem)
                {
                    int oldPreviewIdx = _previewItems.IndexOf(_draggedCapsuleItem);
                    int newPreviewIdx = _previewItems.IndexOf(targetItem);
                    if (oldPreviewIdx >= 0 && newPreviewIdx >= 0 && oldPreviewIdx != newPreviewIdx)
                    {
                        _previewItems.Move(oldPreviewIdx, newPreviewIdx);

                        int oldMasterIdx = _toolbarItems.IndexOf(_draggedCapsuleItem);
                        int newMasterIdx = _toolbarItems.IndexOf(targetItem);
                        if (oldMasterIdx >= 0 && newMasterIdx >= 0)
                        {
                            _toolbarItems.Move(oldMasterIdx, newMasterIdx);
                        }
                    }
                    break;
                }
                element = VisualTreeHelper.GetParent(element) as FrameworkElement;
            }
        }
    }

    private void OnCapsuleItemMouseUp(object sender, MouseButtonEventArgs e)
    {
        EndCapsuleDrag();
    }

    private void EndCapsuleDrag()
    {
        if (_capturedDragElement != null)
        {
            if (_capturedDragElement.IsMouseCaptured)
            {
                _capturedDragElement.ReleaseMouseCapture();
            }
            _capturedDragElement = null;
        }

        if (_draggedCapsuleItem != null)
        {
            _draggedCapsuleItem.IsDragging = false;
            _draggedCapsuleItem = null;
        }

        _isCapsuleDragging = false;
    }

    private void OnRemoveToolbarItemClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement elem && elem.Tag is ToolbarItemViewModel item)
        {
            if (_previewItems.Count <= 1)
            {
                ShowStatus("至少保留一个工具栏按钮", isError: true);
                return;
            }

            item.IsVisible = false;
            UpdatePreviewItems();
            ShowStatus($"已从工具栏移除 {item.DisplayName}");
        }
    }

    private void OnToolbarCardClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement elem && elem.Tag is ToolbarItemViewModel item)
        {
            if (item.IsVisible)
            {
                if (_previewItems.Count <= 1)
                {
                    ShowStatus("至少保留一个工具栏按钮", isError: true);
                    return;
                }
                item.IsVisible = false;
                ShowStatus($"已从工具栏移除 {item.DisplayName}");
            }
            else
            {
                item.IsVisible = true;
                ShowStatus($"已添加 {item.DisplayName} 到工具栏");
            }
            UpdatePreviewItems();
        }
    }

    private static void SelectComboBoxItemByTag(
        System.Windows.Controls.ComboBox comboBox,
        string value,
        string fallback)
    {
        ComboBoxItem? fallbackItem = null;
        foreach (ComboBoxItem item in comboBox.Items)
        {
            string tag = item.Tag?.ToString() ?? string.Empty;
            if (tag.Equals(fallback, StringComparison.OrdinalIgnoreCase))
            {
                fallbackItem = item;
            }
            if (tag.Equals(value, StringComparison.OrdinalIgnoreCase))
            {
                comboBox.SelectedItem = item;
                return;
            }
        }

        comboBox.SelectedItem = fallbackItem ?? comboBox.Items[0];
    }

    private static string SelectedTag(System.Windows.Controls.ComboBox comboBox, string fallback) =>
        (comboBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? fallback;

    private void OnResetShortcutsClick(object sender, RoutedEventArgs e)
    {
        RecHotkeyScreenshotPin.Hotkey = GlobalShortcutDefaults.Screenshot;
        RecHotkeyPinClipboardImage.Hotkey = GlobalShortcutDefaults.PinClipboardImage;
        RecHotkeySelectedText.Hotkey = GlobalShortcutDefaults.SelectedText;
        RecHotkeyScreenTranslate.Hotkey = GlobalShortcutDefaults.ScreenTranslate;
        RecHotkeyLongScreenshot.Hotkey = GlobalShortcutDefaults.LongScreenshot;
        RecHotkeyScreenRecording.Hotkey = GlobalShortcutDefaults.ScreenRecording;
        RecHotkeyRestoreMostRecentPin.Hotkey = GlobalShortcutDefaults.RestoreMostRecentPin;
        RecHotkeyMainTranslator.Hotkey = GlobalShortcutDefaults.MainTranslator;
        ShowStatus("快捷键已恢复默认");
    }

    private void OnResetToolbarItemsClick(object sender, RoutedEventArgs e)
    {
        _toolbarItems.Clear();
        foreach (var item in ScreenshotToolbarItemConfig.DefaultItems())
        {
            _toolbarItems.Add(CreateToolbarItemViewModel(item.Id, item.IsVisible));
        }
        UpdatePreviewItems();
        ShowStatus("截图工具栏已恢复默认设置");
    }

    private void ShowStatus(string message, bool isError = false)
    {
        TxtStatusMessage.Text = message;
        TxtStatusMessage.Foreground = isError
            ? new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44))
            : new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));
    }

    private async void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        BtnCheckUpdate.IsEnabled = false;
        BtnCheckUpdate.Content = "检查中...";
        TxtUpdateStatus.Visibility = Visibility.Visible;
        TxtUpdateStatus.Text = "正在连接更新服务器...";
        TxtUpdateStatus.SetResourceReference(
            System.Windows.Controls.TextBlock.ForegroundProperty,
            "TextFillColorSecondaryBrush");
        BorderAvailableUpdate.Visibility = Visibility.Collapsed;
        PbUpdateProgress.Visibility = Visibility.Collapsed;
        PbUpdateProgress.Value = 0;

        bool includeBeta = SwIncludeBetaUpdates.IsChecked == true;

        try
        {
            UpdateCheckResult check = await AppUpdater.CheckForUpdatesAsync(
                _config.AppcastUrl,
                includeBeta,
                _config.SkippedUpdateVersion);

            if (check.Status == UpdateCheckStatus.UpdateAvailable)
            {
                _latestFoundUpdate = check.Update!;
                TxtUpdateStatus.Visibility = Visibility.Collapsed;
                BorderAvailableUpdate.Visibility = Visibility.Visible;

                TxtNewVersionTitle.Text = $"发现新版本 v{_latestFoundUpdate.Version}";
                if (_latestFoundUpdate.IsBeta)
                {
                    TxtNewVersionType.Text = "Beta 测试版";
                    TxtNewVersionType.Foreground = new SolidColorBrush(Color.FromRgb(0x8B, 0x5C, 0xF6));
                    BadgeNewVersionType.Background = new SolidColorBrush(Color.FromArgb(0x20, 0x8B, 0x5C, 0xF6));
                    BtnSkipVersion.Visibility = Visibility.Visible;
                }
                else
                {
                    TxtNewVersionType.Text = "正式版";
                    TxtNewVersionType.Foreground = new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));
                    BadgeNewVersionType.Background = new SolidColorBrush(Color.FromArgb(0x20, 0x10, 0xB9, 0x81));
                    BtnSkipVersion.Visibility = Visibility.Collapsed;
                }

                TxtReleaseNotes.Text = string.IsNullOrWhiteSpace(_latestFoundUpdate.ReleaseNotes)
                    ? "包含多项体验优化与功能更新。"
                    : _latestFoundUpdate.ReleaseNotes;
            }
            else if (check.Status == UpdateCheckStatus.UpToDate)
            {
                TxtUpdateStatus.Text = "当前已是最新版本";
                TxtUpdateStatus.SetResourceReference(
                    System.Windows.Controls.TextBlock.ForegroundProperty,
                    "TextFillColorSecondaryBrush");
            }
            else
            {
                TxtUpdateStatus.Text = string.IsNullOrWhiteSpace(check.ErrorMessage) ? "检查更新失败" : check.ErrorMessage;
                TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
            }
        }
        catch (Exception ex)
        {
            TxtUpdateStatus.Text = $"检查更新异常: {ex.Message}";
            TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
        }
        finally
        {
            BtnCheckUpdate.IsEnabled = true;
            BtnCheckUpdate.Content = "立即检查更新";
        }
    }

    private void OnSkipVersionClick(object sender, RoutedEventArgs e)
    {
        if (_latestFoundUpdate != null)
        {
            _config.SkippedUpdateVersion = _latestFoundUpdate.Version;
            try
            {
                _configStore.Save(_config);
            }
            catch { }
            BorderAvailableUpdate.Visibility = Visibility.Collapsed;
            TxtUpdateStatus.Visibility = Visibility.Visible;
            TxtUpdateStatus.Text = $"已跳过版本 v{_latestFoundUpdate.Version}，有更高版本时将再次提醒。";
            TxtUpdateStatus.SetResourceReference(
                System.Windows.Controls.TextBlock.ForegroundProperty,
                "TextFillColorSecondaryBrush");
        }
    }

    private async void OnApplyUpdateClick(object sender, RoutedEventArgs e)
    {
        if (_latestFoundUpdate == null) return;

        BtnApplyUpdate.IsEnabled = false;
        BtnSkipVersion.IsEnabled = false;
        BtnCheckUpdate.IsEnabled = false;
        PbUpdateProgress.Visibility = Visibility.Visible;
        TxtUpdateStatus.Visibility = Visibility.Visible;
        TxtUpdateStatus.Text = "正在下载更新包 (0%)...";
        TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));

        var progress = new Progress<int>(percent =>
        {
            PbUpdateProgress.Value = percent;
            TxtUpdateStatus.Text = $"正在下载更新包 ({percent}%)...";
        });

        bool started = await AppUpdater.DownloadAndApplyUpdateAsync(_latestFoundUpdate.DownloadUrl, progress);
        if (!started)
        {
            TxtUpdateStatus.Text = "更新包下载或替换失败，请稍后重试";
            TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
            BtnApplyUpdate.IsEnabled = true;
            BtnSkipVersion.IsEnabled = true;
            BtnCheckUpdate.IsEnabled = true;
        }
    }

    /// <summary>
    /// Rejects shortcuts Windows would refuse before they are written to disk.
    /// Saving one and finding out later that it does nothing is the hardest
    /// version of this to diagnose.
    /// </summary>
    private bool ValidateShortcuts()
    {
        (string Label, string Value)[] shortcuts =
        {
            ("截图贴图", RecHotkeyScreenshotPin.Hotkey),
            ("剪贴板贴图", RecHotkeyPinClipboardImage.Hotkey),
            ("划词翻译", RecHotkeySelectedText.Hotkey),
            ("截图翻译", RecHotkeyScreenTranslate.Hotkey),
            ("长截图", RecHotkeyLongScreenshot.Hotkey),
            ("屏幕录制", RecHotkeyScreenRecording.Hotkey),
            ("恢复最近贴图", RecHotkeyRestoreMostRecentPin.Hotkey),
            ("主窗口", RecHotkeyMainTranslator.Hotkey),
        };

        var problems = new List<string>();
        var assigned = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach ((string label, string value) in shortcuts)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            if (!ShortcutDefinition.TryParse(value, out _, out string? error))
            {
                problems.Add($"{label}：{error}");
                continue;
            }

            if (assigned.TryGetValue(value, out string? owner))
            {
                problems.Add($"{label} 与 {owner} 都使用了 {ShortcutRecorderControl.FormatHotkeyForDisplay(value)}");
                continue;
            }

            assigned[value] = label;
        }

        if (problems.Count == 0)
        {
            return true;
        }

        System.Windows.MessageBox.Show(
            string.Join("\n", problems),
            "快捷键无法使用",
            MessageBoxButton.OK,
            MessageBoxImage.Warning);
        return false;
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (!ValidateShortcuts())
        {
            return;
        }

        if (CmbProvider.SelectedItem is ComboBoxItem item && item.Tag is string provider)
        {
            _config.Provider = provider;
        }

        if (CmbTargetLang.SelectedItem is ComboBoxItem langItem && langItem.Tag is string targetLang)
        {
            _config.TargetLanguage = targetLang;
        }

        _config.Endpoint = TxtEndpoint.Text.Trim();
        _config.ApiKey = TxtApiKey.Password.Trim();
        _config.Model = TxtModel.Text.Trim();
        _config.AiStreamingEnabled = ChkAiStreaming.IsChecked == true;

        _config.HotkeyScreenshotPin = RecHotkeyScreenshotPin.Hotkey;
        _config.HotkeyPinClipboardImage = RecHotkeyPinClipboardImage.Hotkey;
        _config.HotkeySelectedText = RecHotkeySelectedText.Hotkey;
        _config.HotkeyScreenTranslate = RecHotkeyScreenTranslate.Hotkey;
        _config.HotkeyLongScreenshot = RecHotkeyLongScreenshot.Hotkey;
        _config.HotkeyScreenRecording = RecHotkeyScreenRecording.Hotkey;
        _config.HotkeyRestoreMostRecentPin = RecHotkeyRestoreMostRecentPin.Hotkey;
        _config.HotkeyMainTranslator = RecHotkeyMainTranslator.Hotkey;

        _config.IncludeBetaUpdates = SwIncludeBetaUpdates.IsChecked == true;
        _config.DefaultRecordingFormat = SelectedTag(CmbDefaultRecordFormat, "MP4");
        _config.DefaultRecordingFps = int.TryParse(
            SelectedTag(CmbDefaultRecordFps, "30"),
            out int recordingFps)
            ? recordingFps
            : 30;
        _config.DefaultRecordingDelaySeconds = int.TryParse(
            SelectedTag(CmbDefaultRecordDelay, "0"),
            out int recordingDelay)
            ? recordingDelay
            : 0;

        _config.ScreenshotToolbarItems = _toolbarItems
            .Select(vm => new ScreenshotToolbarItemConfig(vm.Id, vm.IsVisible))
            .ToList();

        bool previousLaunchAtLoginEnabled;
        try
        {
            previousLaunchAtLoginEnabled = _startupRegistration.RefreshRegistration();
        }
        catch (Exception error)
        {
            System.Windows.MessageBox.Show(
                $"无法读取开机自启状态：{error.Message}",
                "保存设置失败",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        bool startupSettingWasApplied = false;
        try
        {
            _startupRegistration.SetEnabled(ChkLaunchAtLogin.IsChecked == true);
            startupSettingWasApplied = true;
            _configStore.Save(_config);
            DialogResult = true;
            Close();
        }
        catch (Exception error)
        {
            if (startupSettingWasApplied)
            {
                try
                {
                    _startupRegistration.SetEnabled(previousLaunchAtLoginEnabled);
                }
                catch
                {
                    // Keep the original save error visible to the user.
                }
            }

            System.Windows.MessageBox.Show(
                error.Message,
                "保存设置失败",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}

public sealed class ToolbarItemViewModel : System.ComponentModel.INotifyPropertyChanged
{
    private static readonly Geometry CheckmarkGeom;
    private static readonly SolidColorBrush CheckedCardBg;
    private static readonly SolidColorBrush CheckedCardBorder;
    private static readonly SolidColorBrush CheckedText;
    private static readonly SolidColorBrush CheckedBadgeBg;
    private static readonly SolidColorBrush CheckedBadgeBorder;
    private static readonly SolidColorBrush CheckedBadgeStroke;
    private static readonly SolidColorBrush UncheckedCardBg;
    private static readonly SolidColorBrush UncheckedCardBorder;
    private static readonly SolidColorBrush UncheckedText;
    private static readonly SolidColorBrush UncheckedBadgeBg;
    private static readonly SolidColorBrush UncheckedBadgeBorder;
    private static readonly Thickness CheckedBorderThickness = new(0);
    private static readonly Thickness UncheckedBorderThickness = new(1.2);

    static ToolbarItemViewModel()
    {
        CheckmarkGeom = Geometry.Parse("M2,5.5 L5,8.5 L10.5,2.5");
        CheckmarkGeom.Freeze();

        CheckedCardBg = new SolidColorBrush(Color.FromArgb(0x14, 0x25, 0x63, 0xEB));
        CheckedCardBg.Freeze();
        CheckedCardBorder = new SolidColorBrush(Color.FromArgb(0x50, 0x25, 0x63, 0xEB));
        CheckedCardBorder.Freeze();
        CheckedText = new SolidColorBrush(Color.FromRgb(0x1D, 0x4E, 0xD8));
        CheckedText.Freeze();
        CheckedBadgeBg = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
        CheckedBadgeBg.Freeze();
        CheckedBadgeBorder = new SolidColorBrush(Color.FromRgb(0x25, 0x63, 0xEB));
        CheckedBadgeBorder.Freeze();
        CheckedBadgeStroke = new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF));
        CheckedBadgeStroke.Freeze();

        UncheckedCardBg = new SolidColorBrush(Color.FromArgb(0x06, 0x00, 0x00, 0x00));
        UncheckedCardBg.Freeze();
        UncheckedCardBorder = new SolidColorBrush(Color.FromArgb(0x18, 0x00, 0x00, 0x00));
        UncheckedCardBorder.Freeze();
        UncheckedText = new SolidColorBrush(Color.FromRgb(0x4B, 0x55, 0x63));
        UncheckedText.Freeze();
        UncheckedBadgeBg = new SolidColorBrush(Colors.Transparent);
        UncheckedBadgeBg.Freeze();
        UncheckedBadgeBorder = new SolidColorBrush(Color.FromRgb(0x9C, 0xA3, 0xAF));
        UncheckedBadgeBorder.Freeze();
    }

    public string Id { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public Geometry? IconData { get; set; }
    public Brush? IconBrush { get; set; }
    public Brush? IconStrokeBrush { get; set; }
    public double StrokeThickness { get; set; }

    private bool _isVisible = true;
    public bool IsVisible
    {
        get => _isVisible;
        set
        {
            if (_isVisible != value)
            {
                _isVisible = value;
                OnPropertyChanged(nameof(IsVisible));
                OnPropertyChanged(nameof(CardBackgroundBrush));
                OnPropertyChanged(nameof(CardBorderBrush));
                OnPropertyChanged(nameof(TextBrush));
                OnPropertyChanged(nameof(BadgeBackgroundBrush));
                OnPropertyChanged(nameof(BadgeBorderBrush));
                OnPropertyChanged(nameof(BadgeBorderThickness));
                OnPropertyChanged(nameof(BadgeStrokeBrush));
                OnPropertyChanged(nameof(BadgeIconData));
            }
        }
    }

    public Brush CardBackgroundBrush => IsVisible ? CheckedCardBg : UncheckedCardBg;
    public Brush CardBorderBrush => IsVisible ? CheckedCardBorder : UncheckedCardBorder;
    public Brush TextBrush => IsVisible ? CheckedText : UncheckedText;
    public Brush BadgeBackgroundBrush => IsVisible ? CheckedBadgeBg : UncheckedBadgeBg;
    public Brush BadgeBorderBrush => IsVisible ? CheckedBadgeBorder : UncheckedBadgeBorder;
    public Thickness BadgeBorderThickness => IsVisible ? CheckedBorderThickness : UncheckedBorderThickness;
    public Brush BadgeStrokeBrush => IsVisible ? CheckedBadgeStroke : CheckedBadgeBg;
    public Geometry? BadgeIconData => IsVisible ? CheckmarkGeom : null;

    private bool _isDragging;
    public bool IsDragging
    {
        get => _isDragging;
        set
        {
            if (_isDragging != value)
            {
                _isDragging = value;
                OnPropertyChanged(nameof(IsDragging));
                OnPropertyChanged(nameof(CapsuleOpacity));
                OnPropertyChanged(nameof(CapsuleScale));
            }
        }
    }

    public double CapsuleOpacity => _isDragging ? 0.35 : 1.0;
    public double CapsuleScale => _isDragging ? 0.90 : 1.0;

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
}

