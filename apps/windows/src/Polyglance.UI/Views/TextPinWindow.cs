using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Polyglance.Platform.Pin;
using TextBox = System.Windows.Controls.TextBox;

namespace Polyglance.UI.Views;

internal sealed class TextPinWindow : Window
{
    internal TextBox TextContent { get; }
    private bool _locked;
    private double _scale = 1.0;
    private readonly Size _initialSize;
    private readonly Border _zoomBadge;
    private readonly TextBlock _zoomBadgeText;
    private readonly System.Windows.Threading.DispatcherTimer _zoomBadgeTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private readonly PinSessionController _sessions;

    internal TextPinWindow(string text, PinArchiveStore? store = null, string? archiveId = null, PinSessionRecord? session = null)
    {
        if (string.IsNullOrEmpty(text) || System.Text.Encoding.UTF8.GetByteCount(text) > 1048576)
            throw new ArgumentException("文本为空或超过 1 MB，无法贴出。", nameof(text));
        Title = "Polyglance · 文本贴图";
        ShowInTaskbar = false;
        WindowStyle = WindowStyle.None;
        var size = FittedSize(text, SystemParameters.WorkArea.Size);
        _initialSize = size;
        Width = session?.Width ?? size.Width;
        Height = session?.Height ?? size.Height;
        if (session != null && _initialSize.Width > 0)
        {
            _scale = Width / _initialSize.Width;
        }
        MinWidth = 80; MinHeight = 44;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0, ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(0), UseAeroCaptionButtons = false
        });
        Topmost = session?.IsAlwaysOnTop ?? true;
        Opacity = session?.Opacity ?? 1;
        _locked = session?.IsLocked ?? false;
        ResizeMode = ResizeMode.NoResize;
        if (session != null) { Left = session.X; Top = session.Y; }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;
        TextContent = new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true,
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI"), FontSize = Math.Max(8, Math.Round(16 * _scale)), Padding = new Thickness(8, 4, 8, 4),
            BorderThickness = new Thickness(0), Background = Brushes.White, Foreground = Brushes.Black,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        _zoomBadgeText = new TextBlock
        {
            Text = "100%",
            Foreground = Brushes.White,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center
        };
        _zoomBadge = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(191, 0, 0, 0)),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(12, 6, 12, 6),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Child = _zoomBadgeText
        };
        _zoomBadgeTimer.Tick += (_, _) => { _zoomBadge.Visibility = Visibility.Collapsed; _zoomBadgeTimer.Stop(); };

        var grid = new Grid();
        grid.Children.Add(TextContent);
        grid.Children.Add(_zoomBadge);

        var card = new Border { Background = Brushes.White, BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1),
            Padding = new Thickness(7), Child = grid,
            ToolTip = "拖动贴图移动，滚轮缩放大小，中键重置；文字可直接选择，双击或 Esc 关闭。" };
        card.MouseLeftButtonDown += (_, e) => { if (!_locked && e.OriginalSource == card) { DragMove(); e.Handled = true; } };
        Content = card;
        _sessions = PinSessionController.For(store);
        var menu = new ContextMenu();
        Add(menu, "复制所选文字", () => TextContent.Copy());
        Add(menu, "复制全部文字", () => Clipboard.SetText(text));
        Add(menu, "复制图片", CopyVisibleImage);
        Add(menu, "保存图片...", SaveAsImage);
        menu.Items.Add(new Separator());

        var opacityItem = new MenuItem { Header = "透明度 (Opacity)" };
        foreach (var (label, val) in new[] { ("100% (默认)", 1.0), ("80%", 0.8), ("60%", 0.6), ("40%", 0.4) })
        {
            var subItem = new MenuItem { Header = label };
            double capturedVal = val;
            subItem.Click += (_, _) => Opacity = capturedVal;
            opacityItem.Items.Add(subItem);
        }
        menu.Items.Add(opacityItem);

        var topmostItem = new MenuItem { Header = "总在最前 (Topmost)", IsCheckable = true, IsChecked = Topmost };
        topmostItem.Click += (_, _) => { Topmost = !Topmost; topmostItem.IsChecked = Topmost; };
        menu.Items.Add(topmostItem);

        var lockItem = new MenuItem { Header = "锁定贴图", IsCheckable = true, IsChecked = _locked };
        lockItem.Click += (_, _) => { _locked = !_locked; lockItem.IsChecked = _locked; };
        menu.Items.Add(lockItem);
        menu.Items.Add(new Separator());

        Add(menu, "恢复最近关闭的贴图", async () => await _sessions.Restore(false, null, null));
        menu.Items.Add(new Separator());

        Add(menu, "关闭贴图 (Close)", Close);
        Add(menu, "销毁贴图及历史", async () => await _sessions.Destroy(this));
        Add(menu, "销毁全部贴图及对应历史", async () => await _sessions.DestroyAll());
        TextContent.ContextMenu = menu;
        card.ContextMenu = menu;
        PreviewMouseDoubleClick += (_, e) => { if (e.LeftButton == MouseButtonState.Pressed) { Close(); e.Handled = true; } };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { Close(); e.Handled = true; } };
        PreviewMouseWheel += OnPreviewMouseWheel;
        PreviewMouseDown += (_, e) =>
        {
            if (e.ChangedButton == MouseButton.Middle && !_locked)
            {
                _scale = 1.0;
                Width = Math.Max(MinWidth, _initialSize.Width);
                Height = Math.Max(MinHeight, _initialSize.Height);
                TextContent.FontSize = 16;
                ShowZoomBadge(100);
                e.Handled = true;
            }
        };
        SourceInitialized += (_, _) =>
        {
            // A locked text pin still allows selection/copy, but blocks native title-bar movement.
            var source = System.Windows.Interop.HwndSource.FromHwnd(new System.Windows.Interop.WindowInteropHelper(this).Handle);
            source?.AddHook((IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) =>
            {
                if (_locked && msg == 0x0112 && ((wParam.ToInt64() & 0xFFF0) == 0xF010)) handled = true;
                return IntPtr.Zero;
            });
        };
        _sessions.Register(this, Preview(text), PinArchiveSource.Clipboard, archiveId == null && session == null,
            archiveId, session, text, state => state with
            {
                X = double.IsFinite(Left) ? Left : 0, Y = double.IsFinite(Top) ? Top : 0,
                Width = Width, Height = Height, Opacity = Opacity, IsLocked = _locked, IsAlwaysOnTop = Topmost
            });
    }

    internal static Size FittedSize(string text, Size maximumSize)
    {
        double width = Math.Max(80, Math.Min(1200, maximumSize.Width * .9));
        var formatted = new FormattedText(text, CultureInfo.CurrentCulture, System.Windows.FlowDirection.LeftToRight,
            new Typeface("Segoe UI"), 16, Brushes.Black, 1) { MaxTextWidth = width - 32 };
        return new Size(Math.Min(width, Math.Max(80, Math.Ceiling(formatted.WidthIncludingTrailingWhitespace) + 34)),
            Math.Min(Math.Max(44, maximumSize.Height * .8), Math.Max(44, Math.Ceiling(formatted.Height) + 24)));
    }

    private static void Add(ContextMenu menu, string title, Action action)
    {
        var item = new MenuItem { Header = title };
        item.Click += (_, _) => { try { action(); } catch { PinSessionController.Report("操作失败，请稍后重试。"); } };
        menu.Items.Add(item);
    }

    internal static BitmapSource Preview(string text)
    {
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            drawing.DrawRectangle(Brushes.White, null, new Rect(0, 0, 640, 480));
            var formatted = new FormattedText(text[..Math.Min(text.Length, 8000)], CultureInfo.CurrentCulture,
                System.Windows.FlowDirection.LeftToRight, new Typeface("Segoe UI"), 18, Brushes.Black, 1)
                { MaxTextWidth = 600, MaxTextHeight = 440 };
            drawing.DrawText(formatted, new Point(20, 20));
        }
        var image = new RenderTargetBitmap(640, 480, 96, 96, PixelFormats.Pbgra32);
        image.Render(visual); image.Freeze(); return image;
    }

    private RenderTargetBitmap RenderToBitmap()
    {
        var bitmap = new RenderTargetBitmap((int)Math.Max(1, TextContent.ActualWidth), (int)Math.Max(1, TextContent.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(TextContent);
        bitmap.Freeze();
        return bitmap;
    }

    private void CopyVisibleImage()
    {
        Clipboard.SetImage(RenderToBitmap());
    }

    private void SaveAsImage()
    {
        var bitmap = RenderToBitmap();
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Filter = "PNG 图片 (*.png)|*.png",
            FileName = $"Polyglance_TextPin_{DateTime.Now:yyyyMMdd_HHmmss}.png"
        };
        if (dialog.ShowDialog() == true)
        {
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = System.IO.File.Create(dialog.FileName);
            encoder.Save(stream);
        }
    }

    private void OnPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_locked) return;

        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            if (e.Delta > 0)
                Opacity = Math.Min(1.0, Opacity + 0.1);
            else
                Opacity = Math.Max(0.1, Opacity - 0.1);
            e.Handled = true;
            return;
        }

        double oldScale = _scale;
        if (e.Delta > 0)
            _scale = Math.Min(3.5, _scale * 1.1);
        else
            _scale = Math.Max(0.2, _scale / 1.1);

        double factor = _scale / oldScale;
        Width = Math.Max(MinWidth, Width * factor);
        Height = Math.Max(MinHeight, Height * factor);
        TextContent.FontSize = Math.Max(8, Math.Round(16 * _scale));

        ShowZoomBadge((int)Math.Round(_scale * 100));
        e.Handled = true;
    }

    private void ShowZoomBadge(int percent)
    {
        _zoomBadgeText.Text = $"{percent}%";
        _zoomBadge.Visibility = Visibility.Visible;
        _zoomBadgeTimer.Stop();
        _zoomBadgeTimer.Start();
    }
}
