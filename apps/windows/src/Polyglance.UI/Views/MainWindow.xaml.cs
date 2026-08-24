using System;
using System.ComponentModel;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.UI.Services;
using Wpf.Ui.Controls;

namespace Polyglance.UI.Views;

public partial class MainWindow : FluentWindow
{
    private readonly TranslationService _translationService;
    private readonly ConfigurationStore _configStore;
    private AppConfiguration _config;
    private bool _isPinned = false;
    private DispatcherTimer? _debounceTimer;

    public MainWindow(TranslationService translationService, ConfigurationStore configStore)
    {
        InitializeComponent();
        _translationService = translationService;
        _configStore = configStore;
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

        SyncProviderSelection();

        KeyDown += OnWindowKeyDown;
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // 彻底解决关闭后再次调用 Show 崩溃的异常：拦截关闭改为隐藏
        e.Cancel = true;
        Hide();
    }

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        // 未选择置顶时，点击外部失焦自动隐藏
        if (!_isPinned && IsVisible)
        {
            Hide();
        }
    }

    private void SyncProviderSelection()
    {
        foreach (ComboBoxItem item in CmbProvider.Items)
        {
            if (item.Tag?.ToString()?.Equals(_config.Provider, StringComparison.OrdinalIgnoreCase) == true)
            {
                CmbProvider.SelectedItem = item;
                break;
            }
        }
    }

    private void OnProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        if (CmbProvider.SelectedItem is ComboBoxItem item && item.Tag is string provider)
        {
            _config.Provider = provider;
            _configStore.Save(_config);
            if (!string.IsNullOrWhiteSpace(TxtSource.Text))
            {
                OnTranslateClick(this, new RoutedEventArgs());
            }
        }
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        if (!string.IsNullOrWhiteSpace(TxtSource.Text))
        {
            OnTranslateClick(this, new RoutedEventArgs());
        }
    }

    private void OnSwapLanguageClick(object sender, RoutedEventArgs e)
    {
        int srcIdx = CmbSourceLang.SelectedIndex;
        int tgtIdx = CmbTargetLang.SelectedIndex;

        if (srcIdx == 0)
        {
            CmbSourceLang.SelectedIndex = 2; // 中文
            CmbTargetLang.SelectedIndex = 1; // 英文
        }
        else
        {
            CmbSourceLang.SelectedIndex = tgtIdx + 1;
            CmbTargetLang.SelectedIndex = Math.Max(0, srcIdx - 1);
        }

        string currentSrc = TxtSource.Text;
        string currentTgt = TxtTarget.Text;
        if (!string.IsNullOrEmpty(currentTgt))
        {
            TxtSource.Text = currentTgt;
            TxtTarget.Text = "";
            OnTranslateClick(this, new RoutedEventArgs());
        }
    }

    private void OnSourceTextChanged(object sender, TextChangedEventArgs e)
    {
        string rawText = TxtSource.Text;
        bool hasSource = !string.IsNullOrWhiteSpace(rawText);

        BtnSpeakSource.Opacity = hasSource ? 1.0 : 0.4;
        BtnSpeakSource.IsEnabled = hasSource;
        BtnClearSource.Opacity = hasSource ? 1.0 : 0.4;
        BtnClearSource.IsEnabled = hasSource;

        // 动态展示自动检测到的语言
        if (CmbSourceLang.SelectedIndex == 0 && CmbSourceLang.Items.Count > 0 && CmbSourceLang.Items[0] is ComboBoxItem autoItem)
        {
            if (hasSource)
            {
                string detected = DetectLanguageName(rawText);
                autoItem.Content = $"自动检测 ({detected})";
            }
            else
            {
                autoItem.Content = "自动检测";
            }
        }

        if (!hasSource)
        {
            TxtTarget.Clear();
            TxtTargetPlaceholder.Text = "翻译结果将在这里呈现…";
            BtnSpeakTarget.Opacity = 0.4;
            BtnSpeakTarget.IsEnabled = false;
            _debounceTimer?.Stop();
            return;
        }

        // 500ms 防抖自动后台翻译
        _debounceTimer?.Stop();
        _debounceTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _debounceTimer.Tick += (s, args) =>
        {
            _debounceTimer.Stop();
            OnTranslateClick(this, new RoutedEventArgs());
        };
        _debounceTimer.Start();
    }

    private string DetectLanguageName(string text)
    {
        if (Regex.IsMatch(text, @"[\u3040-\u30FF]")) return "日语";
        if (Regex.IsMatch(text, @"[\uAC00-\uD7AF]")) return "韩语";
        if (Regex.IsMatch(text, @"[\u4E00-\u9FA5]")) return "中文";
        if (Regex.IsMatch(text, @"[\u0400-\u04FF]")) return "俄语";
        return "英语";
    }

    private async void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        string text = TxtSource.Text.Trim();
        if (string.IsNullOrEmpty(text))
            return;

        string targetLang = (CmbTargetLang.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "zh-Hans";
        string? sourceLang = (CmbSourceLang.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        if (string.IsNullOrEmpty(sourceLang))
            sourceLang = null;

        // 对齐 macOS：直接在译文窗口展示“正在思考与翻译…”，右上角展示转圈动画
        PrgTranslating.Visibility = Visibility.Visible;
        if (string.IsNullOrEmpty(TxtTarget.Text))
        {
            TxtTargetPlaceholder.Text = "正在思考与翻译…";
        }

        try
        {
            var res = await _translationService.TranslateAsync(text, targetLang, sourceLang, _config);
            TxtTarget.Text = res.Text;
            bool hasTarget = !string.IsNullOrEmpty(res.Text);
            BtnSpeakTarget.Opacity = hasTarget ? 1.0 : 0.4;
            BtnSpeakTarget.IsEnabled = hasTarget;
        }
        catch (Exception ex)
        {
            TxtTargetPlaceholder.Text = $"翻译失败: {ex.Message}";
        }
        finally
        {
            PrgTranslating.Visibility = Visibility.Collapsed;
        }
    }

    private void OnSpeakSourceClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(TxtSource.Text))
        {
            SpeechService.Speak(TxtSource.Text);
        }
    }

    private void OnSpeakTargetClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(TxtTarget.Text))
        {
            SpeechService.Speak(TxtTarget.Text);
        }
    }

    private void OnSpeakActiveClick(object sender, RoutedEventArgs e)
    {
        string textToSpeak = !string.IsNullOrWhiteSpace(TxtTarget.Text) ? TxtTarget.Text : TxtSource.Text;
        if (!string.IsNullOrWhiteSpace(textToSpeak))
        {
            SpeechService.Speak(textToSpeak);
        }
    }

    private void OnCopyTargetClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtTarget.Text))
        {
            Clipboard.SetText(TxtTarget.Text);
        }
    }

    private void OnClearClick(object sender, RoutedEventArgs e)
    {
        _debounceTimer?.Stop();
        SpeechService.Stop();
        PrgTranslating.Visibility = Visibility.Collapsed;
        TxtSource.Clear();
        TxtTarget.Clear();
        TxtTargetPlaceholder.Text = "翻译结果将在这里呈现…";
        if (CmbSourceLang.Items.Count > 0 && CmbSourceLang.Items[0] is ComboBoxItem autoItem)
        {
            autoItem.Content = "自动检测";
        }
        BtnSpeakSource.Opacity = 0.4;
        BtnSpeakSource.IsEnabled = false;
        BtnClearSource.Opacity = 0.4;
        BtnClearSource.IsEnabled = false;
        BtnSpeakTarget.Opacity = 0.4;
        BtnSpeakTarget.IsEnabled = false;
    }

    private void OnTogglePinClick(object sender, RoutedEventArgs e)
    {
        _isPinned = !_isPinned;
        Topmost = _isPinned;
        BtnPin.Appearance = _isPinned ? ControlAppearance.Primary : ControlAppearance.Secondary;
    }

    private void OnOpenSettingsClick(object sender, RoutedEventArgs e)
    {
        var settingsWin = new SettingsWindow(_configStore);
        settingsWin.Owner = this;
        if (settingsWin.ShowDialog() == true)
        {
            try
            {
                _config = _configStore.Load();
                SyncProviderSelection();
            }
            catch (ConfigurationStoreException error)
            {
                MessageBox.Show(
                    error.Message,
                    "Polyglance 设置",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
    }

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            _debounceTimer?.Stop();
            OnTranslateClick(this, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    public void SetAndTranslate(string text)
    {
        TxtSource.Text = text;
        Show();
        Activate();
        OnTranslateClick(this, new RoutedEventArgs());
    }
}
