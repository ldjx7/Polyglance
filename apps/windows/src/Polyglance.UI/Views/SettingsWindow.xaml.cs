using System;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Startup;
using Polyglance.Platform.Update;
using Wpf.Ui.Controls;

namespace Polyglance.UI.Views;

public partial class SettingsWindow : FluentWindow
{
    private readonly ConfigurationStore _configStore;
    private readonly AppConfiguration _config;
    private readonly StartupRegistrationManager _startupRegistration;

    public SettingsWindow(
        ConfigurationStore configStore,
        StartupRegistrationManager? startupRegistration = null)
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

        TxtCurrentVersion.Text = versionStr;
        TxtAboutVersion.Text = versionStr;

        LoadConfigToUi();
    }

    private void OnNavChanged(object sender, RoutedEventArgs e)
    {
        if (sender is not RadioButton rb || rb.Tag is not string tag) return;

        PanelGeneral.Visibility = tag == "General" ? Visibility.Visible : Visibility.Collapsed;
        PanelServices.Visibility = tag == "Services" ? Visibility.Visible : Visibility.Collapsed;
        PanelShortcuts.Visibility = tag == "Shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        PanelRecording.Visibility = tag == "Recording" ? Visibility.Visible : Visibility.Collapsed;
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
        RecHotkeyScreenTranslate.Hotkey = _config.HotkeyScreenTranslate;
        RecHotkeyMainTranslator.Hotkey = _config.HotkeyMainTranslator;
        RecHotkeySelectedText.Hotkey = _config.HotkeySelectedText;
        RecHotkeyLongScreenshot.Hotkey = _config.HotkeyLongScreenshot;

        ChkAutoCheckUpdates.IsChecked = _config.AutoCheckUpdates;

        try
        {
            ChkLaunchAtLogin.IsChecked = _startupRegistration.IsEnabled;
        }
        catch (Exception error)
        {
            ChkLaunchAtLogin.IsChecked = false;
            Loaded += (_, _) => ShowStatus($"无法读取开机自启状态：{error.Message}", isError: true);
        }
    }

    private void OnResetShortcutsClick(object sender, RoutedEventArgs e)
    {
        RecHotkeyScreenshotPin.Hotkey = "Alt+A";
        RecHotkeyScreenTranslate.Hotkey = "Alt+W";
        RecHotkeyMainTranslator.Hotkey = "Alt+T";
        RecHotkeySelectedText.Hotkey = "Alt+D";
        RecHotkeyLongScreenshot.Hotkey = "Alt+S";
        ShowStatus("快捷键已恢复默认");
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
        TxtUpdateStatus.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        PbUpdateProgress.Visibility = Visibility.Collapsed;
        PbUpdateProgress.Value = 0;

        try
        {
            UpdateCheckResult check = await AppUpdater.CheckForUpdatesAsync(_config.AppcastUrl);
            if (check.Status == UpdateCheckStatus.UpdateAvailable)
            {
                UpdateInfo update = check.Update!;
                TxtUpdateStatus.Text = $"发现新版本 v{update.Version}";
                TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0x10, 0xB9, 0x81));

                var result = System.Windows.MessageBox.Show(
                    $"发现新版本 v{update.Version}！\n\n更新内容:\n{update.ReleaseNotes}\n\n是否立即下载并更新？",
                    "Polyglance 自动更新",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information
                );

                if (result == System.Windows.MessageBoxResult.Yes)
                {
                    BtnCheckUpdate.Content = "正在下载更新...";
                    TxtUpdateStatus.Text = "正在下载更新包 (0%)...";
                    PbUpdateProgress.Visibility = Visibility.Visible;

                    var progress = new Progress<int>(percent =>
                    {
                        PbUpdateProgress.Value = percent;
                        TxtUpdateStatus.Text = $"正在下载更新包 ({percent}%)...";
                    });

                    bool started = await AppUpdater.DownloadAndApplyUpdateAsync(update.DownloadUrl, progress);
                    if (!started)
                    {
                        TxtUpdateStatus.Text = "更新包下载或替换失败";
                        TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
                        System.Windows.MessageBox.Show(
                            "更新包下载或替换失败，请稍后重试，或从 GitHub Release 手动安装。",
                            "Polyglance 自动更新",
                            MessageBoxButton.OK,
                            MessageBoxImage.Warning);
                    }
                }
            }
            else if (check.Status == UpdateCheckStatus.UpToDate)
            {
                TxtUpdateStatus.Text = "当前已是最新版本";
                TxtUpdateStatus.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
                System.Windows.MessageBox.Show("当前已是最新版本！", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                TxtUpdateStatus.Text = string.IsNullOrWhiteSpace(check.ErrorMessage) ? "检查更新失败" : check.ErrorMessage;
                TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
                System.Windows.MessageBox.Show(
                    check.ErrorMessage,
                    "检查更新失败",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
        catch (Exception ex)
        {
            TxtUpdateStatus.Text = $"检查更新异常: {ex.Message}";
            TxtUpdateStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
            System.Windows.MessageBox.Show($"检查更新失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            BtnCheckUpdate.IsEnabled = true;
            BtnCheckUpdate.Content = "立即检查更新";
        }
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
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
        _config.HotkeyScreenTranslate = RecHotkeyScreenTranslate.Hotkey;
        _config.HotkeyMainTranslator = RecHotkeyMainTranslator.Hotkey;
        _config.HotkeySelectedText = RecHotkeySelectedText.Hotkey;
        _config.HotkeyLongScreenshot = RecHotkeyLongScreenshot.Hotkey;

        _config.AutoCheckUpdates = ChkAutoCheckUpdates.IsChecked == true;

        bool previousLaunchAtLoginEnabled;
        try
        {
            previousLaunchAtLoginEnabled = _startupRegistration.IsEnabled;
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
