using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Ocr;
using TextFormattingMode = Polyglance.Core.Services.TextFormattingMode;

namespace Polyglance.UI.Views;

public partial class OcrWorkspaceWindow : Window
{
    public static OcrWorkspaceWindow? ActiveContinuousInstance { get; private set; }

    private readonly System.Collections.Generic.List<BitmapSource> _bitmaps = new();
    private int _currentImageIndex = 0;
    private BitmapSource? CurrentBitmap => _bitmaps.Count > 0 && _currentImageIndex < _bitmaps.Count ? _bitmaps[_currentImageIndex] : null;

    private BitmapSource _bitmap;
    private OcrTextDocument _document;
    private readonly TranslationService? _translationService;
    private readonly AppConfiguration? _configuration;
    private string _rawText = string.Empty;
    private TextFormattingMode _currentMode = TextFormattingMode.SmartMerge;
    public bool IsContinuousMode => BtnContinuous.IsChecked == true;

    private Point _viewportLastMousePos;
    private bool _isViewportDragging;
    private bool _hasUserInteractedWithViewport;

    public OcrWorkspaceWindow(
        BitmapSource bitmap,
        OcrTextDocument? document,
        TranslationService? translationService,
        AppConfiguration? configuration)
    {
        InitializeComponent();
        _bitmap = bitmap;
        _document = document!;
        _translationService = translationService;
        _configuration = configuration;

        if (_configuration != null)
        {
            ChkAutoCopyNextTime.IsChecked = _configuration.OcrAutoCopyNextTime;
            _currentMode = (TextFormattingMode)Math.Clamp(_configuration.OcrDefaultFormatting, 0, 3);
        }

        UpdateFormattingMenuSelection();
        UpdatePinButtonState();

        if (document != null)
        {
            LoadInitialDocument(bitmap, document);
        }
        else
        {
            LoadInitialImage(bitmap);
        }
    }

    private void LoadInitialImage(BitmapSource bitmap)
    {
        _bitmap = bitmap;
        _document = null!;
        _rawText = string.Empty;
        _bitmaps.Clear();
        _bitmaps.Add(bitmap);
        _currentImageIndex = 0;

        UpdateImageViewport();
        ShowLoading(true);
        UpdateStats();
        BtnCopyAll.IsEnabled = false;
        BtnFormatting.IsEnabled = false;
    }

    private void ShowLoading(bool show)
    {
        LoadingOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
    }

    public void SetDocument(OcrTextDocument document)
    {
        _document = document;
        _rawText = document.FullText;
        ShowLoading(false);
        BtnCopyAll.IsEnabled = true;
        BtnFormatting.IsEnabled = true;
        ApplyFormatting();
        DrawBoundingBoxes();
        UpdateStats();
    }

    public void SetError(string errorMessage)
    {
        ShowLoading(false);
        BtnCopyAll.IsEnabled = false;
        TxtStats.Text = "识别失败";
        TxtContent.Text = errorMessage;
    }

    private void LoadInitialDocument(BitmapSource bitmap, OcrTextDocument document)
    {
        _bitmap = bitmap;
        _document = document;
        _rawText = document.FullText;
        _bitmaps.Clear();
        _bitmaps.Add(bitmap);
        _currentImageIndex = 0;

        ShowLoading(false);
        UpdateImageViewport();
        ApplyFormatting();
        DrawBoundingBoxes();
        UpdateStats();
    }

    public void StartPendingAppend(BitmapSource bitmap)
    {
        _bitmap = bitmap;
        _bitmaps.Add(bitmap);
        _currentImageIndex = _bitmaps.Count - 1;
        UpdateImageViewport();
        TxtStats.Text = "正在识别追加内容...";
    }

    public void FinishPendingAppend(BitmapSource bitmap, OcrTextDocument document)
    {
        _bitmap = bitmap;
        _document = document;
        if (!_bitmaps.Contains(bitmap))
        {
            _bitmaps.Add(bitmap);
            _currentImageIndex = _bitmaps.Count - 1;
        }
        UpdateImageViewport();
        DrawBoundingBoxes();

        var newFormatted = document.Lines != null && document.Lines.Count > 0
            ? TextFormattingService.Format(document.Lines, _currentMode)
            : TextFormattingService.Format(document.FullText, _currentMode);
        if (string.IsNullOrWhiteSpace(TxtContent.Text))
        {
            TxtContent.Text = newFormatted;
            _rawText = document.FullText;
        }
        else
        {
            TxtContent.Text += "\n\n" + newFormatted;
            _rawText += "\n\n" + document.FullText;
        }

        TxtContent.CaretIndex = TxtContent.Text.Length;
        TxtContent.ScrollToEnd();
        UpdateStats();
    }

    public void CancelPendingAppend(Exception ex)
    {
        TxtStats.Text = "追加识别失败";
    }

    public void AppendContent(BitmapSource bitmap, OcrTextDocument document)
    {
        FinishPendingAppend(bitmap, document);
    }

    private void UpdateImageViewport()
    {
        var current = CurrentBitmap;
        if (current != null)
        {
            ImgViewport.Source = current;
            ImgViewport.Width = current.PixelWidth;
            ImgViewport.Height = current.PixelHeight;
            ResetViewportZoomAndPan();
        }
        UpdatePagingUI();
    }

    private void UpdatePagingUI()
    {
        if (_bitmaps.Count > 1)
        {
            PagingOverlay.Visibility = Visibility.Visible;
            TxtImagePage.Text = $"{_currentImageIndex + 1} / {_bitmaps.Count}";
        }
        else
        {
            PagingOverlay.Visibility = Visibility.Collapsed;
        }
    }

    private void OnPrevImageClick(object sender, RoutedEventArgs e)
    {
        if (_currentImageIndex > 0)
        {
            _currentImageIndex--;
            UpdateImageViewport();
        }
    }

    private void OnNextImageClick(object sender, RoutedEventArgs e)
    {
        if (_currentImageIndex < _bitmaps.Count - 1)
        {
            _currentImageIndex++;
            UpdateImageViewport();
        }
    }

    private void ResetViewportZoomAndPan()
    {
        _hasUserInteractedWithViewport = false;
        var current = CurrentBitmap;
        if (current == null) return;
        if (ImagePreviewSection == null || ViewportScaleTransform == null || ViewportTranslateTransform == null) return;

        double viewW = ImagePreviewSection.ActualWidth;
        double viewH = ImagePreviewSection.ActualHeight;
        if (viewW <= 0 || viewH <= 0) return;

        double imgW = current.PixelWidth;
        double imgH = current.PixelHeight;
        if (imgW <= 0 || imgH <= 0) return;

        double scaleX = viewW / imgW;
        double scaleY = viewH / imgH;
        double fit = Math.Min(scaleX, scaleY);
        double scale = fit >= 1.0 ? 1.0 : fit;
        if (scale < 0.05) scale = fit;

        ViewportScaleTransform.ScaleX = scale;
        ViewportScaleTransform.ScaleY = scale;

        double scaledW = imgW * scale;
        double scaledH = imgH * scale;
        ViewportTranslateTransform.X = Math.Round((viewW - scaledW) / 2.0);
        ViewportTranslateTransform.Y = Math.Round((viewH - scaledH) / 2.0);

        UpdateScalingMode(scale);
    }

    private void OnImagePreviewSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_hasUserInteractedWithViewport)
        {
            ResetViewportZoomAndPan();
        }
    }

    private void OnViewportMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject dep)
        {
            if (PagingOverlay != null && (PagingOverlay.IsAncestorOf(dep) || ReferenceEquals(dep, PagingOverlay)))
            {
                return;
            }
        }

        if (e.ClickCount == 2)
        {
            ResetViewportZoomAndPan();
            e.Handled = true;
            return;
        }

        if (e.ChangedButton == MouseButton.Left)
        {
            _isViewportDragging = true;
            _hasUserInteractedWithViewport = true;
            _viewportLastMousePos = e.GetPosition(ImagePreviewSection);
            ImagePreviewSection.CaptureMouse();
            e.Handled = true;
        }
    }

    private void OnViewportMouseMove(object sender, MouseEventArgs e)
    {
        if (_isViewportDragging)
        {
            var currentPos = e.GetPosition(ImagePreviewSection);
            var delta = currentPos - _viewportLastMousePos;
            _viewportLastMousePos = currentPos;

            ViewportTranslateTransform.X += delta.X;
            ViewportTranslateTransform.Y += delta.Y;
            e.Handled = true;
        }
    }

    private void OnViewportMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject dep)
        {
            if (PagingOverlay != null && (PagingOverlay.IsAncestorOf(dep) || ReferenceEquals(dep, PagingOverlay)))
            {
                return;
            }
        }

        if (_isViewportDragging)
        {
            _isViewportDragging = false;
            ImagePreviewSection.ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    private void OnViewportMouseWheel(object sender, MouseWheelEventArgs e)
    {
        var mousePos = e.GetPosition(ImagePreviewSection);
        double factor = e.Delta > 0 ? 1.15 : 0.85;
        ApplyViewportZoom(factor, mousePos);
        e.Handled = true;
    }

    private void ApplyViewportZoom(double factor, Point center)
    {
        var current = CurrentBitmap;
        if (current == null) return;

        double oldScale = ViewportScaleTransform.ScaleX;
        double newScale = Math.Clamp(oldScale * factor, 0.05, 10.0);
        if (Math.Abs(newScale - oldScale) < 0.0001) return;

        _hasUserInteractedWithViewport = true;

        double imgX = (center.X - ViewportTranslateTransform.X) / oldScale;
        double imgY = (center.Y - ViewportTranslateTransform.Y) / oldScale;

        ViewportScaleTransform.ScaleX = newScale;
        ViewportScaleTransform.ScaleY = newScale;

        ViewportTranslateTransform.X = Math.Round(center.X - imgX * newScale);
        ViewportTranslateTransform.Y = Math.Round(center.Y - imgY * newScale);

        UpdateScalingMode(newScale);
    }

    private void UpdateScalingMode(double scale)
    {
        if (Math.Abs(scale - 1.0) < 0.001)
        {
            RenderOptions.SetBitmapScalingMode(ImgViewport, BitmapScalingMode.NearestNeighbor);
        }
        else
        {
            RenderOptions.SetBitmapScalingMode(ImgViewport, BitmapScalingMode.HighQuality);
        }
    }

    private void ApplyFormatting()
    {
        if (_document?.Lines != null && _document.Lines.Count > 0)
        {
            TxtContent.Text = TextFormattingService.Format(_document.Lines, _currentMode);
        }
        else
        {
            TxtContent.Text = TextFormattingService.Format(_rawText, _currentMode);
        }
        TxtContent.CaretIndex = TxtContent.Text.Length;
    }

    private void DrawBoundingBoxes()
    {
    }

    private void UpdateStats()
    {
        var text = TxtContent.Text ?? string.Empty;
        var charCount = text.Length;
        var lineCount = string.IsNullOrEmpty(text) ? 0 : text.Split('\n').Length;
        TxtStats.Text = $"字符数: {charCount} | 行数: {lineCount}";
        var engine = OcrService.GetEngine();
        var lang = DetectLanguageName(text);
        TxtLanguage.Text = $"引擎: {engine.DisplayName} | 语言: {lang}";
    }

    private static string DetectLanguageName(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "自动检测";
        if (Regex.IsMatch(text, @"[\u3040-\u30FF]")) return "日语";
        if (Regex.IsMatch(text, @"[\uAC00-\uD7AF]")) return "韩语";
        if (Regex.IsMatch(text, @"[\u4E00-\u9FA5]")) return "简体中文";
        if (Regex.IsMatch(text, @"[\u0400-\u04FF]")) return "俄语";
        return "英语";
    }

    private void UpdateFormattingMenuSelection()
    {
        MenuSmartMerge.IsChecked = _currentMode == TextFormattingMode.SmartMerge;
        MenuPreserveBreaks.IsChecked = _currentMode == TextFormattingMode.PreserveBreaks;
        MenuRemoveSpaces.IsChecked = _currentMode == TextFormattingMode.RemoveSpaces;
        MenuRaw.IsChecked = _currentMode == TextFormattingMode.Raw;
    }

    private void SwitchFormattingMode(TextFormattingMode mode)
    {
        _currentMode = mode;
        UpdateFormattingMenuSelection();
        ApplyFormatting();
        if (_configuration != null)
        {
            _configuration.OcrDefaultFormatting = (int)mode;
        }
    }

    private void OnSelectSmartMerge(object sender, RoutedEventArgs e) => SwitchFormattingMode(TextFormattingMode.SmartMerge);
    private void OnSelectPreserveBreaks(object sender, RoutedEventArgs e) => SwitchFormattingMode(TextFormattingMode.PreserveBreaks);
    private void OnSelectRemoveSpaces(object sender, RoutedEventArgs e) => SwitchFormattingMode(TextFormattingMode.RemoveSpaces);
    private void OnSelectRaw(object sender, RoutedEventArgs e) => SwitchFormattingMode(TextFormattingMode.Raw);

    private void OnFormattingMenuClick(object sender, RoutedEventArgs e)
    {
        FormattingMenu.PlacementTarget = BtnFormatting;
        FormattingMenu.IsOpen = true;
    }

    private async void OnCopyAllClick(object sender, RoutedEventArgs e)
    {
        var text = TxtContent.Text;
        if (!string.IsNullOrEmpty(text))
        {
            Clipboard.SetText(text);
            var originalContent = BtnCopyAll.Content;
            BtnCopyAll.Content = "已复制 ✓";
            await Task.Delay(1200);
            BtnCopyAll.Content = originalContent;
        }
    }

    private void OnTranslateClick(object sender, RoutedEventArgs e)
    {
        string textToSend;
        if (!string.IsNullOrWhiteSpace(TxtContent.SelectedText))
        {
            textToSend = TxtContent.SelectedText;
        }
        else
        {
            textToSend = TxtContent.Text;
        }
        textToSend = textToSend.Trim();
        if (string.IsNullOrEmpty(textToSend)) return;

        App.CurrentApp?.MainWindow?.SetAndTranslate(textToSend);
    }

    private void OnContinuousClick(object sender, RoutedEventArgs e)
    {
        if (BtnContinuous.IsChecked == true)
        {
            ActiveContinuousInstance = this;
            Topmost = true;
            UpdatePinButtonState();
        }
        else
        {
            if (ActiveContinuousInstance == this)
            {
                ActiveContinuousInstance = null;
            }
        }
    }

    private void OnShowImageChanged(object sender, RoutedEventArgs e)
    {
        if (ImagePreviewSection == null || ChkShowImage == null) return;

        ImagePreviewSection.Visibility = ChkShowImage.IsChecked == true
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (ImagePreviewSection.Visibility == Visibility.Visible)
        {
            ResetViewportZoomAndPan();
        }
    }

    private void OnAutoCopyNextTimeChanged(object sender, RoutedEventArgs e)
    {
        if (_configuration != null)
        {
            _configuration.OcrAutoCopyNextTime = ChkAutoCopyNextTime.IsChecked == true;
        }
    }

    private void UpdatePinButtonState()
    {
        if (BtnPin == null) return;
        if (Topmost)
        {
            BtnPin.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#0A84FF"));
            BtnPin.ToolTip = "取消置顶";
        }
        else
        {
            BtnPin.Foreground = new SolidColorBrush((Color)ColorConverter.ConvertFromString("#6B7280"));
            BtnPin.ToolTip = "置顶窗口";
        }
    }

    private void OnPinClick(object sender, RoutedEventArgs e)
    {
        Topmost = !Topmost;
        UpdatePinButtonState();
    }

    private void OnCloseClick(object sender, RoutedEventArgs e) => Close();

    private void OnContentTextChanged(object sender, TextChangedEventArgs e) => UpdateStats();

    private void OnWindowKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Close();
            e.Handled = true;
        }
        else if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            OnCopyAllClick(BtnCopyAll, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        if (ActiveContinuousInstance == this)
        {
            ActiveContinuousInstance = null;
        }
    }
}
