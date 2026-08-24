using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Polyglance.UI.Views;

public partial class ScreenRecordingReviewWindow : Window
{
    private readonly string _filePath;
    private readonly List<BitmapSource> _frames;
    private readonly int _fps;
    private readonly Rect _originalScreenBounds;
    private readonly Rect _originalRecordingRect;
    private readonly DispatcherTimer _playbackTimer;
    private int _currentFrameIndex = 0;
    private bool _isPlaying = true;

    public ScreenRecordingReviewWindow(
        string filePath,
        List<BitmapSource> frames,
        int fps,
        Rect originalScreenBounds,
        Rect originalRecordingRect)
    {
        InitializeComponent();
        _filePath = filePath;
        _frames = frames ?? new List<BitmapSource>();
        _fps = Math.Max(1, fps);
        _originalScreenBounds = originalScreenBounds;
        _originalRecordingRect = originalRecordingRect;

        TxtTitle.Text = $"录屏预览 ({_frames.Count} 帧 · {_fps} FPS)";

        if (_frames.Count > 0)
        {
            PlayerImage.Source = _frames[0];
        }

        _playbackTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(1000.0 / _fps)
        };
        _playbackTimer.Tick += (s, e) =>
        {
            if (_frames.Count == 0) return;
            _currentFrameIndex = (_currentFrameIndex + 1) % _frames.Count;
            PlayerImage.Source = _frames[_currentFrameIndex];
        };

        if (_frames.Count > 1)
        {
            _playbackTimer.Start();
            _isPlaying = true;
            BtnPlayPause.Content = "暂停";
        }
        else
        {
            _isPlaying = false;
            BtnPlayPause.Content = "播放";
            BtnPlayPause.IsEnabled = false;
        }
    }

    private void OnTitleBarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void OnPlayPauseClick(object sender, RoutedEventArgs e)
    {
        if (_isPlaying)
        {
            _playbackTimer.Stop();
            _isPlaying = false;
            BtnPlayPause.Content = "播放";
        }
        else
        {
            _playbackTimer.Start();
            _isPlaying = true;
            BtnPlayPause.Content = "暂停";
        }
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var ext = Path.GetExtension(_filePath);
        if (string.IsNullOrEmpty(ext)) ext = ".gif";

        var dlg = new SaveFileDialog
        {
            Filter = string.Equals(ext, ".mp4", StringComparison.OrdinalIgnoreCase)
                ? "MP4 Video (*.mp4)|*.mp4"
                : "GIF Animation (*.gif)|*.gif",
            FileName = Path.GetFileName(_filePath)
        };
        if (dlg.ShowDialog() == true)
        {
            CopyRecordingFile(dlg.FileName);
        }
    }

    private void OnQuickSaveClick(object sender, RoutedEventArgs e)
    {
        var destDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "Polyglance");
        Directory.CreateDirectory(destDir);
        var destPath = Path.Combine(destDir, Path.GetFileName(_filePath));
        CopyRecordingFile(destPath);
        MessageBox.Show($"已快速保存至:\n{destPath}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void OnCopyFileClick(object sender, RoutedEventArgs e)
    {
        if (File.Exists(_filePath))
        {
            var files = new System.Collections.Specialized.StringCollection { _filePath };
            Clipboard.SetFileDropList(files);
        }
    }

    private void CopyRecordingFile(string path)
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
        }
        catch (Exception ex)
        {
            MessageBox.Show($"保存失败: {ex.Message}", "Polyglance", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OnRestartClick(object sender, RoutedEventArgs e)
    {
        _playbackTimer.Stop();
        Close();

        var recordWin = new ScreenRecordingWindow(_originalScreenBounds, _originalRecordingRect);
        recordWin.Show();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        _playbackTimer.Stop();
        Close();
    }
}
