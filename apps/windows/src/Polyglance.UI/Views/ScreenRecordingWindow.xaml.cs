using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Recording;

namespace Polyglance.UI.Views;

public partial class ScreenRecordingWindow : Window
{
    private readonly Rect _screenBounds;
    private readonly Rect _recordingRect;
    private readonly DispatcherTimer _clockTimer;
    private readonly DispatcherTimer _frameTimer;
    private readonly List<BitmapSource> _capturedFrames = new();
    private readonly FloatingToolbarWindow _toolbarWindow;

    private int _elapsedSeconds = 0;
    private int _fps = 30;
    private bool _isRecording = false;
    private bool _isPaused = false;
    private bool _recordAudio = true;
    private bool _recordMic = false;
    private bool _showCursor = true;
    private ScreenRecordingMediaOptions? _mediaOptions;
    private ScreenRecordingMp4Session? _mp4Session;
    private Int32Rect _physicalRecordingRegion;
    private int _consecutiveCaptureFailures;

    public ScreenRecordingWindow(Rect recordingRect, AppConfiguration? configuration = null)
        : this(
            new Rect(0, 0, SystemParameters.PrimaryScreenWidth, SystemParameters.PrimaryScreenHeight),
            recordingRect,
            configuration)
    {
    }

    public ScreenRecordingWindow(
        Rect screenBounds,
        Rect recordingRect,
        AppConfiguration? configuration = null)
    {
        InitializeComponent();
        ApplyRecordingDefaults(configuration);
        _screenBounds = screenBounds;
        _recordingRect = recordingRect;
        OverlayCanvas.Children.Remove(ControlToolbar);
        _toolbarWindow = new FloatingToolbarWindow(ControlToolbar);

        Left = screenBounds.X;
        Top = screenBounds.Y;
        Width = screenBounds.Width;
        Height = screenBounds.Height;

        // 设置选区红框位置与大小
        Canvas.SetLeft(RecordingBorder, recordingRect.X);
        Canvas.SetTop(RecordingBorder, recordingRect.Y);
        RecordingBorder.Width = Math.Max(10, recordingRect.Width);
        RecordingBorder.Height = Math.Max(10, recordingRect.Height);

        // 设置下方浮动工具栏位置
        Loaded += (_, _) =>
        {
            _toolbarWindow.Owner = this;
            _toolbarWindow.Show();
            _toolbarWindow.UpdateLayout();
            PositionToolbar();
        };
        Closed += (_, _) =>
        {
            if (_toolbarWindow.IsVisible)
            {
                _toolbarWindow.Close();
            }
        };

        _clockTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1)
        };
        _clockTimer.Tick += (s, e) =>
        {
            if (_isRecording && !_isPaused)
            {
                _elapsedSeconds++;
                int mm = _elapsedSeconds / 60;
                int ss = _elapsedSeconds % 60;
                TxtStatus.Text = $"● {mm:D2}:{ss:D2}";
            }
        };

        _frameTimer = new DispatcherTimer(DispatcherPriority.Render);
        _frameTimer.Tick += OnFrameTimerTick;
    }

    private void ApplyRecordingDefaults(AppConfiguration? configuration)
    {
        if (configuration == null)
        {
            return;
        }

        SelectByContent(CmbFormat, configuration.DefaultRecordingFormat, "MP4");
        SelectByContent(CmbFps, $"{configuration.DefaultRecordingFps} FPS", "30 FPS");
        string delay = configuration.DefaultRecordingDelaySeconds <= 0
            ? "无延时"
            : $"{configuration.DefaultRecordingDelaySeconds}秒";
        SelectByContent(CmbDelay, delay, "无延时");
    }

    private static void SelectByContent(
        System.Windows.Controls.ComboBox comboBox,
        string value,
        string fallback)
    {
        ComboBoxItem? fallbackItem = null;
        foreach (ComboBoxItem item in comboBox.Items)
        {
            string content = item.Content?.ToString() ?? string.Empty;
            if (content.Equals(fallback, StringComparison.OrdinalIgnoreCase))
            {
                fallbackItem = item;
            }
            if (content.Equals(value, StringComparison.OrdinalIgnoreCase))
            {
                comboBox.SelectedItem = item;
                return;
            }
        }

        comboBox.SelectedItem = fallbackItem ?? comboBox.Items[0];
    }

    private void PositionToolbar()
    {
        ControlToolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        double tbWidth = ControlToolbar.DesiredSize.Width > 0 ? ControlToolbar.DesiredSize.Width : 710;
        double tbHeight = ControlToolbar.DesiredSize.Height > 0 ? ControlToolbar.DesiredSize.Height : 46;

        // 水平居中对齐选区
        double left = _recordingRect.Left + (_recordingRect.Width - tbWidth) / 2.0;
        left = Math.Clamp(left, 12, Width - tbWidth - 12);

        // 默认显示在选区正下方，若底部越界则显示在选区正上方，若上下均不足则显示在选区内部下方
        double outsideBelow = _recordingRect.Bottom + 10;
        double top;
        if (outsideBelow + tbHeight <= Height - 12)
        {
            top = outsideBelow;
        }
        else
        {
            double outsideAbove = _recordingRect.Top - tbHeight - 10;
            if (outsideAbove >= 12)
            {
                top = outsideAbove;
            }
            else
            {
                top = Math.Clamp(_recordingRect.Bottom - tbHeight - 10, 12, Math.Max(12, Height - tbHeight - 12));
            }
        }

        _toolbarWindow.Left = _screenBounds.X + left;
        _toolbarWindow.Top = _screenBounds.Y + top;
    }

    private async void OnStartClick(object sender, RoutedEventArgs e)
    {
        try
        {
            int delaySeconds = CmbDelay.SelectedIndex switch
            {
                1 => 3,
                2 => 5,
                3 => 10,
                _ => 0,
            };
            if (delaySeconds > 0)
            {
                BtnStart.IsEnabled = false;
                for (int remaining = delaySeconds; remaining > 0; remaining--)
                {
                    TxtStatus.Text = $"{remaining} 秒后录制";
                    await Task.Delay(TimeSpan.FromSeconds(1));
                    if (!IsLoaded)
                    {
                        return;
                    }
                }
            }

            var formatText = ((ComboBoxItem)CmbFormat.SelectedItem)?.Content?.ToString();
            var container = ScreenRecordingContainerParser.Parse(formatText);
            _mediaOptions = ScreenRecordingMediaOptions.Create(
                container,
                _recordAudio,
                _recordMic,
                _showCursor);
            _isPaused = false;
            _elapsedSeconds = 0;
            _consecutiveCaptureFailures = 0;
            _capturedFrames.Clear();

            string fpsStr = ((ComboBoxItem)CmbFps.SelectedItem)?.Content?.ToString() ?? "30 FPS";
            if (fpsStr.StartsWith("60")) _fps = 60;
            else if (fpsStr.StartsWith("15")) _fps = 15;
            else _fps = 30;

            var transform = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice
                ?? Matrix.Identity;
            _physicalRecordingRegion = ScreenRecordingCaptureGeometry.ToPhysicalRegion(
                new Point(_screenBounds.X, _screenBounds.Y),
                _recordingRect,
                transform);

            if (container == ScreenRecordingContainer.Mp4)
            {
                var qualityIndex = Math.Max(0, CmbQuality.SelectedIndex);
                var jpegQuality = qualityIndex switch { 0 => 76, 1 => 88, _ => 96 };
                var bitsPerPixel = qualityIndex switch { 0 => 0.10, 1 => 0.16, _ => 0.24 };
                var estimated = _physicalRecordingRegion.Width
                    * (double)_physicalRecordingRegion.Height
                    * _fps
                    * bitsPerPixel;
                var bitrate = (uint)Math.Clamp(estimated, 2_000_000, 30_000_000);
                var sessionDirectory = Path.Combine(
                    Path.GetTempPath(),
                    "Polyglance",
                    $"recording-{Guid.NewGuid():N}");
                try
                {
                    _mp4Session = CreateMp4Session(
                        sessionDirectory,
                        jpegQuality,
                        bitrate,
                        _mediaOptions);
                }
                catch (ScreenRecordingAudioDeviceUnavailableException error)
                    when (error.DeviceKind == ScreenRecordingAudioDeviceKind.Microphone &&
                          _mediaOptions.CapturesMicrophone)
                {
                    var choice = MessageBox.Show(
                        $"{error.Message}\n\n是否关闭本次麦克风录制并继续？",
                        "麦克风不可用",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Warning);
                    if (choice != MessageBoxResult.Yes)
                    {
                        return;
                    }

                    _recordMic = false;
                    UpdateMicrophoneButton();
                    _mediaOptions = _mediaOptions.WithoutMicrophone();
                    _mp4Session = CreateMp4Session(
                        sessionDirectory,
                        jpegQuality,
                        bitrate,
                        _mediaOptions);
                }
            }
            _isRecording = true;
        }
        catch (Exception error)
        {
            _isRecording = false;
            BtnStart.IsEnabled = true;
            BtnStart.Opacity = 1.0;
            TxtStatus.Text = "待录制";
            MessageBox.Show(
                $"无法开始录屏：{error.Message}",
                "Polyglance",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        TxtStatus.Text = "● 00:00";
        TxtStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));

        // 开始录制后：开始按钮置灰禁用
        BtnStart.IsEnabled = false;
        BtnStart.Opacity = 0.35;

        // 启用暂停与停止按钮
        BtnPause.IsEnabled = true;
        BtnPause.Opacity = 1.0;
        BtnStop.IsEnabled = true;
        BtnStop.Opacity = 1.0;

        // 锁定设置项
        CmbFormat.IsEnabled = false;
        CmbQuality.IsEnabled = false;
        CmbFps.IsEnabled = false;
        CmbDelay.IsEnabled = false;
        BtnAudio.IsEnabled = false;
        BtnMic.IsEnabled = false;
        BtnCursor.IsEnabled = false;

        _frameTimer.Interval = TimeSpan.FromMilliseconds(1000.0 / _fps);
        _frameTimer.Start();
        _clockTimer.Start();
    }

    private ScreenRecordingMp4Session CreateMp4Session(
        string sessionDirectory,
        int jpegQuality,
        uint bitrate,
        ScreenRecordingMediaOptions options) =>
        new(
            sessionDirectory,
            _physicalRecordingRegion.Width,
            _physicalRecordingRegion.Height,
            _fps,
            jpegQuality,
            bitrate,
            options);

    private void OnFrameTimerTick(object? sender, EventArgs e)
    {
        if (!_isRecording || _isPaused) return;

        try
        {
            var frame = ScreenCapture.CaptureRegion(
                _physicalRecordingRegion,
                _mediaOptions?.ShowsCursor ?? _showCursor);
            if (frame != null)
            {
                _capturedFrames.Add(frame);
                _mp4Session?.AppendFrame(frame);
            }
            _consecutiveCaptureFailures = 0;
        }
        catch (Exception error)
        {
            _consecutiveCaptureFailures++;
            System.Diagnostics.Debug.WriteLine($"Screen recording frame failed: {error}");
            if (_consecutiveCaptureFailures >= 3)
            {
                _ = FailRecordingAsync(error);
            }
        }
    }

    private void OnPauseClick(object sender, RoutedEventArgs e)
    {
        _isPaused = !_isPaused;
        if (_isPaused)
        {
            _mp4Session?.SetPaused(true);
            TxtStatus.Text = "Ⅱ 暂停";
            TxtStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xF5, 0x9E, 0x0B));
            IconPause.Data = Geometry.Parse("M8,5.14 V19.14 L19,12.14 Z"); // 播放图标
            BtnPause.ToolTip = "继续录制";
        }
        else
        {
            _mp4Session?.SetPaused(false);
            int mm = _elapsedSeconds / 60;
            int ss = _elapsedSeconds % 60;
            TxtStatus.Text = $"● {mm:D2}:{ss:D2}";
            TxtStatus.Foreground = new SolidColorBrush(Color.FromRgb(0xEF, 0x44, 0x44));
            IconPause.Data = Geometry.Parse("M6,19 H10 V5 H6 Z M14,5 V19 H18 V5 Z"); // 暂停图标
            BtnPause.ToolTip = "暂停录制";
        }
    }

    private async void OnStopClick(object sender, RoutedEventArgs e)
    {
        _clockTimer.Stop();
        _frameTimer.Stop();
        _isRecording = false;

        // 即时交互反馈：切换为“生成中…”并旋转 ProgressRing
        TxtStatus.Text = "生成中…";
        TxtStatus.Foreground = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF));
        RingSaving.Visibility = Visibility.Visible;

        BtnStop.IsEnabled = false;
        BtnStop.Opacity = 0.35;
        BtnPause.IsEnabled = false;
        BtnPause.Opacity = 0.35;
        BtnClose.IsEnabled = false;

        var container = _mediaOptions?.Container ?? ScreenRecordingContainer.Gif;
        string formatExt = container == ScreenRecordingContainer.Mp4 ? "mp4" : "gif";

        string tempDir = Path.Combine(Path.GetTempPath(), "Polyglance");
        Directory.CreateDirectory(tempDir);
        string tempFile = Path.Combine(tempDir, $"ScreenRecord_{DateTime.Now:yyyyMMdd_HHmmss_fff}.{formatExt}");

        try
        {
            if (_capturedFrames.Count == 0)
            {
                throw new InvalidOperationException("没有捕获到有效画面");
            }
            if (container == ScreenRecordingContainer.Mp4)
            {
                var session = _mp4Session
                    ?? throw new InvalidOperationException("MP4 编码会话尚未启动");
                await session.FinishAsync(tempFile);
                _mp4Session = null;
            }
            else
            {
                var framesSnapshot = new List<BitmapSource>(_capturedFrames);
                await Task.Run(() =>
                {
                    var encoder = new GifBitmapEncoder();
                    foreach (var frame in framesSnapshot)
                    {
                        encoder.Frames.Add(BitmapFrame.Create(frame));
                    }
                    using var fs = File.Create(tempFile);
                    encoder.Save(fs);
                });
            }
        }
        catch (Exception error)
        {
            RingSaving.Visibility = Visibility.Collapsed;
            BtnClose.IsEnabled = true;
            MessageBox.Show(
                $"生成录屏失败：{error.Message}",
                "Polyglance",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return;
        }

        Close();

        // 对齐 macOS: 打开 Review 预览窗口，支持播放、另存为、快速保存、复制文件、重新录制
        var reviewWin = new ScreenRecordingReviewWindow(
            tempFile,
            _capturedFrames,
            _fps,
            _screenBounds,
            _recordingRect
        );
        reviewWin.Show();
    }

    private void OnToggleAudio(object sender, RoutedEventArgs e)
    {
        _recordAudio = !_recordAudio;
        IconAudio.Fill = _recordAudio ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : new SolidColorBrush(Color.FromRgb(0x94, 0xA3, 0xB8));
        IconAudioSlash.Visibility = _recordAudio ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnToggleMic(object sender, RoutedEventArgs e)
    {
        _recordMic = !_recordMic;
        UpdateMicrophoneButton();
    }

    private void UpdateMicrophoneButton()
    {
        IconMic.Fill = _recordMic ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : new SolidColorBrush(Color.FromRgb(0x94, 0xA3, 0xB8));
        IconMicSlash.Visibility = _recordMic ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnToggleCursor(object sender, RoutedEventArgs e)
    {
        _showCursor = !_showCursor;
        IconCursor.Fill = _showCursor ? new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)) : new SolidColorBrush(Color.FromRgb(0x94, 0xA3, 0xB8));
    }

    private void OnFormatChanged(object sender, SelectionChangedEventArgs e)
    {
        if (BtnAudio is null || BtnMic is null) return;
        var formatText = ((ComboBoxItem)CmbFormat.SelectedItem)?.Content?.ToString();
        var supportsAudio = string.Equals(formatText, "MP4", StringComparison.OrdinalIgnoreCase);
        BtnAudio.IsEnabled = supportsAudio && !_isRecording;
        BtnMic.IsEnabled = supportsAudio && !_isRecording;
        BtnAudio.Opacity = supportsAudio ? 1.0 : 0.35;
        BtnMic.Opacity = supportsAudio ? 1.0 : 0.35;
        BtnAudio.ToolTip = supportsAudio ? "录制系统声音" : "GIF 不支持声音";
        BtnMic.ToolTip = supportsAudio ? "录制麦克风" : "GIF 不支持声音";
    }

    private async Task FailRecordingAsync(Exception error)
    {
        if (!_isRecording) return;
        _isRecording = false;
        _clockTimer.Stop();
        _frameTimer.Stop();
        if (_mp4Session is not null)
        {
            await _mp4Session.DisposeAsync();
            _mp4Session = null;
        }
        MessageBox.Show(
            $"录屏捕获连续失败：{error.Message}",
            "Polyglance",
            MessageBoxButton.OK,
            MessageBoxImage.Error);
        Close();
    }

    private async void OnCancelClick(object sender, RoutedEventArgs e)
    {
        _clockTimer.Stop();
        _frameTimer.Stop();
        _isRecording = false;
        if (_mp4Session is not null)
        {
            await _mp4Session.DisposeAsync();
            _mp4Session = null;
        }
        Close();
    }
}
