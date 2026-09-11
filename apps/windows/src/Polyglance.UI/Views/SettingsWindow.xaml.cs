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
    private readonly ObservableCollection<ProviderItem> _providerList = new();
    private ProviderItem? _currentSelectedProviderItem;

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
        ["translate"] = new("OCR翻译", "M12.87,15.07 L10.33,12.56 L10.36,12.53 C12.1,10.59 13.34,8.36 14.07,6 H17 V4 H10 V2 H8 V4 H1 V6 H12.17 C11.5,7.92 10.44,9.75 9,11.35 C8.07,10.32 7.3,9.19 6.69,8 H4.69 C5.42,9.63 6.42,11.17 7.67,12.56 L2.58,17.58 L4,19 L9,14 L12.11,17.11 L12.87,15.07 Z M18.5,10 H16.5 L12,22 H14 L15.12,19 H19.87 L21,22 H23 L18.5,10 Z M15.88,17 L17.5,12.67 L19.12,17 H15.88 Z", false),
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
        TxtSidebarVersion.Text = $"版本 {versionStr}";

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
        else if (string.Equals(initialTab, "Favorites", StringComparison.OrdinalIgnoreCase))
        {
            NavFavorites.IsChecked = true;
            OnNavChanged(NavFavorites, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "History", StringComparison.OrdinalIgnoreCase))
        {
            NavHistory.IsChecked = true;
            OnNavChanged(NavHistory, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "Translation", StringComparison.OrdinalIgnoreCase) ||
                 string.Equals(initialTab, "Services", StringComparison.OrdinalIgnoreCase))
        {
            NavTranslation.IsChecked = true;
            OnNavChanged(NavTranslation, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "Shortcuts", StringComparison.OrdinalIgnoreCase))
        {
            NavShortcuts.IsChecked = true;
            OnNavChanged(NavShortcuts, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "OcrSettings", StringComparison.OrdinalIgnoreCase))
        {
            NavOcrSettings.IsChecked = true;
            OnNavChanged(NavOcrSettings, new RoutedEventArgs());
        }
        else if (string.Equals(initialTab, "OcrServices", StringComparison.OrdinalIgnoreCase))
        {
            NavTranslation.IsChecked = true;
            OnNavChanged(NavTranslation, new RoutedEventArgs());
            TabServiceOcr.IsChecked = true;
            OnServiceCategoryChanged(TabServiceOcr, new RoutedEventArgs());
        }
        else
        {
            NavGeneral.IsChecked = true;
            OnNavChanged(NavGeneral, new RoutedEventArgs());
        }
    }

    private List<TranslationRecord> _allFavoriteRecords = new();
    private List<TranslationRecord> _allHistoryRecords = new();

    private void OnNavChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton rb || rb.Tag is not string tag) return;

        switch (tag)
        {
            case "Translation":
                TxtHeaderTitle.Text = "翻译设置";
                TxtHeaderSubtitle.Text = "服务列表、密钥配置与翻译交互偏好";
                break;
            case "Favorites":
                TxtHeaderTitle.Text = "收藏夹";
                TxtHeaderSubtitle.Text = "已收藏的高频词句与常用译文";
                LoadFavorites();
                break;
            case "History":
                TxtHeaderTitle.Text = "历史记录";
                TxtHeaderSubtitle.Text = "本地翻译历史查询与管理";
                LoadHistory();
                break;
            case "OcrSettings":
                TxtHeaderTitle.Text = "OCR 设置";
                TxtHeaderSubtitle.Text = "文字识别格式与自动复制偏好";
                break;
            case "Shortcuts":
                TxtHeaderTitle.Text = "快捷键";
                TxtHeaderSubtitle.Text = "全局快捷键自定义";
                break;
            case "Toolbar":
                TxtHeaderTitle.Text = "录屏与工具栏";
                TxtHeaderSubtitle.Text = "截图工具栏定制与录屏参数配置";
                break;
            case "About":
                TxtHeaderTitle.Text = "关于";
                TxtHeaderSubtitle.Text = "版本信息与技术架构";
                break;
            default:
                TxtHeaderTitle.Text = "通用设置";
                TxtHeaderSubtitle.Text = "系统权限、启动项与基础偏好";
                break;
        }

        PanelGeneral.Visibility = tag == "General" ? Visibility.Visible : Visibility.Collapsed;
        PanelTranslation.Visibility = tag == "Translation" ? Visibility.Visible : Visibility.Collapsed;
        PanelFavorites.Visibility = tag == "Favorites" ? Visibility.Visible : Visibility.Collapsed;
        PanelHistory.Visibility = tag == "History" ? Visibility.Visible : Visibility.Collapsed;
        PanelOcrSettings.Visibility = tag == "OcrSettings" ? Visibility.Visible : Visibility.Collapsed;
        PanelShortcuts.Visibility = tag == "Shortcuts" ? Visibility.Visible : Visibility.Collapsed;
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

        // 备用目标语言
        string secondTargetLang = string.IsNullOrWhiteSpace(_config.SecondTargetLanguage) ? "en" : _config.SecondTargetLanguage;
        foreach (ComboBoxItem item in CmbSecondTargetLang.Items)
        {
            if (item.Tag?.ToString()?.Equals(secondTargetLang, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbSecondTargetLang.SelectedItem = item;
                break;
            }
        }

        TxtEndpoint.Text = _config.Endpoint;
        TxtApiKey.Password = _config.ApiKey;
        TxtModel.Text = _config.Model;
        ChkAiStreaming.IsChecked = _config.AiStreamingEnabled;

        string style = string.IsNullOrWhiteSpace(_config.ScreenshotTranslationStyle) ? "bob" : _config.ScreenshotTranslationStyle;
        foreach (ComboBoxItem item in CmbScreenshotTranslationStyle.Items)
        {
            if (item.Tag?.ToString()?.Equals(style, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbScreenshotTranslationStyle.SelectedItem = item;
                break;
            }
        }

        ChkAiStreaming.IsChecked = _config.AiStreamingEnabled;
        ChkAiStreamingFreeAi.IsChecked = _config.AiStreamingEnabled;
        PopulateServiceProviders();

        TxtDeeplAuthKey.Password = _config.DeeplAuthKey;
        TxtDeeplEndpoint.Text = _config.DeeplEndpoint;
        TxtBaiduAppId.Text = _config.BaiduAppId;
        TxtBaiduSecretKey.Password = _config.BaiduSecretKey;
        TxtYoudaoAppKey.Text = _config.YoudaoAppKey;
        TxtYoudaoSecret.Password = _config.YoudaoSecret;
        TxtVolcanoAccessKey.Text = _config.VolcanoAccessKey;
        TxtVolcanoSecretKey.Password = _config.VolcanoSecretKey;

        RecHotkeyScreenshotPin.Hotkey = _config.HotkeyScreenshotPin;
        RecHotkeyScreenshotCopy.Hotkey = _config.HotkeyScreenshotCopy;
        RecHotkeyPinClipboardImage.Hotkey = _config.HotkeyPinClipboardImage;
        RecHotkeySelectedText.Hotkey = _config.HotkeySelectedText;
        RecHotkeyTranslateAndReplace.Hotkey = _config.HotkeyTranslateAndReplace;
        RecHotkeyScreenTranslate.Hotkey = _config.HotkeyScreenTranslate;
        RecHotkeyOcrWorkspace.Hotkey = _config.HotkeyOcrWorkspace;
        RecHotkeyOcrTranslationCard.Hotkey = _config.HotkeyOcrTranslationCard;
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
        ToggleSaveCompletedScreenshotsToHistory.IsChecked = _config.SaveCompletedScreenshotsToHistory;

        foreach (ComboBoxItem item in CmbOcrFormatting.Items)
        {
            if (item.Tag?.ToString() == _config.OcrDefaultFormatting.ToString())
            {
                CmbOcrFormatting.SelectedItem = item;
                break;
            }
        }
        ToggleOcrAutoCopy.IsChecked = _config.OcrAutoCopyNextTime;

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
        RecHotkeyScreenshotCopy.Hotkey = GlobalShortcutDefaults.ScreenshotCopy;
        RecHotkeyPinClipboardImage.Hotkey = GlobalShortcutDefaults.PinClipboardImage;
        RecHotkeySelectedText.Hotkey = GlobalShortcutDefaults.SelectedText;
        RecHotkeyTranslateAndReplace.Hotkey = GlobalShortcutDefaults.TranslateAndReplace;
        RecHotkeyScreenTranslate.Hotkey = GlobalShortcutDefaults.ScreenTranslate;
        RecHotkeyOcrWorkspace.Hotkey = GlobalShortcutDefaults.OcrWorkspace;
        RecHotkeyOcrTranslationCard.Hotkey = GlobalShortcutDefaults.OcrTranslationCard;
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
            ("截图", RecHotkeyScreenshotPin.Hotkey),
            ("截图并复制", RecHotkeyScreenshotCopy.Hotkey),
            ("剪贴板贴图", RecHotkeyPinClipboardImage.Hotkey),
            ("划词翻译", RecHotkeySelectedText.Hotkey),
            ("划词翻译并替换", RecHotkeyTranslateAndReplace.Hotkey),
            ("截图翻译", RecHotkeyScreenTranslate.Hotkey),
            ("文字识别", RecHotkeyOcrWorkspace.Hotkey),
            ("双语对照卡", RecHotkeyOcrTranslationCard.Hotkey),
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

        if (CmbSecondTargetLang.SelectedItem is ComboBoxItem secondLangItem && secondLangItem.Tag is string secondTargetLang)
        {
            _config.SecondTargetLanguage = secondTargetLang;
        }

        if (CmbScreenshotTranslationStyle.SelectedItem is ComboBoxItem styleItem && styleItem.Tag is string style)
        {
            _config.ScreenshotTranslationStyle = style;
        }

        SyncCurrentCustomAiFromForm();

        foreach (var p in _providerList.Where(p => p.IsCustom))
        {
            if (string.IsNullOrWhiteSpace(p.CustomConfig?.Name))
            {
                ShowStatus("自定义 AI 服务名称不能为空", isError: true);
                return;
            }
        }
        var customNames = _providerList.Where(p => p.IsCustom).Select(p => p.CustomConfig!.Name.Trim()).ToList();
        if (customNames.Count != new HashSet<string>(customNames, StringComparer.OrdinalIgnoreCase).Count)
        {
            ShowStatus("自定义 AI 服务名称不能重复", isError: true);
            return;
        }

        var newEnabled = _providerList
            .Where(p => p.IsEnabled)
            .Select(p => p.Id == "openaicompatible" ? "openai-compatible" : p.Id)
            .ToList();
        _config.EnabledProviders = newEnabled.Count > 0 ? newEnabled : new List<string> { "freeai" };
        _config.ProviderOrder = _providerList.Select(p => p.Id).ToList();
        _config.CustomAIConfigs = _providerList
            .Where(p => p.IsCustom && p.CustomConfig != null)
            .Select(p => p.CustomConfig!)
            .ToList();

        if (_currentSelectedProviderItem?.Id == "openaicompatible")
        {
            _config.Endpoint = TxtEndpoint.Text.Trim();
            _config.ApiKey = TxtApiKey.Password.Trim();
            _config.Model = TxtModel.Text.Trim();
        }
        _config.AiStreamingEnabled = ChkAiStreaming.IsChecked == true;

        _config.DeeplAuthKey = TxtDeeplAuthKey.Password.Trim();
        _config.DeeplEndpoint = TxtDeeplEndpoint.Text.Trim();
        _config.BaiduAppId = TxtBaiduAppId.Text.Trim();
        _config.BaiduSecretKey = TxtBaiduSecretKey.Password.Trim();
        _config.YoudaoAppKey = TxtYoudaoAppKey.Text.Trim();
        _config.YoudaoSecret = TxtYoudaoSecret.Password.Trim();
        _config.VolcanoAccessKey = TxtVolcanoAccessKey.Text.Trim();
        _config.VolcanoSecretKey = TxtVolcanoSecretKey.Password.Trim();

        _config.HotkeyScreenshotPin = RecHotkeyScreenshotPin.Hotkey;
        _config.HotkeyScreenshotCopy = RecHotkeyScreenshotCopy.Hotkey;
        _config.HotkeyPinClipboardImage = RecHotkeyPinClipboardImage.Hotkey;
        _config.HotkeySelectedText = RecHotkeySelectedText.Hotkey;
        _config.HotkeyTranslateAndReplace = RecHotkeyTranslateAndReplace.Hotkey;
        _config.HotkeyScreenTranslate = RecHotkeyScreenTranslate.Hotkey;
        _config.HotkeyOcrWorkspace = RecHotkeyOcrWorkspace.Hotkey;
        _config.HotkeyOcrTranslationCard = RecHotkeyOcrTranslationCard.Hotkey;
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
        _config.SaveCompletedScreenshotsToHistory = ToggleSaveCompletedScreenshotsToHistory.IsChecked == true;

        if (CmbOcrFormatting.SelectedItem is ComboBoxItem ocrItem && int.TryParse(ocrItem.Tag?.ToString(), out int ocrFormat))
        {
            _config.OcrDefaultFormatting = ocrFormat;
        }
        _config.OcrAutoCopyNextTime = ToggleOcrAutoCopy.IsChecked == true;

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

    private void LoadFavorites()
    {
        _allFavoriteRecords = TranslationHistoryStore.Shared.GetFavorites().ToList();
        FilterFavorites();
    }

    private void FilterFavorites()
    {
        string query = TxtFavoriteSearch.Text.Trim();
        var filtered = string.IsNullOrEmpty(query)
            ? _allFavoriteRecords
            : _allFavoriteRecords.Where(r =>
                r.SourceText.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.TargetText.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();

        ListFavorites.ItemsSource = filtered;
        EmptyFavoritesNotice.Visibility = filtered.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (filtered.Count > 0)
        {
            if (ListFavorites.SelectedItem == null || !filtered.Contains(ListFavorites.SelectedItem))
            {
                ListFavorites.SelectedIndex = 0;
            }
        }
        else
        {
            FavoriteDetailPane.Visibility = Visibility.Collapsed;
            TxtFavoriteEmptySelection.Visibility = Visibility.Visible;
        }
    }

    private void OnFavoriteSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        FilterFavorites();
    }

    private void OnFavoriteSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ListFavorites.SelectedItem is TranslationRecord record)
        {
            TxtFavoriteTime.Text = record.Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
            TxtFavoriteSource.Text = record.SourceText;
            TxtFavoriteTarget.Text = record.TargetText;
            TxtFavoriteSourceLang.Text = string.IsNullOrEmpty(record.SourceLang) ? "自动检测" : record.SourceLang;
            TxtFavoriteTargetLang.Text = record.TargetLang;
            TxtFavoriteProvider.Text = record.Provider;

            FavoriteDetailPane.Visibility = Visibility.Visible;
            TxtFavoriteEmptySelection.Visibility = Visibility.Collapsed;
        }
        else
        {
            FavoriteDetailPane.Visibility = Visibility.Collapsed;
            TxtFavoriteEmptySelection.Visibility = Visibility.Visible;
        }
    }

    private void OnDeleteFavoriteClick(object sender, RoutedEventArgs e)
    {
        if (ListFavorites.SelectedItem is TranslationRecord record)
        {
            TranslationHistoryStore.Shared.DeleteRecord(record.Id);
            LoadFavorites();
        }
    }

    private void OnUnfavoriteClick(object sender, RoutedEventArgs e)
    {
        if (ListFavorites.SelectedItem is TranslationRecord record)
        {
            TranslationHistoryStore.Shared.ToggleFavorite(record.Id);
            LoadFavorites();
        }
    }

    private void OnCopyFavoriteSourceClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtFavoriteSource.Text))
        {
            Clipboard.SetText(TxtFavoriteSource.Text);
            ShowStatus("已复制原文");
        }
    }

    private void OnCopyFavoriteTargetClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtFavoriteTarget.Text))
        {
            Clipboard.SetText(TxtFavoriteTarget.Text);
            ShowStatus("已复制译文");
        }
    }

    private void LoadHistory()
    {
        _allHistoryRecords = TranslationHistoryStore.Shared.GetRecords().ToList();
        FilterHistory();
    }

    private void FilterHistory()
    {
        string query = TxtHistorySearch.Text.Trim();
        var filtered = string.IsNullOrEmpty(query)
            ? _allHistoryRecords
            : _allHistoryRecords.Where(r =>
                r.SourceText.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.TargetText.Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();

        ListHistory.ItemsSource = filtered;
        EmptyHistoryNotice.Visibility = filtered.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        if (filtered.Count > 0)
        {
            if (ListHistory.SelectedItem == null || !filtered.Contains(ListHistory.SelectedItem))
            {
                ListHistory.SelectedIndex = 0;
            }
        }
        else
        {
            HistoryDetailPane.Visibility = Visibility.Collapsed;
            TxtHistoryEmptySelection.Visibility = Visibility.Visible;
        }
    }

    private void OnHistorySearchTextChanged(object sender, TextChangedEventArgs e)
    {
        FilterHistory();
    }

    private void OnHistorySelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ListHistory.SelectedItem is TranslationRecord record)
        {
            TxtHistoryTime.Text = record.Timestamp.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
            TxtHistorySource.Text = record.SourceText;
            TxtHistoryTarget.Text = record.TargetText;
            TxtHistorySourceLang.Text = string.IsNullOrEmpty(record.SourceLang) ? "自动检测" : record.SourceLang;
            TxtHistoryTargetLang.Text = record.TargetLang;
            TxtHistoryProvider.Text = record.Provider;

            BtnToggleFavoriteHistory.Foreground = record.IsFavorite
                ? new SolidColorBrush(Color.FromRgb(0xEA, 0xB3, 0x08))
                : (Brush)FindResource("TextFillColorSecondaryBrush");

            HistoryDetailPane.Visibility = Visibility.Visible;
            TxtHistoryEmptySelection.Visibility = Visibility.Collapsed;
        }
        else
        {
            HistoryDetailPane.Visibility = Visibility.Collapsed;
            TxtHistoryEmptySelection.Visibility = Visibility.Visible;
        }
    }

    private void OnDeleteHistoryClick(object sender, RoutedEventArgs e)
    {
        if (ListHistory.SelectedItem is TranslationRecord record)
        {
            TranslationHistoryStore.Shared.DeleteRecord(record.Id);
            LoadHistory();
        }
    }

    private void OnToggleFavoriteHistoryClick(object sender, RoutedEventArgs e)
    {
        if (ListHistory.SelectedItem is TranslationRecord record)
        {
            TranslationHistoryStore.Shared.ToggleFavorite(record.Id);
            LoadHistory();
        }
    }

    private void OnClearHistoryClick(object sender, RoutedEventArgs e)
    {
        if (System.Windows.MessageBox.Show("确定要清空所有翻译历史记录吗？", "清空历史", MessageBoxButton.YesNo, MessageBoxImage.Question) == System.Windows.MessageBoxResult.Yes)
        {
            TranslationHistoryStore.Shared.ClearAll();
            LoadHistory();
        }
    }

    private void OnCopyHistorySourceClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtHistorySource.Text))
        {
            Clipboard.SetText(TxtHistorySource.Text);
            ShowStatus("已复制原文");
        }
    }

    private void OnCopyHistoryTargetClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtHistoryTarget.Text))
        {
            Clipboard.SetText(TxtHistoryTarget.Text);
            ShowStatus("已复制译文");
        }
    }

    private void PopulateServiceProviders()
    {
        _providerList.Clear();
        var defaultOrder = new List<string> { "freeai", "microsoft", "google", "deepl", "baidu", "youdao", "volcano", "openaicompatible" };
        var order = _config.ProviderOrder != null && _config.ProviderOrder.Count > 0 ? _config.ProviderOrder : defaultOrder;
        var enabled = _config.EnabledProviders ?? new List<string> { "freeai" };
        var customConfigs = _config.CustomAIConfigs ?? new List<CustomAIServiceConfig>();
        var customDict = customConfigs.ToDictionary(c => c.Id, StringComparer.OrdinalIgnoreCase);

        var allIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var id in order)
        {
            var norm = NormalizeProviderId(id);
            if (customDict.TryGetValue(norm, out var customCfg))
            {
                if (allIds.Add(norm))
                {
                    _providerList.Add(new ProviderItem
                    {
                        Id = norm,
                        DisplayName = string.IsNullOrEmpty(customCfg.Name) ? "自定义 AI" : customCfg.Name,
                        Subtitle = "自定义 OpenAI 协议 AI 服务",
                        IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/openai.png",
                        IsBuiltin = false,
                        IsEnabled = IsProviderEnabled(norm, enabled),
                        IsCustom = true,
                        CustomConfig = customCfg
                    });
                }
            }
            else if (allIds.Add(norm))
            {
                _providerList.Add(CreateProviderItem(norm, IsProviderEnabled(norm, enabled)));
            }
        }
        foreach (var id in defaultOrder)
        {
            if (allIds.Add(id))
            {
                _providerList.Add(CreateProviderItem(id, IsProviderEnabled(id, enabled)));
            }
        }
        foreach (var custom in customConfigs)
        {
            if (allIds.Add(custom.Id))
            {
                _providerList.Add(new ProviderItem
                {
                    Id = custom.Id,
                    DisplayName = string.IsNullOrEmpty(custom.Name) ? "自定义 AI" : custom.Name,
                    Subtitle = "自定义 OpenAI 协议 AI 服务",
                    IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/openai.png",
                    IsBuiltin = false,
                    IsEnabled = IsProviderEnabled(custom.Id, enabled),
                    IsCustom = true,
                    CustomConfig = custom
                });
            }
        }
        UpdateProviderMovementState();

        ListServiceProviders.ItemsSource = _providerList;
        if (_providerList.Count > 0 && ListServiceProviders.SelectedIndex < 0)
        {
            ListServiceProviders.SelectedIndex = 0;
        }
        else if (ListServiceProviders.SelectedItem is ProviderItem current)
        {
            UpdateSelectedProviderDetails(current);
        }
    }

    private static string NormalizeProviderId(string id) => id.ToLowerInvariant() switch
    {
        "openai-compatible" or "openaicompatible" => "openaicompatible",
        "free-ai" or "freeai" => "freeai",
        _ => id.ToLowerInvariant()
    };

    private static bool IsProviderEnabled(string id, List<string> enabled)
    {
        return enabled.Any(e => NormalizeProviderId(e) == id);
    }

    private static ProviderItem CreateProviderItem(string id, bool isEnabled)
    {
        return id switch
        {
            "freeai" => new ProviderItem
            {
                Id = "freeai",
                DisplayName = "官方 AI",
                Subtitle = "官方内置 AI 翻译服务，无需配置密钥",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/free-ai.png",
                IsBuiltin = true,
                IsEnabled = isEnabled
            },
            "microsoft" => new ProviderItem
            {
                Id = "microsoft",
                DisplayName = "Microsoft 翻译",
                Subtitle = "微软内置翻译服务",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/microsoft.png",
                IsBuiltin = true,
                IsEnabled = isEnabled
            },
            "google" => new ProviderItem
            {
                Id = "google",
                DisplayName = "Google 翻译",
                Subtitle = "谷歌内置翻译服务",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/google.png",
                IsBuiltin = true,
                IsEnabled = isEnabled
            },
            "deepl" => new ProviderItem
            {
                Id = "deepl",
                DisplayName = "DeepL",
                Subtitle = "高品质神经网络机器翻译",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/deepl.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            },
            "baidu" => new ProviderItem
            {
                Id = "baidu",
                DisplayName = "百度翻译",
                Subtitle = "百度通用文本翻译 API",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/baidu.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            },
            "youdao" => new ProviderItem
            {
                Id = "youdao",
                DisplayName = "有道翻译",
                Subtitle = "有道智云文本翻译 API",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/youdao.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            },
            "volcano" => new ProviderItem
            {
                Id = "volcano",
                DisplayName = "火山翻译",
                Subtitle = "字节跳动火山引擎机器翻译",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/volcano.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            },
            "openaicompatible" => new ProviderItem
            {
                Id = "openaicompatible",
                DisplayName = "OpenAI 兼容",
                Subtitle = "支持任意 OpenAI 协议的大语言模型 API",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/openai.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            },
            _ => new ProviderItem
            {
                Id = id,
                DisplayName = id,
                Subtitle = "自定义翻译服务",
                IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/free-ai.png",
                IsBuiltin = false,
                IsEnabled = isEnabled
            }
        };
    }

    private void UpdateProviderMovementState()
    {
        for (int i = 0; i < _providerList.Count; i++)
        {
            _providerList[i].CanMoveUp = i > 0;
            _providerList[i].CanMoveDown = i < _providerList.Count - 1;
        }
    }

    private void SyncCurrentCustomAiFromForm()
    {
        if (_currentSelectedProviderItem is ProviderItem item && item.IsCustom && item.CustomConfig != null)
        {
            item.CustomConfig.Name = TxtCustomAiName.Text.Trim();
            item.CustomConfig.Endpoint = TxtEndpoint.Text.Trim();
            item.CustomConfig.ApiKey = TxtApiKey.Password.Trim();
            item.CustomConfig.Model = TxtModel.Text.Trim();
            item.CustomConfig.Prompt = TxtCustomAiPrompt.Text.Trim();
            item.DisplayName = string.IsNullOrEmpty(item.CustomConfig.Name) ? "自定义 AI" : item.CustomConfig.Name;
        }
    }

    private void UpdateSelectedProviderDetails(ProviderItem item)
    {
        _currentSelectedProviderItem = item;
        try
        {
            ImgSelectedProvider.Source = new System.Windows.Media.Imaging.BitmapImage(new Uri(item.IconPath, UriKind.Absolute));
        }
        catch
        {
            // fallback if icon cannot be loaded
        }
        TxtSelectedProviderTitle.Text = item.DisplayName;
        TxtSelectedProviderSubtitle.Text = item.Subtitle;

        FormFreeAi.Visibility = item.Id == "freeai" ? Visibility.Visible : Visibility.Collapsed;
        FormDeepl.Visibility = item.Id == "deepl" ? Visibility.Visible : Visibility.Collapsed;
        FormBaidu.Visibility = item.Id == "baidu" ? Visibility.Visible : Visibility.Collapsed;
        FormYoudao.Visibility = item.Id == "youdao" ? Visibility.Visible : Visibility.Collapsed;
        FormVolcano.Visibility = item.Id == "volcano" ? Visibility.Visible : Visibility.Collapsed;
        FormOpenAi.Visibility = (item.Id == "openaicompatible" || item.IsCustom) ? Visibility.Visible : Visibility.Collapsed;
        FormBuiltin.Visibility = (item.Id == "microsoft" || item.Id == "google") ? Visibility.Visible : Visibility.Collapsed;

        if (item.IsCustom && item.CustomConfig != null)
        {
            LblCustomAiName.Visibility = Visibility.Visible;
            TxtCustomAiName.Visibility = Visibility.Visible;
            LblCustomAiPrompt.Visibility = Visibility.Visible;
            TxtCustomAiPrompt.Visibility = Visibility.Visible;
            TxtCustomAiPromptHint.Visibility = Visibility.Visible;
            BtnDeleteCustomAi.Visibility = Visibility.Visible;

            TxtCustomAiName.Text = item.CustomConfig.Name;
            TxtEndpoint.Text = item.CustomConfig.Endpoint;
            TxtApiKey.Password = item.CustomConfig.ApiKey;
            TxtModel.Text = item.CustomConfig.Model;
            TxtCustomAiPrompt.Text = item.CustomConfig.Prompt;
            CheckCustomAiNameError();
        }
        else if (item.Id == "openaicompatible")
        {
            LblCustomAiName.Visibility = Visibility.Collapsed;
            TxtCustomAiName.Visibility = Visibility.Collapsed;
            TxtCustomAiNameError.Visibility = Visibility.Collapsed;
            LblCustomAiPrompt.Visibility = Visibility.Collapsed;
            TxtCustomAiPrompt.Visibility = Visibility.Collapsed;
            TxtCustomAiPromptHint.Visibility = Visibility.Collapsed;
            BtnDeleteCustomAi.Visibility = Visibility.Collapsed;

            TxtEndpoint.Text = _config.Endpoint;
            TxtApiKey.Password = _config.ApiKey;
            TxtModel.Text = _config.Model;
        }
    }

    private void OnCustomAiNameChanged(object sender, TextChangedEventArgs e)
    {
        if (_currentSelectedProviderItem is ProviderItem item && item.IsCustom)
        {
            string newName = TxtCustomAiName.Text.Trim();
            if (item.CustomConfig != null)
            {
                item.CustomConfig.Name = newName;
            }
            item.DisplayName = string.IsNullOrEmpty(newName) ? "自定义 AI" : newName;
            TxtSelectedProviderTitle.Text = item.DisplayName;
            CheckCustomAiNameError();
        }
    }

    private void CheckCustomAiNameError()
    {
        if (_currentSelectedProviderItem is ProviderItem item && item.IsCustom)
        {
            string name = TxtCustomAiName.Text.Trim();
            bool isDuplicate = !string.IsNullOrEmpty(name) && _providerList.Any(p => p.IsCustom && p != item && string.Equals(p.CustomConfig?.Name?.Trim(), name, StringComparison.OrdinalIgnoreCase));
            TxtCustomAiNameError.Visibility = isDuplicate ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private void OnProviderSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        SyncCurrentCustomAiFromForm();
        if (ListServiceProviders.SelectedItem is ProviderItem item)
        {
            UpdateSelectedProviderDetails(item);
        }
    }

    private void OnProviderToggleClick(object sender, RoutedEventArgs e)
    {
        if (!_providerList.Any(p => p.IsEnabled))
        {
            var freeAi = _providerList.FirstOrDefault(p => p.Id == "freeai");
            if (freeAi != null) freeAi.IsEnabled = true;
        }
    }

    private Point _providerDragStart;
    private ProviderItem? _draggedProviderItem;
    private FrameworkElement? _capturedProviderDragElement;
    private bool _isProviderDragging;

    private void OnProviderItemPreviewMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left && sender is FrameworkElement elem && elem.DataContext is ProviderItem item)
        {
            if (e.OriginalSource is DependencyObject dep)
            {
                var parent = dep as FrameworkElement;
                while (parent != null && parent != elem)
                {
                    if (parent is Wpf.Ui.Controls.ToggleSwitch) return;
                    parent = VisualTreeHelper.GetParent(parent) as FrameworkElement;
                }
            }

            _providerDragStart = e.GetPosition(this);
            _draggedProviderItem = item;
            _capturedProviderDragElement = elem;
            _isProviderDragging = false;
        }
    }

    private void OnProviderItemMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _draggedProviderItem == null || _capturedProviderDragElement == null)
        {
            return;
        }

        Point current = e.GetPosition(this);
        if (!_isProviderDragging)
        {
            Vector diff = _providerDragStart - current;
            if (Math.Abs(diff.X) > SystemParameters.MinimumHorizontalDragDistance ||
                Math.Abs(diff.Y) > SystemParameters.MinimumVerticalDragDistance)
            {
                _isProviderDragging = true;
                _capturedProviderDragElement.CaptureMouse();
            }
            return;
        }

        Point posInList = e.GetPosition(ListServiceProviders);
        HitTestResult hitResult = VisualTreeHelper.HitTest(ListServiceProviders, posInList);
        if (hitResult?.VisualHit is DependencyObject hit)
        {
            var element = hit as FrameworkElement;
            while (element != null && element != ListServiceProviders)
            {
                if (element.DataContext is ProviderItem targetItem && targetItem != _draggedProviderItem)
                {
                    int oldIdx = _providerList.IndexOf(_draggedProviderItem);
                    int newIdx = _providerList.IndexOf(targetItem);
                    if (oldIdx >= 0 && newIdx >= 0 && oldIdx != newIdx)
                    {
                        _providerList.Move(oldIdx, newIdx);
                        if (_config != null)
                        {
                            _config.ProviderOrder = _providerList.Select(p => p.Id).ToList();
                        }
                    }
                    break;
                }
                element = VisualTreeHelper.GetParent(element) as FrameworkElement;
            }
        }
    }

    private void OnProviderItemMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_capturedProviderDragElement != null)
        {
            if (_capturedProviderDragElement.IsMouseCaptured)
            {
                _capturedProviderDragElement.ReleaseMouseCapture();
            }
            _capturedProviderDragElement = null;
        }
        if (_draggedProviderItem != null)
        {
            ListServiceProviders.SelectedItem = _draggedProviderItem;
        }
        _draggedProviderItem = null;
        _isProviderDragging = false;
    }

    private void OnResetProviderOrderClick(object sender, RoutedEventArgs e)
    {
        var defaultOrder = new List<string> { "freeai", "microsoft", "google", "deepl", "baidu", "youdao", "volcano", "openaicompatible" };
        var dict = _providerList.ToDictionary(p => p.Id);
        _providerList.Clear();
        foreach (var id in defaultOrder)
        {
            if (dict.TryGetValue(id, out var item))
            {
                _providerList.Add(item);
            }
        }
        foreach (var pair in dict)
        {
            if (pair.Value.IsCustom && !_providerList.Contains(pair.Value))
            {
                _providerList.Add(pair.Value);
            }
        }
        UpdateProviderMovementState();
        if (_providerList.Count > 0) ListServiceProviders.SelectedIndex = 0;
    }

    private void OnAddProviderMenuClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();

        var addCustomItem = new MenuItem
        {
            Header = "添加自定义 AI 服务..."
        };
        addCustomItem.Click += (s, args) => AddCustomAiProvider();
        menu.Items.Add(addCustomItem);
        menu.Items.Add(new Separator());

        foreach (var p in _providerList)
        {
            var item = new MenuItem
            {
                Header = p.DisplayName,
                IsChecked = p.IsEnabled
            };
            item.Click += (s, args) =>
            {
                p.IsEnabled = true;
                ListServiceProviders.SelectedItem = p;
            };
            menu.Items.Add(item);
        }
        menu.PlacementTarget = BtnAddProvider;
        menu.IsOpen = true;
    }

    private void AddCustomAiProvider()
    {
        SyncCurrentCustomAiFromForm();

        int counter = 1;
        string candidateName = $"自定义 AI {counter}";
        var existingNames = new HashSet<string>(_providerList.Where(p => p.IsCustom).Select(p => p.CustomConfig?.Name?.Trim() ?? ""), StringComparer.OrdinalIgnoreCase);
        while (existingNames.Contains(candidateName))
        {
            counter++;
            candidateName = $"自定义 AI {counter}";
        }

        string newId = $"custom_{Guid.NewGuid():N}"[..15];
        var customConfig = new CustomAIServiceConfig
        {
            Id = newId,
            Name = candidateName,
            Endpoint = "https://api.openai.com/v1",
            ApiKey = "",
            Model = "gpt-4o-mini",
            Prompt = "",
            IsEnabled = true
        };

        var item = new ProviderItem
        {
            Id = newId,
            DisplayName = candidateName,
            Subtitle = "自定义 OpenAI 协议 AI 服务",
            IconPath = "pack://application:,,,/Polyglance;component/Resources/ProviderIcons/openai.png",
            IsBuiltin = false,
            IsEnabled = true,
            IsCustom = true,
            CustomConfig = customConfig
        };

        _providerList.Add(item);
        UpdateProviderMovementState();
        ListServiceProviders.SelectedItem = item;
    }

    private void OnRemoveProviderClick(object sender, RoutedEventArgs e)
    {
        if (ListServiceProviders.SelectedItem is ProviderItem item)
        {
            DeleteProviderItem(item);
        }
    }

    private void OnDeleteCustomAiClick(object sender, RoutedEventArgs e)
    {
        if (ListServiceProviders.SelectedItem is ProviderItem item && item.IsCustom)
        {
            DeleteProviderItem(item);
        }
    }

    private void DeleteProviderItem(ProviderItem item)
    {
        if (item.IsCustom)
        {
            int idx = _providerList.IndexOf(item);
            _providerList.Remove(item);
            UpdateProviderMovementState();
            if (_providerList.Count > 0)
            {
                ListServiceProviders.SelectedIndex = Math.Clamp(idx, 0, _providerList.Count - 1);
            }
        }
        else
        {
            item.IsEnabled = false;
            if (!_providerList.Any(p => p.IsEnabled))
            {
                var freeAi = _providerList.FirstOrDefault(p => p.Id == "freeai");
                if (freeAi != null) freeAi.IsEnabled = true;
            }
        }
    }

    private void OnCancelProviderSettingsClick(object sender, RoutedEventArgs e)
    {
        LoadConfigToUi();
    }

    private void OnAiStreamingFreeAiClick(object sender, RoutedEventArgs e)
    {
        ChkAiStreaming.IsChecked = ChkAiStreamingFreeAi.IsChecked;
    }

    private void OnAiStreamingOpenAiClick(object sender, RoutedEventArgs e)
    {
        ChkAiStreamingFreeAi.IsChecked = ChkAiStreaming.IsChecked;
    }

    private void OnServiceCategoryChanged(object sender, RoutedEventArgs e)
    {
        bool isTranslation = TabServiceTranslation.IsChecked == true;
        bool isOcr = TabServiceOcr.IsChecked == true;
        bool isTts = TabServiceTts.IsChecked == true;
        bool isPrefs = TabServicePreferences.IsChecked == true;

        ViewServiceTranslation.Visibility = isTranslation ? Visibility.Visible : Visibility.Collapsed;
        ViewServiceOcr.Visibility = isOcr ? Visibility.Visible : Visibility.Collapsed;
        ViewServiceTts.Visibility = isTts ? Visibility.Visible : Visibility.Collapsed;
        ViewServicePreferences.Visibility = isPrefs ? Visibility.Visible : Visibility.Collapsed;
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

public sealed class ProviderItem : System.ComponentModel.INotifyPropertyChanged
{
    private static readonly SolidColorBrush BuiltinBg;
    private static readonly SolidColorBrush BuiltinFg;
    private static readonly SolidColorBrush KeyBg;
    private static readonly SolidColorBrush KeyFg;

    static ProviderItem()
    {
        BuiltinBg = new SolidColorBrush(Color.FromArgb(0x20, 0x10, 0xB9, 0x81));
        BuiltinBg.Freeze();
        BuiltinFg = new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));
        BuiltinFg.Freeze();
        KeyBg = new SolidColorBrush(Color.FromArgb(0x20, 0x0A, 0x84, 0xFF));
        KeyBg.Freeze();
        KeyFg = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        KeyFg.Freeze();
    }

    public string Id { get; set; } = "";

    private string _displayName = "";
    public string DisplayName
    {
        get => _displayName;
        set
        {
            if (_displayName != value)
            {
                _displayName = value;
                OnPropertyChanged(nameof(DisplayName));
            }
        }
    }

    public string Subtitle { get; set; } = "";
    public string IconPath { get; set; } = "";
    public bool IsBuiltin { get; set; }
    public bool IsCustom { get; set; }
    public CustomAIServiceConfig? CustomConfig { get; set; }
    public string BadgeText => IsBuiltin ? "内置" : "秘钥";
    public SolidColorBrush BadgeBackground => IsBuiltin ? BuiltinBg : KeyBg;
    public SolidColorBrush BadgeForeground => IsBuiltin ? BuiltinFg : KeyFg;

    private bool _isEnabled;
    public bool IsEnabled
    {
        get => _isEnabled;
        set
        {
            if (_isEnabled != value)
            {
                _isEnabled = value;
                OnPropertyChanged(nameof(IsEnabled));
            }
        }
    }

    private bool _canMoveUp;
    public bool CanMoveUp
    {
        get => _canMoveUp;
        set
        {
            if (_canMoveUp != value)
            {
                _canMoveUp = value;
                OnPropertyChanged(nameof(CanMoveUp));
            }
        }
    }

    private bool _canMoveDown;
    public bool CanMoveDown
    {
        get => _canMoveDown;
        set
        {
            if (_canMoveDown != value)
            {
                _canMoveDown = value;
                OnPropertyChanged(nameof(CanMoveDown));
            }
        }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged(string name) => PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
}

