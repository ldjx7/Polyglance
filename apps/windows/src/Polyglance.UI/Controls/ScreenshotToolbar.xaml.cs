using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;

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
    public string CurrentFontFamily { get; private set; } = "";
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
        SetButtonActiveState(BtnTextBold, IsBold);
        SetButtonActiveState(BtnTextItalic, IsItalic);
    }

    private void UpdateSubToolbar(string tool)
    {
        PanelRectControls.Visibility = Visibility.Collapsed;
        PanelLineControls.Visibility = Visibility.Collapsed;
        PanelTextControls.Visibility = Visibility.Collapsed;
        PanelNumberControls.Visibility = Visibility.Collapsed;
        PanelMosaicControls.Visibility = Visibility.Collapsed;
        PanelStrokeSizes.Visibility = Visibility.Visible;
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
                PanelStrokeSizes.Visibility = Visibility.Collapsed;
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

    public int ArrowStyle { get; private set; } = 0;
    public int LineDashPattern { get; private set; } = 0;

    public DoubleCollection? CurrentDashArray => LineDashPattern switch
    {
        1 => new DoubleCollection { 4, 2 },
        2 => new DoubleCollection { 1, 2 },
        3 => new DoubleCollection { 6, 2, 1, 2 },
        _ => null
    };

    public void AdjustStrokeSize(int step)
    {
        double newSize = Math.Clamp(CurrentStrokeSize + step, 1, 50);
        if (Math.Abs(newSize - CurrentStrokeSize) > 0.1)
        {
            CurrentStrokeSize = newSize;
            if (TxtStrokeSize != null)
                TxtStrokeSize.Text = ((int)newSize).ToString();
            if (SliderStrokeSize != null)
                SliderStrokeSize.Value = newSize;
            if (TxtSliderStrokeVal != null)
                TxtSliderStrokeVal.Text = $"{(int)newSize} px";
            StrokeSizeChanged?.Invoke(newSize);
        }
    }

    public void AdjustFontSize(int step)
    {
        double newSize = Math.Clamp(FontSizeValue + step, 8, 96);
        if (Math.Abs(newSize - FontSizeValue) > 0.1)
        {
            FontSizeValue = newSize;
            SelectComboItemByTag(CmbFontSize, ((int)newSize).ToString());
        }
    }

    private void OnSubToolbarMouseWheel(object sender, MouseWheelEventArgs e)
    {
        string currentTool = _selectedToolButton?.Tag as string ?? "";
        if (currentTool == "Text")
        {
            AdjustFontSize(e.Delta > 0 ? 2 : -2);
            e.Handled = true;
        }
        else
        {
            AdjustStrokeSize(e.Delta > 0 ? 1 : -1);
            e.Handled = true;
        }
    }

    private void SelectComboItemByTag(ComboBox combo, string tag)
    {
        foreach (var item in combo.Items)
        {
            if (item is ComboBoxItem cbi && cbi.Tag is string t && t == tag)
            {
                combo.SelectedItem = cbi;
                return;
            }
        }
        if (combo == CmbFontSize)
        {
            combo.Text = $"{tag} pt";
        }
    }

    private void OnFillCheckChanged(object sender, RoutedEventArgs e)
    {
        IsFilled = ChkFilled.IsChecked == true;
    }

    private void OnRectDashChanged(object sender, SelectionChangedEventArgs e)
    {
        LineDashPattern = CmbRectDash.SelectedIndex;
        IsDashed = LineDashPattern != 0;
    }

    private void OnArrowStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        ArrowStyle = CmbArrowStyle.SelectedIndex;
        HasArrow = ArrowStyle != 8;
    }

    private void OnLineDashChanged(object sender, SelectionChangedEventArgs e)
    {
        LineDashPattern = CmbLineDash.SelectedIndex;
        IsDashed = LineDashPattern != 0;
    }

    private void OnFontFamilyChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbFontFamily.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            CurrentFontFamily = tag;
        }
    }

    private void OnFontSizeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbFontSize.SelectedItem is ComboBoxItem item && item.Tag is string tag && double.TryParse(tag, out double size))
        {
            FontSizeValue = size;
        }
    }

    private void OnNumberStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        NumberStyle = CmbNumberStyle.SelectedIndex;
    }

    private void OnMosaicStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        switch (CmbMosaicStyle.SelectedIndex)
        {
            case 0: // 涂抹像素
                MosaicShapeType = 0;
                MosaicIsBlur = false;
                break;
            case 1: // 涂抹模糊
                MosaicShapeType = 0;
                MosaicIsBlur = true;
                break;
            case 2: // 矩形像素
                MosaicShapeType = 1;
                MosaicIsBlur = false;
                break;
            case 3: // 矩形模糊
                MosaicShapeType = 1;
                MosaicIsBlur = true;
                break;
        }
    }

    private void OnStrokeSizeButtonClick(object sender, RoutedEventArgs e)
    {
        if (SliderStrokeSize != null)
            SliderStrokeSize.Value = CurrentStrokeSize;
        if (TxtSliderStrokeVal != null)
            TxtSliderStrokeVal.Text = $"{(int)CurrentStrokeSize} px";
        PopupStrokeSlider.IsOpen = true;
    }

    private void OnStrokeSliderValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (TxtSliderStrokeVal == null || TxtStrokeSize == null) return;
        double newSize = Math.Round(e.NewValue);
        if (Math.Abs(newSize - CurrentStrokeSize) > 0.1)
        {
            CurrentStrokeSize = newSize;
            TxtStrokeSize.Text = ((int)newSize).ToString();
            TxtSliderStrokeVal.Text = $"{(int)newSize} px";
            StrokeSizeChanged?.Invoke(newSize);
        }
    }

    private void OnSubToolActionClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string action)
        {
            switch (action)
            {
                case "TextBold":
                    IsBold = !IsBold;
                    break;
                case "TextItalic":
                    IsItalic = !IsItalic;
                    break;
            }
            UpdateSubToolButtonStates();
            SubToolActionTriggered?.Invoke(action);
        }
    }

    private void OnActionClicked(object sender, RoutedEventArgs e)
    {
        if (sender is Button btn && btn.Tag is string action)
        {
            ActionTriggered?.Invoke(action);
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
