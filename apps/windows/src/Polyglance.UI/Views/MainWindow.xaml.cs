using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.UI.Services;
using Wpf.Ui.Controls;

namespace Polyglance.UI.Views;

public sealed class ProviderCardItem : INotifyPropertyChanged
{
    private string _provider = "";
    private string _displayName = "";
    private string _text = "";
    private bool _isTranslating;
    private string? _errorMessage;
    private bool _isCollapsed;
    private ProviderDisplayMode _displayMode = ProviderDisplayMode.Normal;

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Provider
    {
        get => _provider;
        set
        {
            _provider = value;
            OnPropertyChanged(nameof(Provider));
            OnPropertyChanged(nameof(IconSource));
        }
    }

    public ImageSource? IconSource => MainWindow.GetProviderIconSource(_provider);

    public string DisplayName
    {
        get => _displayName;
        set { _displayName = value; OnPropertyChanged(nameof(DisplayName)); }
    }

    public ProviderDisplayMode DisplayMode
    {
        get => _displayMode;
        set { _displayMode = value; OnPropertyChanged(nameof(DisplayMode)); }
    }

    public string Text
    {
        get => _text;
        set
        {
            _text = value;
            OnPropertyChanged(nameof(Text));
            OnPropertyChanged(nameof(HasText));
            OnPropertyChanged(nameof(ActionOpacity));
            OnPropertyChanged(nameof(PlaceholderVisibility));
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(CollapsedPreviewText));
            OnPropertyChanged(nameof(CollapsedPreviewVisibility));
        }
    }

    public bool IsTranslating
    {
        get => _isTranslating;
        set
        {
            _isTranslating = value;
            OnPropertyChanged(nameof(IsTranslating));
            OnPropertyChanged(nameof(IsTranslatingVisibility));
            OnPropertyChanged(nameof(PlaceholderVisibility));
            OnPropertyChanged(nameof(StatusText));
        }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        set
        {
            _errorMessage = value;
            OnPropertyChanged(nameof(ErrorMessage));
            OnPropertyChanged(nameof(PlaceholderVisibility));
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(StatusTextColor));
        }
    }

    public bool IsCollapsed
    {
        get => _isCollapsed;
        set
        {
            _isCollapsed = value;
            OnPropertyChanged(nameof(IsCollapsed));
            OnPropertyChanged(nameof(ContentVisibility));
            OnPropertyChanged(nameof(CollapseIconText));
            OnPropertyChanged(nameof(CollapseToolTip));
            OnPropertyChanged(nameof(CollapsedPreviewVisibility));
        }
    }

    public bool HasText => !string.IsNullOrEmpty(Text);
    public double ActionOpacity => HasText ? 1.0 : 0.4;
    public Visibility IsTranslatingVisibility => IsTranslating ? Visibility.Visible : Visibility.Collapsed;
    public Visibility ContentVisibility => IsCollapsed ? Visibility.Collapsed : Visibility.Visible;
    public string CollapseIconText => IsCollapsed ? "⌄" : "⌃";
    public string CollapseToolTip => IsCollapsed ? "展开此卡片" : "折叠此卡片";

    public string CollapsedPreviewText => !string.IsNullOrEmpty(Text) ? Text.Replace("\r", " ").Replace("\n", " ").Trim() : "";
    public Visibility CollapsedPreviewVisibility => (IsCollapsed && !string.IsNullOrEmpty(Text)) ? Visibility.Visible : Visibility.Collapsed;

    public Visibility PlaceholderVisibility =>
        string.IsNullOrEmpty(Text) ? Visibility.Visible : Visibility.Collapsed;

    public string StatusText =>
        !string.IsNullOrEmpty(ErrorMessage) ? $"翻译失败: {ErrorMessage}"
        : IsTranslating ? "正在思考与翻译…"
        : "翻译结果将在这里呈现…";

    public System.Windows.Media.Brush StatusTextColor =>
        !string.IsNullOrEmpty(ErrorMessage)
            ? System.Windows.Media.Brushes.Crimson
            : System.Windows.Media.Brushes.Gray;

    private void OnPropertyChanged(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public partial class MainWindow : FluentWindow
{
    private readonly TranslationService _translationService;
    private readonly ConfigurationStore _configStore;
    private AppConfiguration _config;
    private bool _isPinned = false;
    private DispatcherTimer? _debounceTimer;
    private string? _lastTranslatedSource;
    private CancellationTokenSource? _translationCts;

    private readonly ObservableCollection<ProviderCardItem> _providerCards = new();
    private readonly List<string> _enabledProviders = new() { "freeai" };

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
            Loaded += (_, _) => System.Windows.MessageBox.Show(
                error.Message,
                "Polyglance 设置",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }

        if (_config.EnabledProviders != null && _config.EnabledProviders.Count > 0)
        {
            _enabledProviders.Clear();
            _enabledProviders.AddRange(_config.EnabledProviders);
        }
        else
        {
            _enabledProviders.Clear();
            _enabledProviders.Add("freeai");
        }

        ItemsProviderCards.ItemsSource = _providerCards;
        RefreshProviderCards();
        RefreshPinnedServices();

        SyncProviderSelection();
        KeyDown += OnWindowKeyDown;
    }

    public void ReloadConfiguration()
    {
        try
        {
            _config = _configStore.Load();
        }
        catch
        {
            _config = new AppConfiguration();
        }

        _enabledProviders.Clear();
        if (_config.EnabledProviders != null && _config.EnabledProviders.Count > 0)
        {
            _enabledProviders.AddRange(_config.EnabledProviders);
        }
        else
        {
            _enabledProviders.Add("freeai");
        }

        RefreshProviderCards();
        RefreshPinnedServices();
        SyncProviderSelection();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }

    protected override void OnDeactivated(EventArgs e)
    {
        base.OnDeactivated(e);
        if (!_isPinned && IsVisible)
        {
            Hide();
        }
    }

    private static readonly Dictionary<string, ImageSource> _providerIconCache = new(StringComparer.OrdinalIgnoreCase);

    public static ImageSource? GetProviderIconSource(string provider)
    {
        string norm = provider.ToLowerInvariant() switch
        {
            "freeai" or "free-ai" or "official-ai" or "polyglance-ai" => "free-ai",
            "microsoft" or "ms" => "microsoft",
            "google" => "google",
            "deepl" => "deepl",
            "baidu" => "baidu",
            "youdao" => "youdao",
            "volcano" or "volcengine" => "volcano",
            "openaicompatible" or "openai-compatible" or "openai" => "openai",
            var s when s.StartsWith("custom") => "openai",
            _ => provider.ToLowerInvariant()
        };

        if (_providerIconCache.TryGetValue(norm, out var cached))
            return cached;

        try
        {
            var uri = new Uri($"pack://application:,,,/Polyglance;component/Resources/ProviderIcons/{norm}.png", UriKind.Absolute);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.UriSource = uri;
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.EndInit();
            bitmap.Freeze();
            _providerIconCache[norm] = bitmap;
            return bitmap;
        }
        catch
        {
            try
            {
                string devPath = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Resources", "ProviderIcons", $"{norm}.png");
                if (System.IO.File.Exists(devPath))
                {
                    var bitmap = new BitmapImage(new Uri(devPath, UriKind.Absolute));
                    bitmap.Freeze();
                    _providerIconCache[norm] = bitmap;
                    return bitmap;
                }
            }
            catch { }
            return null;
        }
    }

    private string GetProviderDisplayName(string provider)
    {
        var custom = _config?.CustomAIConfigs?.Find(c => string.Equals(c.Id, provider, StringComparison.OrdinalIgnoreCase));
        if (custom != null && !string.IsNullOrWhiteSpace(custom.Name))
        {
            return custom.Name;
        }

        return provider.ToLowerInvariant() switch
        {
            "freeai" or "free-ai" => "官方 AI",
            "microsoft" => "Microsoft 翻译",
            "google" => "Google 翻译",
            "deepl" => "DeepL",
            "baidu" => "百度翻译",
            "youdao" => "有道翻译",
            "volcano" or "volcengine" => "火山翻译",
            "openaicompatible" or "openai-compatible" => "OpenAI 兼容",
            _ => provider
        };
    }

    private ProviderDisplayMode GetProviderDisplayMode(string provider)
    {
        if (_config.ProviderDisplayModes != null &&
            _config.ProviderDisplayModes.TryGetValue(provider, out string? raw))
        {
            return ProviderDisplayModeExtensions.FromConfigString(raw);
        }
        return ProviderDisplayMode.Normal;
    }

    private void RefreshProviderCards()
    {
        var existingMap = _providerCards.ToDictionary(c => c.Provider, StringComparer.OrdinalIgnoreCase);
        _providerCards.Clear();

        var baseProviders = _enabledProviders.Count > 0 ? _enabledProviders : new List<string> { "freeai" };
        var activeProviders = baseProviders
            .Where(p => GetProviderDisplayMode(p) != ProviderDisplayMode.Closed && GetProviderDisplayMode(p) != ProviderDisplayMode.PinToBar)
            .ToList();

        foreach (var p in activeProviders)
        {
            var mode = GetProviderDisplayMode(p);
            bool isInitiallyCollapsed = mode switch
            {
                ProviderDisplayMode.AlwaysFold => true,
                ProviderDisplayMode.RememberFold => existingMap.TryGetValue(p, out var ex) && ex.IsCollapsed,
                _ => false
            };

            if (existingMap.TryGetValue(p, out var existing))
            {
                existing.DisplayMode = mode;
                existing.IsCollapsed = isInitiallyCollapsed;
                _providerCards.Add(existing);
            }
            else
            {
                _providerCards.Add(new ProviderCardItem
                {
                    Provider = p,
                    DisplayName = GetProviderDisplayName(p),
                    Text = "",
                    IsTranslating = false,
                    DisplayMode = mode,
                    IsCollapsed = isInitiallyCollapsed
                });
            }
        }
    }

    private void RefreshPinnedServices()
    {
        StkPinnedServices.Children.Clear();
        var baseProviders = _enabledProviders.Count > 0 ? _enabledProviders : new List<string> { "freeai" };
        var pinnedProviders = baseProviders
            .Where(p => GetProviderDisplayMode(p) == ProviderDisplayMode.PinToBar)
            .ToList();

        foreach (var p in pinnedProviders)
        {
            var btn = new Wpf.Ui.Controls.Button
            {
                Appearance = ControlAppearance.Transparent,
                FontSize = 11,
                Padding = new Thickness(6, 3, 6, 3),
                Margin = new Thickness(0, 0, 4, 0),
                CornerRadius = new CornerRadius(4),
                ToolTip = $"钉住的服务：点击使用 {GetProviderDisplayName(p)} 翻译",
                Tag = p
            };
            var panel = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            var icon = GetProviderIconSource(p);
            if (icon != null)
            {
                panel.Children.Add(new Image
                {
                    Source = icon,
                    Width = 14,
                    Height = 14,
                    Margin = new Thickness(0, 0, 4, 0),
                    VerticalAlignment = VerticalAlignment.Center
                });
            }
            panel.Children.Add(new TextBlock
            {
                Text = GetProviderDisplayName(p).Replace(" 翻译", ""),
                FontSize = 11,
                VerticalAlignment = VerticalAlignment.Center
            });
            btn.Content = panel;
            btn.Click += async (s, e) =>
            {
                var card = _providerCards.FirstOrDefault(c => c.Provider.Equals(p, StringComparison.OrdinalIgnoreCase));
                if (card == null)
                {
                    card = new ProviderCardItem
                    {
                        Provider = p,
                        DisplayName = GetProviderDisplayName(p),
                        Text = "",
                        IsTranslating = false,
                        DisplayMode = ProviderDisplayMode.PinToBar,
                        IsCollapsed = false
                    };
                    _providerCards.Add(card);
                }
                else
                {
                    card.IsCollapsed = false;
                }

                if (!string.IsNullOrWhiteSpace(TxtSource.Text))
                {
                    await TranslateSingleCardAsync(card, TxtSource.Text.Trim());
                }
            };
            StkPinnedServices.Children.Add(btn);
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
            if (!_enabledProviders.Contains(provider, StringComparer.OrdinalIgnoreCase))
            {
                _enabledProviders.Insert(0, provider);
                RefreshProviderCards();
                RefreshPinnedServices();
            }
            _lastTranslatedSource = null;
            if (!string.IsNullOrWhiteSpace(TxtSource.Text))
            {
                OnTranslateClick(this, new RoutedEventArgs());
            }
        }
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        _lastTranslatedSource = null;
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

        var primaryCard = _providerCards.FirstOrDefault();
        string currentTgt = primaryCard?.Text ?? "";
        if (!string.IsNullOrEmpty(currentTgt))
        {
            TxtSource.Text = currentTgt;
            OnTranslateClick(this, new RoutedEventArgs());
        }
    }

    private void OnSourceTextChanged(object sender, TextChangedEventArgs e)
    {
        string rawText = TxtSource.Text;
        bool hasSource = !string.IsNullOrWhiteSpace(rawText);

        BtnSpeakSource.Opacity = hasSource ? 1.0 : 0.4;
        BtnSpeakSource.IsEnabled = hasSource;
        BtnCopySource.Opacity = hasSource ? 1.0 : 0.4;
        BtnCopySource.IsEnabled = hasSource;
        BtnClearSource.Opacity = hasSource ? 1.0 : 0.4;
        BtnClearSource.IsEnabled = hasSource;

        if (hasSource)
        {
            string detected = DetectLanguageName(rawText);
            TxtDetectedLang.Text = detected;
            BrdDetectedLang.Visibility = Visibility.Visible;
        }
        else
        {
            BrdDetectedLang.Visibility = Visibility.Collapsed;
        }

        if (CmbSourceLang.SelectedIndex == 0 && CmbSourceLang.Items.Count > 0 && CmbSourceLang.Items[0] is ComboBoxItem autoItem)
        {
            if (hasSource)
            {
                string detected = DetectLanguageName(rawText);
                autoItem.Content = $"自动检测 ({detected})";
                UpdateAutoTargetLanguage(rawText);
            }
            else
            {
                autoItem.Content = "自动检测";
            }
        }

        // 更新收藏按钮状态
        BtnFavorite.Appearance = TranslationHistoryStore.Shared.IsFavorite(rawText)
            ? ControlAppearance.Primary
            : ControlAppearance.Secondary;

        if (!hasSource)
        {
            _lastTranslatedSource = null;
            _translationCts?.Cancel();
            foreach (var card in _providerCards)
            {
                card.Text = "";
                card.IsTranslating = false;
                card.ErrorMessage = null;
            }
            TxtTarget.Clear();
            _debounceTimer?.Stop();
            return;
        }

        if (string.Equals(rawText.Trim(), _lastTranslatedSource, StringComparison.Ordinal))
        {
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

    private void UpdateAutoTargetLanguage(string text)
    {
        string targetLang = DetermineTargetLanguage(
            text,
            _config.TargetLanguage,
            _config.SecondTargetLanguage
        );

        foreach (ComboBoxItem item in CmbTargetLang.Items)
        {
            if (item.Tag?.ToString()?.Equals(targetLang, StringComparison.OrdinalIgnoreCase) == true)
            {
                if (!Equals(CmbTargetLang.SelectedItem, item))
                {
                    CmbTargetLang.SelectedItem = item;
                }
                break;
            }
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

    private async Task TranslateSingleCardAsync(ProviderCardItem card, string text, CancellationToken ct = default)
    {
        string targetLang = (CmbTargetLang.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "zh-Hans";
        string? sourceLang = (CmbSourceLang.SelectedItem as ComboBoxItem)?.Tag?.ToString();
        if (string.IsNullOrEmpty(sourceLang))
            sourceLang = null;

        card.IsTranslating = true;
        card.ErrorMessage = null;

        try
        {
            var res = await _translationService.TranslateAsync(
                text,
                targetLang,
                sourceLang,
                _config,
                providerOverride: card.Provider
            );
            if (ct.IsCancellationRequested) return;

            Dispatcher.Invoke(() =>
            {
                card.Text = res.Text;
                card.IsTranslating = false;
                if (card.Provider.Equals(_config.Provider, StringComparison.OrdinalIgnoreCase))
                {
                    TxtTarget.Text = res.Text;
                }
                TranslationHistoryStore.Shared.AddRecord(text, res.Text, sourceLang ?? "auto", targetLang, card.DisplayName);
            });
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested) return;
            Dispatcher.Invoke(() =>
            {
                card.ErrorMessage = ex.Message;
                card.IsTranslating = false;
            });
        }
        finally
        {
            Dispatcher.Invoke(() =>
            {
                card.IsTranslating = false;
            });
        }
    }

    private async void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        _debounceTimer?.Stop();
        string text = TxtSource.Text.Trim();
        if (string.IsNullOrEmpty(text))
            return;

        _lastTranslatedSource = text;
        _translationCts?.Cancel();
        _translationCts = new CancellationTokenSource();
        var ct = _translationCts.Token;

        var cardsToTranslate = new List<ProviderCardItem>();
        foreach (var card in _providerCards)
        {
            var mode = GetProviderDisplayMode(card.Provider);
            bool willTranslate;
            switch (mode)
            {
                case ProviderDisplayMode.AlwaysFold:
                    card.IsCollapsed = true;
                    willTranslate = false;
                    break;
                case ProviderDisplayMode.RememberFold:
                    willTranslate = !card.IsCollapsed;
                    break;
                case ProviderDisplayMode.Normal:
                default:
                    card.IsCollapsed = false;
                    willTranslate = true;
                    break;
            }

            if (willTranslate)
            {
                card.Text = "";
                card.IsTranslating = true;
                card.ErrorMessage = null;
                cardsToTranslate.Add(card);
            }
            else
            {
                card.Text = "";
                card.IsTranslating = false;
                card.ErrorMessage = null;
            }
        }

        var tasks = cardsToTranslate.Select(card => TranslateSingleCardAsync(card, text, ct));
        await Task.WhenAll(tasks);
    }

    private void OnSpeakSourceClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(TxtSource.Text))
        {
            SpeechService.Speak(TxtSource.Text);
        }
    }

    private void OnCopySourceClick(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(TxtSource.Text))
        {
            Clipboard.SetText(TxtSource.Text);
        }
    }

    private void OnSpeakCardClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ProviderCardItem card } && !string.IsNullOrWhiteSpace(card.Text))
        {
            SpeechService.Speak(card.Text);
        }
    }

    private void OnCopyCardClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ProviderCardItem card } && !string.IsNullOrEmpty(card.Text))
        {
            Clipboard.SetText(card.Text);
        }
    }

    private void OnReplaceCardClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ProviderCardItem card } && !string.IsNullOrEmpty(card.Text))
        {
            Hide();
            _ = TextReplacementService.ReplaceSelectedTextAsync(card.Text);
        }
    }

    private void OnToggleCardCollapseClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ProviderCardItem card })
        {
            card.IsCollapsed = !card.IsCollapsed;
            if (!card.IsCollapsed && string.IsNullOrEmpty(card.Text) && !card.IsTranslating && !string.IsNullOrWhiteSpace(TxtSource.Text))
            {
                _ = TranslateSingleCardAsync(card, TxtSource.Text.Trim());
            }
        }
    }

    private void OnCardOptionsClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: ProviderCardItem card } button)
            return;

        var menu = new ContextMenu();
        var currentMode = GetProviderDisplayMode(card.Provider);

        var modes = new[]
        {
            ProviderDisplayMode.Normal,
            ProviderDisplayMode.RememberFold,
            ProviderDisplayMode.AlwaysFold,
            ProviderDisplayMode.PinToBar,
            ProviderDisplayMode.Closed
        };

        foreach (var mode in modes)
        {
            var item = new MenuItem
            {
                Header = mode.GetTitle(),
                IsCheckable = true,
                IsChecked = currentMode == mode
            };

            item.Click += async (_, _) =>
            {
                _config.ProviderDisplayModes[card.Provider] = mode.ToConfigString();
                card.DisplayMode = mode;

                switch (mode)
                {
                    case ProviderDisplayMode.Closed:
                        _enabledProviders.RemoveAll(x => x.Equals(card.Provider, StringComparison.OrdinalIgnoreCase));
                        _config.EnabledProviders = _enabledProviders.ToList();
                        _providerCards.Remove(card);
                        break;

                    case ProviderDisplayMode.PinToBar:
                        if (!_enabledProviders.Contains(card.Provider, StringComparer.OrdinalIgnoreCase))
                            _enabledProviders.Add(card.Provider);
                        _config.EnabledProviders = _enabledProviders.ToList();
                        _providerCards.Remove(card);
                        break;

                    case ProviderDisplayMode.AlwaysFold:
                        if (!_enabledProviders.Contains(card.Provider, StringComparer.OrdinalIgnoreCase))
                            _enabledProviders.Add(card.Provider);
                        _config.EnabledProviders = _enabledProviders.ToList();
                        card.IsCollapsed = true;
                        break;

                    case ProviderDisplayMode.Normal:
                        if (!_enabledProviders.Contains(card.Provider, StringComparer.OrdinalIgnoreCase))
                            _enabledProviders.Add(card.Provider);
                        _config.EnabledProviders = _enabledProviders.ToList();
                        card.IsCollapsed = false;
                        if (string.IsNullOrEmpty(card.Text) && !string.IsNullOrWhiteSpace(TxtSource.Text))
                        {
                            await TranslateSingleCardAsync(card, TxtSource.Text.Trim());
                        }
                        break;

                    case ProviderDisplayMode.RememberFold:
                        if (!_enabledProviders.Contains(card.Provider, StringComparer.OrdinalIgnoreCase))
                            _enabledProviders.Add(card.Provider);
                        _config.EnabledProviders = _enabledProviders.ToList();
                        break;
                }

                try
                {
                    _configStore.Save(_config);
                }
                catch { }

                RefreshPinnedServices();
            };

            menu.Items.Add(item);
        }

        menu.PlacementTarget = button;
        menu.IsOpen = true;
    }

    private void OnClearClick(object sender, RoutedEventArgs e)
    {
        _debounceTimer?.Stop();
        SpeechService.Stop();
        TxtSource.Clear();
        foreach (var card in _providerCards)
        {
            card.Text = "";
            card.IsTranslating = false;
            card.ErrorMessage = null;
        }
        TxtTarget.Clear();
        if (CmbSourceLang.Items.Count > 0 && CmbSourceLang.Items[0] is ComboBoxItem autoItem)
        {
            autoItem.Content = "自动检测";
        }
        BrdDetectedLang.Visibility = Visibility.Collapsed;
        BtnSpeakSource.Opacity = 0.4;
        BtnSpeakSource.IsEnabled = false;
        BtnCopySource.Opacity = 0.4;
        BtnCopySource.IsEnabled = false;
        BtnClearSource.Opacity = 0.4;
        BtnClearSource.IsEnabled = false;
    }

    private void OnTogglePinClick(object sender, RoutedEventArgs e)
    {
        _isPinned = !_isPinned;
        Topmost = _isPinned;
        BtnPin.Appearance = _isPinned ? ControlAppearance.Primary : ControlAppearance.Secondary;
    }

    private void OnToggleFavoriteClick(object sender, RoutedEventArgs e)
    {
        string src = TxtSource.Text.Trim();
        if (string.IsNullOrEmpty(src)) return;

        var primaryCard = _providerCards.FirstOrDefault();
        string tgt = primaryCard?.Text ?? "";

        TranslationHistoryStore.Shared.ToggleFavoriteForCurrent(src, tgt);
        BtnFavorite.Appearance = TranslationHistoryStore.Shared.IsFavorite(src)
            ? ControlAppearance.Primary
            : ControlAppearance.Secondary;
    }

    private void OnOpenHistoryClick(object sender, RoutedEventArgs e)
    {
        var win = new HistoryWindow
        {
            Owner = this,
            OnSelectText = (txt) =>
            {
                TxtSource.Text = txt;
                OnTranslateClick(this, new RoutedEventArgs());
            }
        };
        win.Show();
    }

    private void OnScreenshotTranslateClick(object sender, RoutedEventArgs e)
    {
        Hide();
        App.CurrentApp?.TriggerScreenTranslate();
    }

    private void OnClipboardTranslateClick(object sender, RoutedEventArgs e)
    {
        try
        {
            if (Clipboard.ContainsText())
            {
                string text = Clipboard.GetText();
                if (!string.IsNullOrWhiteSpace(text))
                {
                    TxtSource.Text = text.Trim();
                    OnTranslateClick(this, new RoutedEventArgs());
                }
            }
        }
        catch
        {
        }
    }

    private void OnToggleFoldInputClick(object sender, RoutedEventArgs e)
    {
        bool isVisible = BrdSourceCard.Visibility == Visibility.Visible;
        BrdSourceCard.Visibility = isVisible ? Visibility.Collapsed : Visibility.Visible;
        BtnFoldInput.Appearance = isVisible ? ControlAppearance.Primary : ControlAppearance.Secondary;
    }

    private void OnAdjustServicesClick(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        var allProviders = _config.ProviderOrder != null && _config.ProviderOrder.Count > 0
            ? _config.ProviderOrder
            : new List<string> { "freeai", "microsoft", "google", "deepl", "baidu", "youdao", "volcano", "openaicompatible" };

        foreach (var p in allProviders)
        {
            var icon = GetProviderIconSource(p);
            var item = new MenuItem
            {
                Header = GetProviderDisplayName(p),
                IsCheckable = true,
                IsChecked = _enabledProviders.Contains(p, StringComparer.OrdinalIgnoreCase)
                    || (_enabledProviders.Count == 0 && p.Equals("freeai", StringComparison.OrdinalIgnoreCase)),
                Icon = icon != null ? new Image { Source = icon, Width = 16, Height = 16 } : null
            };
            item.Click += async (_, _) =>
            {
                bool wasChecked = _enabledProviders.Contains(p, StringComparer.OrdinalIgnoreCase);
                if (item.IsChecked)
                {
                    if (!wasChecked)
                        _enabledProviders.Add(p);
                    _config.ProviderDisplayModes[p] = ProviderDisplayMode.Normal.ToConfigString();
                }
                else
                {
                    _enabledProviders.RemoveAll(x => x.Equals(p, StringComparison.OrdinalIgnoreCase));
                    _config.ProviderDisplayModes[p] = ProviderDisplayMode.Closed.ToConfigString();
                }

                _config.EnabledProviders = _enabledProviders.ToList();
                try
                {
                    _configStore.Save(_config);
                }
                catch { }

                RefreshProviderCards();
                RefreshPinnedServices();

                string currentText = TxtSource.Text.Trim();
                if (!string.IsNullOrWhiteSpace(currentText) && item.IsChecked)
                {
                    var newCard = _providerCards.FirstOrDefault(c => c.Provider.Equals(p, StringComparison.OrdinalIgnoreCase));
                    if (newCard != null && string.IsNullOrEmpty(newCard.Text) && !newCard.IsTranslating)
                    {
                        var mode = GetProviderDisplayMode(newCard.Provider);
                        if (mode != ProviderDisplayMode.AlwaysFold && mode != ProviderDisplayMode.Closed && mode != ProviderDisplayMode.PinToBar)
                        {
                            newCard.IsCollapsed = false;
                            newCard.IsTranslating = true;
                            newCard.ErrorMessage = null;
                            await TranslateSingleCardAsync(newCard, currentText, _translationCts?.Token ?? CancellationToken.None);
                        }
                    }
                }
            };
            menu.Items.Add(item);
        }
        menu.PlacementTarget = BtnServices;
        menu.IsOpen = true;
    }

    private void OnDetectedLangClick(object sender, MouseButtonEventArgs e)
    {
        var menu = new ContextMenu();
        var langs = new (string Name, int Index)[]
        {
            ("自动检测", 0),
            ("英语 (EN)", 1),
            ("中文 (ZH)", 2),
            ("日语 (JA)", 3),
            ("韩语 (KO)", 4),
            ("法语 (FR)", 5),
            ("德语 (DE)", 6),
            ("西班牙语", 7),
            ("俄语 (RU)", 8)
        };

        foreach (var (name, idx) in langs)
        {
            var item = new MenuItem { Header = name };
            item.Click += (_, _) =>
            {
                CmbSourceLang.SelectedIndex = idx;
            };
            menu.Items.Add(item);
        }

        menu.PlacementTarget = BrdDetectedLang;
        menu.IsOpen = true;
    }

    private void OnOpenSettingsClick(object sender, RoutedEventArgs e)
    {
        var settingsWin = new SettingsWindow(_configStore);
        settingsWin.Owner = this;
        if (settingsWin.ShowDialog() == true)
        {
            ReloadConfiguration();
        }
    }

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && !Topmost)
        {
            Hide();
            e.Handled = true;
            return;
        }

        if (e.Key == Key.S && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            OnToggleFavoriteClick(this, new RoutedEventArgs());
            e.Handled = true;
            return;
        }

        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            _debounceTimer?.Stop();
            OnTranslateClick(this, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    public void BeginOcrLoading(Rect? nearRect = null)
    {
        ReloadConfiguration();
        _debounceTimer?.Stop();
        TxtSource.Text = "正在识别屏幕文字…";
        _lastTranslatedSource = null;
        if (nearRect.HasValue && (!IsVisible || WindowState == WindowState.Minimized))
        {
            PositionNear(nearRect.Value);
        }
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
    }

    public void SetAndTranslate(string text, Rect? nearRect = null)
    {
        ReloadConfiguration();
        _debounceTimer?.Stop();
        TxtSource.Text = text;
        _debounceTimer?.Stop();
        if (CmbSourceLang.SelectedIndex <= 0)
        {
            UpdateAutoTargetLanguage(text);
        }
        if (nearRect.HasValue && (!IsVisible || WindowState == WindowState.Minimized))
        {
            PositionNear(nearRect.Value);
        }
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
        OnTranslateClick(this, new RoutedEventArgs());
    }

    private void PositionNear(Rect targetRect)
    {
        var screen = System.Windows.Forms.Screen.FromPoint(
            new System.Drawing.Point((int)targetRect.X, (int)targetRect.Y));
        var workArea = screen.WorkingArea;

        double w = ActualWidth > 0 ? ActualWidth : Width;
        double h = ActualHeight > 0 ? ActualHeight : Height;
        if (double.IsNaN(w) || w <= 0) w = 460;
        if (double.IsNaN(h) || h <= 0) h = 540;

        if (targetRect.Width <= 2 && targetRect.Height <= 2)
        {
            double mouseX = targetRect.Left - 30;
            double mouseY = targetRect.Top + 16;
            if (mouseY + h > workArea.Bottom)
            {
                mouseY = targetRect.Top - h - 16;
            }
            Left = Math.Clamp(mouseX, workArea.Left + 8, Math.Max(workArea.Left + 8, workArea.Right - w - 8));
            Top = Math.Clamp(mouseY, workArea.Top + 8, Math.Max(workArea.Top + 8, workArea.Bottom - h - 8));
            return;
        }

        double x = targetRect.Right + 16;
        double y = targetRect.Top;

        if (x + w > workArea.Right)
        {
            x = targetRect.Left - w - 16;
        }

        if (x < workArea.Left)
        {
            x = targetRect.Left + (targetRect.Width - w) / 2;
            y = targetRect.Bottom + 16;
            if (y + h > workArea.Bottom)
            {
                y = targetRect.Top - h - 16;
            }
        }

        x = Math.Clamp(x, workArea.Left + 8, Math.Max(workArea.Left + 8, workArea.Right - w - 8));
        y = Math.Clamp(y, workArea.Top + 8, Math.Max(workArea.Top + 8, workArea.Bottom - h - 8));

        Left = x;
        Top = y;
    }
}
