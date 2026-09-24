using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Polyglance.Core.Services;

namespace Polyglance.UI.Views;

public partial class ScreenRecordingReviewWindow : Window
{
    private readonly string _filePath;
    private readonly List<BitmapSource> _frames;
    private readonly int _fps;
    private readonly Rect _originalScreenBounds;
    private readonly Rect _originalRecordingRect;
    private readonly DispatcherTimer _playbackTimer;
    private readonly PlaybackProgressClock _progressClock = new();
    private readonly System.Diagnostics.Stopwatch _playbackStopwatch = new();
    private readonly bool _isMp4;
    private int _currentFrameIndex = 0;
    private double _pausedTimeSeconds = 0;
    private double _totalDurationSeconds = 0;
    private bool _isPlaying = true;
    private bool _isUserSeeking = false;

    public ScreenRecordingReviewWindow(
        string filePath,
        List<BitmapSource> frames,
        int fps,
        Rect originalScreenBounds,
        Rect originalRecordingRect)
        : this(
            filePath,
            frames,
            fps,
            (frames != null && frames.Count > 0) ? frames.Count / (double)Math.Max(1, fps) : 0,
            originalScreenBounds,
            originalRecordingRect)
    {
    }

    public ScreenRecordingReviewWindow(
        string filePath,
        List<BitmapSource> frames,
        int fps,
        double totalDurationSeconds,
        Rect originalScreenBounds,
        Rect originalRecordingRect)
    {
        InitializeComponent();
        _filePath = filePath;
        _frames = frames ?? new List<BitmapSource>();
        _fps = Math.Max(1, fps);
        _totalDurationSeconds = totalDurationSeconds > 0 ? totalDurationSeconds : _frames.Count / (double)_fps;
        _originalScreenBounds = originalScreenBounds;
        _originalRecordingRect = originalRecordingRect;

        _isMp4 = string.Equals(Path.GetExtension(_filePath), ".mp4", StringComparison.OrdinalIgnoreCase) && File.Exists(_filePath);

        if (_isMp4)
        {
            PlayerMedia.Visibility = Visibility.Visible;
            PlayerImage.Visibility = Visibility.Collapsed;
            PlayerMedia.MediaFailed += OnMediaFailed;
            PlayerMedia.Source = new Uri(Path.GetFullPath(_filePath));
            PlayerMedia.Play();
            _isPlaying = true;
            BtnPlayPause.Content = "暂停";
            TxtTitle.Text = "录屏预览";
        }
        else
        {
            PlayerMedia.Visibility = Visibility.Collapsed;
            PlayerImage.Visibility = Visibility.Visible;
            if (_frames.Count > 0)
            {
                PlayerImage.Source = _frames[0];
            }
            TxtTitle.Text = $"录屏预览 ({_frames.Count} 帧 · {_fps} FPS · {_totalDurationSeconds:F1}s)";
            ProgressSlider.Maximum = Math.Max(0, _frames.Count - 1);
            ProgressSlider.Value = 0;
            UpdateTimeDisplay(0, _totalDurationSeconds);

            if (_frames.Count > 1)
            {
                _playbackStopwatch.Start();
                _isPlaying = true;
                BtnPlayPause.Content = "暂停";
            }
            else
            {
                _isPlaying = false;
                BtnPlayPause.Content = "播放";
                BtnPlayPause.IsEnabled = false;
                ProgressSlider.IsEnabled = false;
            }
        }

        _playbackTimer = new DispatcherTimer(DispatcherPriority.Normal)
        {
            Interval = TimeSpan.FromMilliseconds(_isMp4 ? 100 : 1000.0 / _fps)
        };
        _playbackTimer.Tick += OnPlaybackTimerTick;
        _playbackTimer.Start();
    }

    private void OnMediaOpened(object sender, RoutedEventArgs e)
    {
        if (PlayerMedia.NaturalDuration.HasTimeSpan)
        {
            double totalSec = PlayerMedia.NaturalDuration.TimeSpan.TotalSeconds;
            _totalDurationSeconds = totalSec;
            ProgressSlider.Maximum = totalSec;
            TxtTitle.Text = $"录屏预览 ({totalSec:F1}s)";
            UpdateTimeDisplay(0, totalSec);
            if (_isPlaying)
            {
                _progressClock.Play(PlayerMedia.Position.TotalSeconds);
                StartProgressAnimation(_progressClock.Position);
            }
        }
    }

    private void OnMediaEnded(object sender, RoutedEventArgs e)
    {
        _isPlaying = false;
        _progressClock.Pause();
        StopProgressAnimation();
        BtnPlayPause.Content = "播放";
        if (PlayerMedia.NaturalDuration.HasTimeSpan)
        {
            double totalSec = PlayerMedia.NaturalDuration.TimeSpan.TotalSeconds;
            PlayerMedia.Position = TimeSpan.FromSeconds(totalSec);
            _progressClock.Seek(totalSec);
            ProgressSlider.Value = totalSec;
            UpdateTimeDisplay(totalSec, totalSec);
        }
    }

    private void OnMediaFailed(object? sender, ExceptionRoutedEventArgs e)
    {
        PlayerMedia.Visibility = Visibility.Collapsed;
        PlayerImage.Visibility = Visibility.Visible;
        if (_frames.Count > 0)
        {
            PlayerImage.Source = _frames[0];
        }
        _isPlaying = false;
        _progressClock.Pause();
        StopProgressAnimation();
        BtnPlayPause.Content = "播放";
        BtnPlayPause.IsEnabled = false;
        ProgressSlider.IsEnabled = false;
        TxtTitle.Text = "预览播放失败，可保存后使用系统播放器打开";

    }

    private void OnPlaybackTimerTick(object? sender, EventArgs e)
    {
        if (_isMp4 && PlayerMedia.Visibility == Visibility.Visible)
        {
            if (_isUserSeeking) return;
            if (PlayerMedia.NaturalDuration.HasTimeSpan)
            {
                double total = PlayerMedia.NaturalDuration.TimeSpan.TotalSeconds;
                _progressClock.Observe(PlayerMedia.Position.TotalSeconds);
                double cur = Math.Clamp(_progressClock.Position, 0, total);
                UpdateTimeDisplay(cur, total);
            }
            return;
        }

        if (_frames.Count == 0) return;

        double currentSeconds = _pausedTimeSeconds + _playbackStopwatch.Elapsed.TotalSeconds;
        if (currentSeconds >= _totalDurationSeconds)
        {
            // 播放完一遍立即停止，停在最后一帧，不自动循环
            _playbackStopwatch.Stop();
            _playbackTimer.Stop();
            _isPlaying = false;
            BtnPlayPause.Content = "播放";

            _pausedTimeSeconds = _totalDurationSeconds;
            _currentFrameIndex = Math.Max(0, _frames.Count - 1);
            PlayerImage.Source = _frames[_currentFrameIndex];
            if (!_isUserSeeking)
            {
                ProgressSlider.Value = _currentFrameIndex;
            }
            UpdateTimeDisplay(_totalDurationSeconds, _totalDurationSeconds);
            return;
        }

        int targetFrame = _totalDurationSeconds > 0
            ? (int)Math.Clamp(Math.Round((currentSeconds / _totalDurationSeconds) * (_frames.Count - 1)), 0, _frames.Count - 1)
            : 0;

        if (targetFrame != _currentFrameIndex)
        {
            _currentFrameIndex = targetFrame;
            PlayerImage.Source = _frames[_currentFrameIndex];
        }
        if (!_isUserSeeking)
        {
            ProgressSlider.Value = _currentFrameIndex;
        }
        UpdateTimeDisplay(currentSeconds, _totalDurationSeconds);
    }

    private void UpdateTimeDisplay(double currentSec, double totalSec)
    {
        int cur = (int)Math.Max(0, currentSec);
        int tot = (int)Math.Max(0, totalSec);
        string text = $"{cur / 60:D2}:{cur % 60:D2} / {tot / 60:D2}:{tot % 60:D2}";
        if (TxtTimeProgress.Text != text) TxtTimeProgress.Text = text;
    }

    private void StartProgressAnimation(double currentSeconds)
    {
        if (!_isMp4 || !PlayerMedia.NaturalDuration.HasTimeSpan) return;

        double total = PlayerMedia.NaturalDuration.TimeSpan.TotalSeconds;
        double current = Math.Clamp(currentSeconds, 0, total);
        ProgressSlider.BeginAnimation(RangeBase.ValueProperty, null);
        ProgressSlider.Value = current;
        if (!_isPlaying || current >= total) return;

        // WPF advances this animation on its rendering clock. The UI timer
        // only refreshes the text, so a delayed tick cannot jump the thumb.
        var animation = new DoubleAnimation(current, total, TimeSpan.FromSeconds(total - current))
        {
            FillBehavior = FillBehavior.HoldEnd
        };
        ProgressSlider.BeginAnimation(RangeBase.ValueProperty, animation);
    }

    private void StopProgressAnimation()
    {
        if (!_isMp4) return;
        double current = ProgressSlider.Value;
        ProgressSlider.BeginAnimation(RangeBase.ValueProperty, null);
        ProgressSlider.Value = current;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Space)
        {
            TogglePlayPause();
            e.Handled = true;
        }
    }

    private void OnTitleBarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void OnPlayPauseClick(object sender, RoutedEventArgs e) => TogglePlayPause();

    private void TogglePlayPause()
    {
        if (_isMp4)
        {
            if (_isPlaying)
            {
                PlayerMedia.Pause();
                _progressClock.Pause();
                StopProgressAnimation();
                _isPlaying = false;
                BtnPlayPause.Content = "播放";
            }
            else
            {
                if (PlayerMedia.NaturalDuration.HasTimeSpan &&
                    PlayerMedia.Position >= PlayerMedia.NaturalDuration.TimeSpan - TimeSpan.FromMilliseconds(200))
                {
                    PlayerMedia.Position = TimeSpan.Zero;
                }
                PlayerMedia.Play();
                _progressClock.Play(PlayerMedia.Position.TotalSeconds);
                _isPlaying = true;
                StartProgressAnimation(_progressClock.Position);
                BtnPlayPause.Content = "暂停";
            }
            return;
        }

        if (_frames.Count <= 1) return;

        if (_isPlaying)
        {
            _pausedTimeSeconds += _playbackStopwatch.Elapsed.TotalSeconds;
            _playbackStopwatch.Stop();
            _isPlaying = false;
            BtnPlayPause.Content = "播放";
        }
        else
        {
            // 如果已经在末尾，重置回开头重新播放一遍
            if (_pausedTimeSeconds >= _totalDurationSeconds - 0.05)
            {
                _pausedTimeSeconds = 0;
                _currentFrameIndex = 0;
                PlayerImage.Source = _frames[0];
                ProgressSlider.Value = 0;
            }
            _playbackStopwatch.Restart();
            _playbackTimer.Start();
            _isPlaying = true;
            BtnPlayPause.Content = "暂停";
        }
    }

    private void OnProgressSliderMouseDown(object sender, MouseButtonEventArgs e)
    {
        StopProgressAnimation();
        _isUserSeeking = true;
    }

    private void OnProgressSliderMouseUp(object sender, MouseButtonEventArgs e)
    {
        _isUserSeeking = false;
        ApplySeekFromSlider();
        if (_isMp4 && _isPlaying) StartProgressAnimation(_progressClock.Position);
    }

    private void OnProgressSliderValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_isUserSeeking)
        {
            ApplySeekFromSlider();
        }
    }

    private void ApplySeekFromSlider()
    {
        if (_isMp4)
        {
            double targetSeconds = Math.Clamp(ProgressSlider.Value, 0, ProgressSlider.Maximum);
            PlayerMedia.Position = TimeSpan.FromSeconds(targetSeconds);
            _progressClock.Seek(targetSeconds);
            UpdateTimeDisplay(targetSeconds, ProgressSlider.Maximum);
            return;
        }

        if (_frames.Count == 0) return;
        int targetFrame = (int)Math.Clamp(Math.Round(ProgressSlider.Value), 0, _frames.Count - 1);
        _currentFrameIndex = targetFrame;
        PlayerImage.Source = _frames[_currentFrameIndex];
        _pausedTimeSeconds = _totalDurationSeconds * (targetFrame / (double)Math.Max(1, _frames.Count - 1));
        if (_isPlaying)
        {
            _playbackStopwatch.Restart();
        }
        UpdateTimeDisplay(_pausedTimeSeconds, _totalDurationSeconds);
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var ext = Path.GetExtension(_filePath);
        if (string.IsNullOrEmpty(ext)) ext = ".gif";

        var initialDir = DataDirectoryManager.VideosDirectory;
        Directory.CreateDirectory(initialDir);

        var dlg = new SaveFileDialog
        {
            Filter = string.Equals(ext, ".mp4", StringComparison.OrdinalIgnoreCase)
                ? "MP4 Video (*.mp4)|*.mp4"
                : "GIF Animation (*.gif)|*.gif",
            FileName = Path.GetFileName(_filePath),
            InitialDirectory = initialDir
        };
        if (dlg.ShowDialog() == true)
        {
            if (CopyRecordingFile(dlg.FileName))
            {
                CloseReview();
            }
        }
    }

    private void OnQuickSaveClick(object sender, RoutedEventArgs e)
    {
        var destDir = DataDirectoryManager.VideosDirectory;
        Directory.CreateDirectory(destDir);
        var destPath = Path.Combine(destDir, Path.GetFileName(_filePath));
        if (CopyRecordingFile(destPath))
        {
            ShowQuickSaveSuccess(destPath);
            CloseReview();
        }
    }

    private void ShowQuickSaveSuccess(string destPath)
    {
        var dialog = new Window
        {
            Title = "Polyglance",
            Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            Width = 480,
            SizeToContent = SizeToContent.Height,
            WindowStyle = WindowStyle.SingleBorderWindow,
            Background = System.Windows.Media.Brushes.White,
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI"),
            ShowInTaskbar = false
        };

        var rootGrid = new System.Windows.Controls.Grid();
        rootGrid.RowDefinitions.Add(new System.Windows.Controls.RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rootGrid.RowDefinitions.Add(new System.Windows.Controls.RowDefinition { Height = GridLength.Auto });

        var bodyPanel = new System.Windows.Controls.StackPanel
        {
            Margin = new Thickness(20, 16, 20, 14)
        };

        var headerPanel = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            Margin = new Thickness(0, 0, 0, 10)
        };

        var iconBadge = new System.Windows.Controls.Border
        {
            Width = 24,
            Height = 24,
            CornerRadius = new CornerRadius(12),
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(220, 252, 231)),
            Margin = new Thickness(0, 0, 10, 0)
        };
        var checkIcon = new System.Windows.Controls.TextBlock
        {
            Text = "✓",
            FontWeight = FontWeights.Bold,
            FontSize = 13,
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(22, 163, 74)),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center
        };
        iconBadge.Child = checkIcon;
        headerPanel.Children.Add(iconBadge);

        var titleBlock = new System.Windows.Controls.TextBlock
        {
            Text = "录屏已快速保存",
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(15, 23, 42)),
            VerticalAlignment = System.Windows.VerticalAlignment.Center
        };
        headerPanel.Children.Add(titleBlock);
        bodyPanel.Children.Add(headerPanel);

        var pathContainer = new System.Windows.Controls.Border
        {
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(248, 250, 252)),
            BorderBrush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(226, 232, 240)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 8, 10, 8)
        };
        var pathBox = new System.Windows.Controls.TextBox
        {
            Text = destPath,
            IsReadOnly = true,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            FontSize = 12,
            Foreground = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(51, 65, 85)),
            TextWrapping = TextWrapping.Wrap
        };
        pathContainer.Child = pathBox;
        bodyPanel.Children.Add(pathContainer);

        System.Windows.Controls.Grid.SetRow(bodyPanel, 0);
        rootGrid.Children.Add(bodyPanel);

        var footerBorder = new System.Windows.Controls.Border
        {
            Background = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(248, 250, 252)),
            BorderBrush = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(241, 245, 249)),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(20, 10, 20, 10)
        };

        var buttonPanel = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };

        var btnOpen = new Wpf.Ui.Controls.Button
        {
            Content = "打开目录",
            Appearance = Wpf.Ui.Controls.ControlAppearance.Secondary,
            Padding = new Thickness(14, 5, 14, 5),
            Margin = new Thickness(0, 0, 8, 0),
            FontSize = 12,
            Cursor = Cursors.Hand
        };
        btnOpen.Click += (_, _) =>
        {
            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{destPath}\"",
                    UseShellExecute = true
                });
            }
            catch { }
            dialog.Close();
        };

        var btnOk = new Wpf.Ui.Controls.Button
        {
            Content = "确定",
            Appearance = Wpf.Ui.Controls.ControlAppearance.Primary,
            Padding = new Thickness(22, 5, 22, 5),
            FontSize = 12,
            IsDefault = true,
            IsCancel = true,
            Cursor = Cursors.Hand
        };
        btnOk.Click += (_, _) => dialog.Close();

        buttonPanel.Children.Add(btnOpen);
        buttonPanel.Children.Add(btnOk);
        footerBorder.Child = buttonPanel;

        System.Windows.Controls.Grid.SetRow(footerBorder, 1);
        rootGrid.Children.Add(footerBorder);

        dialog.Content = rootGrid;
        dialog.ShowDialog();
    }

    private void OnCopyFileClick(object sender, RoutedEventArgs e)
    {
        if (File.Exists(_filePath))
        {
            var files = new System.Collections.Specialized.StringCollection { _filePath };
            Clipboard.SetFileDropList(files);
            CloseReview();
        }
    }

    private bool CopyRecordingFile(string path)
    {
        try
        {
            if (!File.Exists(_filePath))
            {
                throw new FileNotFoundException("录屏临时文件不存在", _filePath);
            }
            if (!string.Equals(
                    Path.GetFullPath(_filePath),
                    Path.GetFullPath(path),
                    StringComparison.OrdinalIgnoreCase))
            {
                File.Copy(_filePath, path, overwrite: true);
            }
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show($"保存失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Error);
            return false;
        }
    }

    private void OnRestartClick(object sender, RoutedEventArgs e)
    {
        _playbackTimer.Stop();
        StopProgressAnimation();
        Close();

        var recordWin = new ScreenRecordingWindow(_originalScreenBounds, _originalRecordingRect);
        recordWin.Show();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => CloseReview();

    private void CloseReview()
    {
        _playbackTimer.Stop();
        StopProgressAnimation();
        if (_isMp4)
        {
            PlayerMedia.Close();
        }
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        _playbackTimer.Stop();
        StopProgressAnimation();
        _playbackStopwatch.Stop();
        PlayerMedia.Close();
        _frames.Clear();
        base.OnClosed(e);
        App.CurrentApp?.CheckOneShotExit();
    }
}
