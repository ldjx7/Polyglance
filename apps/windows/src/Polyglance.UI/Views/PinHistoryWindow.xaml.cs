using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Pin;

namespace Polyglance.UI.Views;

public sealed class PinHistoryDisplayItem : INotifyPropertyChanged
{
    public required PinArchiveItem Item { get; init; }
    public string Id => Item.Id;
    public string SourceName => Item.Source.GetDisplayName();
    public string Resolution => $"{Item.PixelWidth} × {Item.PixelHeight}";
    public string DateString => Item.CreatedAt.ToLocalTime().ToString("yyyy/MM/dd HH:mm");

    private BitmapSource? _thumbnail;
    public BitmapSource? Thumbnail
    {
        get => _thumbnail;
        set
        {
            if (!ReferenceEquals(_thumbnail, value))
            {
                _thumbnail = value;
                OnPropertyChanged();
            }
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public partial class PinHistoryWindow : Window
{
    private const long MaxThumbnailCacheBytes = 32 * 1024 * 1024; // 32 MiB
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private readonly PinArchiveStore _store;
    private bool _isExplicitClose;

    private CancellationTokenSource? _loadCts;
    private int _currentGeneration;
    private readonly SemaphoreSlim _loadSemaphore = new(2, 2);
    private readonly Dictionary<string, long> _thumbnailSizes = new();

    public PinHistoryWindow(
        TranslationService? translationService = null,
        AppConfiguration? configuration = null,
        PinArchiveStore? store = null)
    {
        InitializeComponent();
        _translationService = translationService;
        _configuration = configuration;
        _store = store ?? PinHistoryManager.DefaultStore;

        Loaded += async (_, _) => await RefreshItems();
        IsVisibleChanged += OnIsVisibleChanged;
    }

    private void OnIsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (!IsVisible)
        {
            CancelLoadingAndClearCache();
        }
    }

    private void CancelLoadingAndClearCache()
    {
        _loadCts?.Cancel();
        _loadCts?.Dispose();
        _loadCts = null;

        if (LstHistory.ItemsSource is IEnumerable<PinHistoryDisplayItem> items)
        {
            foreach (var item in items)
            {
                item.Thumbnail = null;
            }
        }
        _thumbnailSizes.Clear();
    }

    public async Task RefreshItems()
    {
        _loadCts?.Cancel();
        _loadCts?.Dispose();
        _loadCts = new CancellationTokenSource();
        int generation = ++_currentGeneration;
        var token = _loadCts.Token;

        var items = await _store.Schedule(store => store.List());
        if (token.IsCancellationRequested || generation != _currentGeneration) return;
        TxtCount.Text = $"({items.Count})";

        if (items.Count == 0)
        {
            EmptyPanel.Visibility = Visibility.Visible;
            LstHistory.Visibility = Visibility.Collapsed;
            LstHistory.ItemsSource = null;
            UpdateButtonStates();
            return;
        }

        EmptyPanel.Visibility = Visibility.Collapsed;
        LstHistory.Visibility = Visibility.Visible;

        string? previousSelectedId = (LstHistory.SelectedItem as PinHistoryDisplayItem)?.Id;

        var displayItems = new List<PinHistoryDisplayItem>(items.Count);
        foreach (var item in items)
        {
            displayItems.Add(new PinHistoryDisplayItem
            {
                Item = item,
                Thumbnail = null
            });
        }

        LstHistory.ItemsSource = displayItems;

        var toSelect = displayItems.FirstOrDefault(i => i.Id == previousSelectedId) ?? displayItems.FirstOrDefault();
        LstHistory.SelectedItem = toSelect;

        UpdateButtonStates();

        // Asynchronously load thumbnails in background with concurrency limit and memory budget
        _ = LoadThumbnailsAsync(displayItems, generation, token);
    }

    private async Task LoadThumbnailsAsync(
        List<PinHistoryDisplayItem> displayItems,
        int generation,
        CancellationToken token)
    {
        long currentTotalBytes = 0;

        foreach (var item in displayItems)
        {
            if (token.IsCancellationRequested || generation != _currentGeneration)
                break;

            if (token.IsCancellationRequested) break;
            try { await _loadSemaphore.WaitAsync(token); }
            catch (OperationCanceledException) { break; }
            try
            {
                if (token.IsCancellationRequested || generation != _currentGeneration)
                    break;

                string id = item.Id;
                var thumb = await _store.Schedule(store => store.LoadThumbnail(id, maxPixelDimension: 480));

                if (thumb != null && !token.IsCancellationRequested && generation == _currentGeneration)
                {
                    long itemBytes = (long)thumb.PixelWidth * thumb.PixelHeight * 4;
                    currentTotalBytes += itemBytes;

                    // Dispatch thumbnail assignment to UI thread
                    Dispatcher.Invoke(() =>
                    {
                        if (generation == _currentGeneration)
                        {
                            item.Thumbnail = thumb;
                            _thumbnailSizes[id] = itemBytes;
                        }
                    });

                    // Evict from beginning of cache if budget exceeded
                    if (currentTotalBytes > MaxThumbnailCacheBytes)
                    {
                        Dispatcher.Invoke(() =>
                        {
                            foreach (var oldItem in displayItems)
                            {
                                if (currentTotalBytes <= MaxThumbnailCacheBytes)
                                    break;

                                if (oldItem != item && oldItem.Thumbnail != null && _thumbnailSizes.TryGetValue(oldItem.Id, out long sz))
                                {
                                    oldItem.Thumbnail = null;
                                    _thumbnailSizes.Remove(oldItem.Id);
                                    currentTotalBytes -= sz;
                                }
                            }
                        });
                    }
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch { }
            finally
            {
                _loadSemaphore.Release();
            }
        }
    }

    private void UpdateButtonStates()
    {
        bool hasSelection = LstHistory.SelectedItem != null;
        int count = (LstHistory.ItemsSource as IReadOnlyCollection<PinHistoryDisplayItem>)?.Count ?? 0;

        BtnPin.IsEnabled = hasSelection;
        BtnDelete.IsEnabled = hasSelection;
        // An empty visible list can still have quarantined images that the user wants to erase.
        BtnClearAll.IsEnabled = true;
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        UpdateButtonStates();
    }

    private async void OnItemDoubleClicked(object sender, MouseButtonEventArgs e)
    {
        if (LstHistory.SelectedItem is PinHistoryDisplayItem selected)
        {
            await PinItem(selected.Item);
        }
    }

    private async void OnPinClick(object sender, RoutedEventArgs e)
    {
        if (LstHistory.SelectedItem is PinHistoryDisplayItem selected)
        {
            await PinItem(selected.Item);
        }
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (LstHistory.SelectedItem is PinHistoryDisplayItem selected)
        {
            var result = await _store.Schedule(store => store.Delete(selected.Id));
            if (!result.IsSuccess)
            {
                MessageBox.Show(result.ErrorMessage ?? "删除历史记录失败。", "贴图历史", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            await RefreshItems();
        }
    }

    private async void OnClearAllClick(object sender, RoutedEventArgs e)
    {
        var confirm = MessageBox.Show(
            "确定要清空全部贴图历史吗？此操作将删除本地历史图片、文本原文和恢复记录，无法撤销。已打开的窗口可继续显示，但关闭后不能恢复。",
            "清空全部",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning);

        if (confirm == MessageBoxResult.Yes)
        {
            var result = await _store.Schedule(store => store.DeleteAll());
            if (!result.IsSuccess)
            {
                MessageBox.Show(result.ErrorMessage ?? "清空历史记录时出现错误。", "贴图历史", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            await RefreshItems();
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Hide();
            e.Handled = true;
        }
        else if (e.Key == Key.Delete)
        {
            OnDeleteClick(sender, e);
            e.Handled = true;
        }
        else if (e.Key == Key.Enter)
        {
            OnPinClick(sender, e);
            e.Handled = true;
        }
    }

    public async Task PinItem(PinArchiveItem item)
    {
        var bitmap = await _store.Schedule(store => store.LoadImage(item.Id));
        if (bitmap == null)
        {
            MessageBox.Show("未能读取贴图图片文件。", "贴图历史", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        await PinSessionController.For(_store).OpenHistory(bitmap, item.Id, _translationService, _configuration);
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        CancelLoadingAndClearCache();

        if (!_isExplicitClose)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnClosing(e);
    }

    public void ExplicitClose()
    {
        _isExplicitClose = true;
        Close();
    }
}
