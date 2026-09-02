using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Polyglance.UI.Controls;

public partial class ScreenshotToolbar : UserControl
{
    public event Action<string>? ToolSelected;
    public event Action<string>? ActionTriggered;
    public event Action<double>? StrokeSizeChanged;
    public event Action<Color>? ColorChanged;

    private Button? _selectedToolButton;
    private bool _isCompactLayout;
    private bool _isAnnotationMode;

    public double CurrentStrokeSize { get; private set; } = 4;
    public Color CurrentColor { get; private set; } = Color.FromRgb(0xEF, 0x44, 0x44);
    public bool IsFilled { get; private set; } = false;
    public bool IsDashed { get; private set; } = false;
    public bool HasArrow { get; private set; } = false;
    public bool IsBold { get; private set; } = false;
    public bool IsItalic { get; private set; } = false;
    public double FontSizeValue { get; private set; } = 16;
    public int NumberStyle { get; private set; } = 0;
    public int MosaicShapeType { get; private set; } = 0;
    public bool MosaicIsBlur { get; private set; } = false;

    public event Action<string>? SubToolActionTriggered;

    internal bool AreScreenshotActionsVisible =>
        BtnOCR.Visibility == Visibility.Visible &&
        BtnTranslate.Visibility == Visibility.Visible &&
        BtnBarcode.Visibility == Visibility.Visible &&
        BtnLongScreenshot.Visibility == Visibility.Visible &&
        BtnScreenRecording.Visibility == Visibility.Visible &&
        BtnPin.Visibility == Visibility.Visible &&
        BtnSave.Visibility == Visibility.Visible &&
        BtnCancel.Visibility == Visibility.Visible &&
        BtnCopy.Visibility == Visibility.Visible;
    internal bool IsFinishActionVisible => BtnFinish.Visibility == Visibility.Visible;

    public ScreenshotToolbar()
    {
        InitializeComponent();
    }

    private void OnToolClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string tool)
        {
            if (_selectedToolButton != null)
            {
                ClearSelectedAppearance(_selectedToolButton);
            }

            if (_selectedToolButton == btn)
            {
                _selectedToolButton = null;
                SubToolbarBorder.Visibility = Visibility.Collapsed;
                ToolSelected?.Invoke("None");
            }
            else
            {
                _selectedToolButton = btn;
                btn.Foreground = (System.Windows.Media.Brush)FindResource("ToolbarActiveBrush");
                btn.Background = (System.Windows.Media.Brush)FindResource("ToolbarActiveBackgroundBrush");
                UpdateSubToolbar(tool);
                SubToolbarBorder.Visibility = Visibility.Visible;
                ToolSelected?.Invoke(tool);
            }
        }
    }

    private void SetButtonActiveState(Button? button, bool isActive)
    {
        if (button == null) return;
        if (isActive)
        {
            button.Background = (System.Windows.Media.Brush)FindResource("ToolbarActiveBackgroundBrush");
            button.Foreground = (System.Windows.Media.Brush)FindResource("ToolbarActiveBrush");
        }
        else
        {
            button.Background = System.Windows.Media.Brushes.Transparent;
            button.Foreground = (System.Windows.Media.Brush)FindResource("ToolbarTextBrush");
        }
    }

    public void UpdateSubToolButtonStates(string? currentTool = null)
    {
        currentTool ??= _selectedToolButton?.Tag as string ?? "";

        // Rect / Ellipse
        SetButtonActiveState(BtnShapeRect, currentTool == "Rect");
        SetButtonActiveState(BtnShapeEllipse, currentTool == "Ellipse");
        SetButtonActiveState(BtnToggleFill, IsFilled);
        SetButtonActiveState(BtnToggleDash, IsDashed);

        // Line / Arrow
        SetButtonActiveState(BtnLineStraight, !HasArrow && (currentTool == "Line" || currentTool == "Straight"));
        SetButtonActiveState(BtnLineArrow, HasArrow || currentTool == "Arrow");
        SetButtonActiveState(BtnLineDash, IsDashed);

        // Text
        SetButtonActiveState(BtnTextBold, IsBold);
        SetButtonActiveState(BtnTextItalic, IsItalic);

        // Number
        SetButtonActiveState(BtnNumFilled, NumberStyle == 0);
        SetButtonActiveState(BtnNumOutline, NumberStyle == 1);

        // Mosaic
        SetButtonActiveState(BtnMosaicBrush, MosaicShapeType == 0);
        SetButtonActiveState(BtnMosaicRect, MosaicShapeType == 1);
        SetButtonActiveState(BtnMosaicPixel, !MosaicIsBlur);
        SetButtonActiveState(BtnMosaicBlur, MosaicIsBlur);
    }

    private void UpdateSubToolbar(string tool)
    {
        PanelRectControls.Visibility = Visibility.Collapsed;
        PanelLineControls.Visibility = Visibility.Collapsed;
        PanelTextControls.Visibility = Visibility.Collapsed;
        PanelNumberControls.Visibility = Visibility.Collapsed;
        PanelMosaicControls.Visibility = Visibility.Collapsed;
        PanelColorPalette.Visibility = Visibility.Visible;

        switch (tool)
        {
            case "Rect":
            case "Ellipse":
                PanelRectControls.Visibility = Visibility.Visible;
                break;
            case "Line":
            case "Arrow":
                PanelLineControls.Visibility = Visibility.Visible;
                break;
            case "Text":
                PanelTextControls.Visibility = Visibility.Visible;
                break;
            case "Number":
                PanelNumberControls.Visibility = Visibility.Visible;
                break;
            case "Mosaic":
                PanelMosaicControls.Visibility = Visibility.Visible;
                PanelColorPalette.Visibility = Visibility.Collapsed;
                break;
        }

        UpdateSubToolButtonStates(tool);
    }

    private void OnSubToolActionClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string action)
        {
            switch (action)
            {
                case "ShapeRect":
                    OnToolClicked(BtnRect, e);
                    break;
                case "ShapeEllipse":
                    OnToolClicked(BtnEllipse, e);
                    break;
                case "ToggleFill":
                    IsFilled = !IsFilled;
                    break;
                case "ToggleDash":
                    IsDashed = !IsDashed;
                    break;
                case "LineStraight":
                    HasArrow = false;
                    OnToolClicked(BtnLine, e);
                    break;
                case "LineArrow":
                    HasArrow = true;
                    OnToolClicked(BtnArrow, e);
                    break;
                case "TextBold":
                    IsBold = !IsBold;
                    break;
                case "TextItalic":
                    IsItalic = !IsItalic;
                    break;
                case "NumFilled":
                    NumberStyle = 0;
                    break;
                case "NumOutline":
                    NumberStyle = 1;
                    break;
                case "MosaicBrush":
                    MosaicShapeType = 0;
                    break;
                case "MosaicRect":
                    MosaicShapeType = 1;
                    break;
                case "MosaicPixel":
                    MosaicIsBlur = false;
                    break;
                case "MosaicBlur":
                    MosaicIsBlur = true;
                    break;
            }
            UpdateSubToolButtonStates();
            SubToolActionTriggered?.Invoke(action);
        }
    }

    private void OnFontSizeChecked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton rb && rb.Tag is string sizeStr && double.TryParse(sizeStr, out double size))
        {
            FontSizeValue = size;
        }
    }

    private void OnActionClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string action)
        {
            ActionTriggered?.Invoke(action);
        }
    }

    private void OnStrokeSizeChecked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton rb && rb.Tag is string sizeStr && double.TryParse(sizeStr, out double size))
        {
            CurrentStrokeSize = size;
            StrokeSizeChanged?.Invoke(size);
        }
    }

    private void OnColorChecked(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton rb && rb.Tag is string hex)
        {
            try
            {
                var color = (Color)ColorConverter.ConvertFromString(hex);
                CurrentColor = color;
                ColorChanged?.Invoke(color);
            }
            catch
            {
                // Ignore invalid hex
            }
        }
    }

    public void SetUndoRedoState(bool canUndo, bool canRedo)
    {
        BtnUndo.IsEnabled = canUndo;
        BtnRedo.IsEnabled = canRedo;
    }

    public void SetAnnotationMode(bool enabled)
    {
        _isAnnotationMode = enabled;
        // Selecting a markup tool must not reshape the screenshot toolbar. This
        // mirrors macOS: the active tool is highlighted in place and every
        // screenshot action stays at the same position.
        SetScreenshotActionVisibility(Visibility.Visible);
        BtnFinish.Visibility = Visibility.Collapsed;
        if (!enabled)
        {
            SubToolbarBorder.Visibility = Visibility.Collapsed;
        }
    }

    public void SetPinAnnotationMode(bool enabled)
    {
        _isAnnotationMode = enabled;
        BtnFinish.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        SetScreenshotActionVisibility(enabled ? Visibility.Collapsed : Visibility.Visible);
        if (!enabled)
            SubToolbarBorder.Visibility = Visibility.Collapsed;
    }

    private void SetScreenshotActionVisibility(Visibility visibility)
    {
        BtnOCR.Visibility = visibility;
        BtnTranslate.Visibility = visibility;
        BtnBarcode.Visibility = visibility;
        BtnLongScreenshot.Visibility = visibility;
        BtnScreenRecording.Visibility = visibility;
        BtnPin.Visibility = visibility;
        BtnSave.Visibility = visibility;
        BtnCancel.Visibility = visibility;
        BtnCopy.Visibility = visibility;
    }

    public void ClearSelectedTool()
    {
        if (_selectedToolButton is not null)
        {
            ClearSelectedAppearance(_selectedToolButton);
            _selectedToolButton = null;
        }
        SubToolbarBorder.Visibility = Visibility.Collapsed;
    }

    public void SetCompactLayout(bool compact)
    {
        if (_isCompactLayout == compact)
        {
            return;
        }

        _isCompactLayout = compact;
        ToolbarRows.Orientation = compact ? Orientation.Vertical : Orientation.Horizontal;
        MainToolbarBorder.CornerRadius = compact ? new CornerRadius(12) : new CornerRadius(22);

        ToolRow.HorizontalAlignment = compact
            ? System.Windows.HorizontalAlignment.Left
            : System.Windows.HorizontalAlignment.Center;
        ActionRow.HorizontalAlignment = compact
            ? System.Windows.HorizontalAlignment.Left
            : System.Windows.HorizontalAlignment.Center;
    }

    private static void ClearSelectedAppearance(Button button)
    {
        button.ClearValue(ForegroundProperty);
        button.ClearValue(BackgroundProperty);
    }
}
