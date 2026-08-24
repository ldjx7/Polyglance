using System;
using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
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
            Loaded += (_, _) => MessageBox.Show(
                error.Message,
                "Polyglance 设置",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

        TxtCurrentVersion.Text = $"当前版本: v{Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "0.0.3"}";

        LoadConfigToUi();
    }

    private void LoadConfigToUi()
    {
        foreach (ComboBoxItem item in CmbProvider.Items)
        {
            if (item.Tag?.ToString()?.Equals(_config.Provider, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbProvider.SelectedItem = item;
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
            Loaded += (_, _) => MessageBox.Show(
                $"无法读取开机自启状态：{error.Message}",
                "Polyglance 设置",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        BtnCheckUpdate.IsEnabled = false;
        BtnCheckUpdate.Content = "检查中...";

        try
        {
            var update = await AppUpdater.CheckForUpdatesAsync(_config.AppcastUrl);
            if (update != null)
            {
                var result = MessageBox.Show(
                    $"发现新版本 v{update.Version}！\n\n更新内容:\n{update.ReleaseNotes}\n\n是否立即下载并更新？",
                    "Polyglance 自动更新",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information
                );

                if (result == System.Windows.MessageBoxResult.Yes)
                {
                    BtnCheckUpdate.Content = "正在下载更新...";
                    await AppUpdater.DownloadAndApplyUpdateAsync(update.DownloadUrl);
                }
            }
            else
            {
                MessageBox.Show("当前已是最新版本！", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"检查更新失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Warning);
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
            MessageBox.Show(
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

            MessageBox.Show(
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
