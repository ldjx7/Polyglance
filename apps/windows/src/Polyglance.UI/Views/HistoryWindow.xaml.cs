using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Polyglance.Core.Services;
using Wpf.Ui.Controls;

namespace Polyglance.UI.Views;

public partial class HistoryWindow : FluentWindow
{
    private readonly TranslationHistoryStore _historyStore = TranslationHistoryStore.Shared;
    public Action<string>? OnSelectText { get; set; }

    public HistoryWindow()
    {
        InitializeComponent();
        RefreshList();
    }

    private void RefreshList()
    {
        bool showFavoritesOnly = RbFavorites?.IsChecked == true;
        var records = showFavoritesOnly ? _historyStore.GetFavorites() : _historyStore.GetRecords();

        string query = (TxtSearch?.Text ?? "").Trim().ToLowerInvariant();
        if (!string.IsNullOrEmpty(query))
        {
            records = records.Where(r =>
                r.SourceText.ToLowerInvariant().Contains(query) ||
                r.TargetText.ToLowerInvariant().Contains(query)
            ).ToList();
        }

        if (ItemsHistory != null)
        {
            ItemsHistory.ItemsSource = records;
        }

        if (TxtCount != null)
        {
            TxtCount.Text = $"共 {records.Count} 条记录";
        }
    }

    private void OnTabSelectionChanged(object sender, RoutedEventArgs e)
    {
        RefreshList();
    }

    private void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        RefreshList();
    }

    private void OnApplyRecordClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: TranslationRecord record })
        {
            OnSelectText?.Invoke(record.SourceText);
            Close();
        }
    }

    private void OnCopyRecordClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: TranslationRecord record })
        {
            try
            {
                Clipboard.SetText(record.TargetText);
            }
            catch
            {
            }
        }
    }

    private void OnToggleFavoriteClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: TranslationRecord record })
        {
            _historyStore.ToggleFavorite(record.Id);
            RefreshList();
        }
    }

    private void OnDeleteRecordClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: TranslationRecord record })
        {
            _historyStore.DeleteRecord(record.Id);
            RefreshList();
        }
    }

    private void OnClearAllClick(object sender, RoutedEventArgs e)
    {
        _historyStore.ClearAll();
        RefreshList();
    }
}
