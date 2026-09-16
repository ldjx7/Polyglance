using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;

namespace Polyglance.Platform.Translation;

public sealed class OfflineModelInfo : INotifyPropertyChanged
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public string Description { get; init; } = "";
    public string SourceLanguage { get; init; } = "";
    public string TargetLanguage { get; init; } = "";
    public long SizeBytes { get; init; }
    public string DownloadUrl { get; init; } = "";
    public List<string> DownloadUrls { get; init; } = [];

    private bool _isInstalled;
    public bool IsInstalled
    {
        get => _isInstalled;
        set
        {
            if (SetField(ref _isInstalled, value))
            {
                OnPropertyChanged(nameof(InstalledVisibility));
                OnPropertyChanged(nameof(NotInstalledVisibility));
            }
        }
    }

    private bool _isDownloading;
    public bool IsDownloading
    {
        get => _isDownloading;
        set
        {
            if (SetField(ref _isDownloading, value))
            {
                OnPropertyChanged(nameof(DownloadingVisibility));
                OnPropertyChanged(nameof(NotInstalledVisibility));
                OnPropertyChanged(nameof(InstalledVisibility));
            }
        }
    }

    private double _downloadProgress;
    public double DownloadProgress
    {
        get => _downloadProgress;
        set => SetField(ref _downloadProgress, value);
    }

    private string _statusText = "未安装";
    public string StatusText
    {
        get => _statusText;
        set => SetField(ref _statusText, value);
    }

    public string SizeFormatted => $"{SizeBytes / (1024.0 * 1024.0):F1} MB";

    public Visibility InstalledVisibility => _isInstalled && !_isDownloading ? Visibility.Visible : Visibility.Collapsed;
    public Visibility NotInstalledVisibility => !_isInstalled && !_isDownloading ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DownloadingVisibility => _isDownloading ? Visibility.Visible : Visibility.Collapsed;

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (!Equals(field, value))
        {
            field = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
            return true;
        }
        return false;
    }

    private void OnPropertyChanged(string propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
