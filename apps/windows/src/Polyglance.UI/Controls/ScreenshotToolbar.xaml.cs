using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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
    public bool HasTextBorder { get; private set; } = false;
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

    private DateTime _popupStrokeClosedTime = DateTime.MinValue;

    public ScreenshotToolbar()
    {
        InitializeComponent();
        PopupStrokeSlider.Closed += (s, e) => _popupStrokeClosedTime = DateTime.UtcNow;
        Mouse.AddPreviewMouseDownOutsideCapturedElementHandler(this, OnMouseDownOutsideCaptured);
    }

    private void OnMouseDownOutsideCaptured(object sender, MouseButtonEventArgs e)
    {
        Point pt = e.GetPosition(this);
        HitTestResult result = VisualTreeHelper.HitTest(this, pt);
        if (result?.VisualHit is DependencyObject hit)
        {
            var targetCmb = FindAncestor<ComboBox>(hit);
            if (targetCmb != null && targetCmb.Visibility == Visibility.Visible)
            {
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    targetCmb.IsDropDownOpen = true;
                }), System.Windows.Threading.DispatcherPriority.Input);
                return;
            }

            var targetBtn = FindAncestor<Button>(hit);
            if (targetBtn != null && targetBtn == BtnStrokeSize)
            {
                Dispatcher.BeginInvoke(new Action(() =>
                {
                    OnStrokeSizeButtonClick(BtnStrokeSize, new RoutedEventArgs());
                }), System.Windows.Threading.DispatcherPriority.Input);
                return;
            }
        }
    }

    private static T? FindAncestor<T>(DependencyObject current) where T : DependencyObject
    {
        while (current != null)
        {
            if (current is T match) return match;
            if (current is Visual || current is System.Windows.Media.Media3D.Visual3D)
                current = VisualTreeHelper.GetParent(current);
            else
                break;
        }
        return null;
    }

    private void OnToolClicked(object sender, RoutedEventArgs e)
    {
        CloseAllPopups();
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
                var activeFg = TryFindResource("ToolbarActiveBrush") as Brush ?? new SolidColorBrush(Color.FromRgb(10, 132, 255));
                var activeBg = TryFindResource("ToolbarActiveBackgroundBrush") as Brush ?? new SolidColorBrush(Color.FromArgb(31, 10, 132, 255));
                btn.Foreground = activeFg;
                btn.Background = activeBg;
                UpdateSubToolbar(tool);
                SubToolbarBorder.Visibility = Visibility.Visible;
                ToolSelected?.Invoke(tool);
            }
        }
    }

    private void SetButtonActiveState(Button? button, bool isActive)
    {
        if (button == null) return;
        var activeBg = TryFindResource("ToolbarActiveBackgroundBrush") as Brush ?? new SolidColorBrush(Color.FromArgb(31, 10, 132, 255));
        var activeFg = TryFindResource("ToolbarActiveBrush") as Brush ?? new SolidColorBrush(Color.FromRgb(10, 132, 255));
        var inactiveFg = (TryFindResource("ToolbarIconBrush") as Brush) ?? (TryFindResource("ToolbarTextBrush") as Brush) ?? new SolidColorBrush(Color.FromRgb(46, 46, 46));

        if (isActive)
        {
            button.Background = activeBg;
            button.Foreground = activeFg;
        }
        else
        {
            button.Background = Brushes.Transparent;
            button.Foreground = inactiveFg;
        }
    }

    public void UpdateSubToolButtonStates(string? currentTool = null)
    {
        SetButtonActiveState(BtnTextBold, IsBold);
        SetButtonActiveState(BtnTextItalic, IsItalic);
        SetButtonActiveState(BtnTextBorder, HasTextBorder);
        SetButtonActiveState(BtnNumberFilled, NumberStyle == 0);
        SetButtonActiveState(BtnNumberOutline, NumberStyle == 1);
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
            case "Pen":
                PanelLineControls.Visibility = Visibility.Visible;
                CmbArrowStyle.Visibility = Visibility.Collapsed;
                CmbLineDash.Visibility = Visibility.Visible;
                break;
            case "Arrow":
                PanelLineControls.Visibility = Visibility.Visible;
                CmbArrowStyle.Visibility = Visibility.Visible;
                CmbLineDash.Visibility = Visibility.Visible;
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

    public int ArrowStyle { get; private set; } = 4;
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
        if (CmbFontSize == null || CmbFontSize.Items.Count == 0) return;
        int currentIndex = CmbFontSize.SelectedIndex;
        if (currentIndex < 0)
        {
            for (int i = 0; i < CmbFontSize.Items.Count; i++)
            {
                if (CmbFontSize.Items[i] is ComboBoxItem cbi && cbi.Tag is string t && double.TryParse(t, out double s) && Math.Abs(s - FontSizeValue) < 0.5)
                {
                    currentIndex = i;
                    break;
                }
            }
            if (currentIndex < 0) currentIndex = 2; // 默认 16 pt
        }

        int dir = step > 0 ? 1 : -1;
        int newIndex = Math.Clamp(currentIndex + dir, 0, CmbFontSize.Items.Count - 1);
        CmbFontSize.SelectedIndex = newIndex;
    }

    private void OnSubToolbarMouseWheel(object sender, MouseWheelEventArgs e)
    {
        string currentTool = _selectedToolButton?.Tag as string ?? "";
        if (currentTool == "Text")
        {
            AdjustFontSize(e.Delta > 0 ? 1 : -1);
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
        if (combo == null) return;
        foreach (var item in combo.Items)
        {
            if (item is ComboBoxItem cbi && cbi.Tag is string t && t == tag)
            {
                combo.SelectedItem = cbi;
                return;
            }
        }
        if (combo == CmbFontSize && combo.Items.Count > 0)
        {
            combo.SelectedIndex = 0;
        }
    }

    private void OnFillCheckChanged(object sender, RoutedEventArgs e)
    {
        IsFilled = ChkFilled.IsChecked == true;
    }

    private void OnRectDashChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbRectDash == null) return;
        LineDashPattern = CmbRectDash.SelectedIndex;
        IsDashed = LineDashPattern != 0;
        if (CmbLineDash != null && CmbLineDash.SelectedIndex != LineDashPattern)
        {
            CmbLineDash.SelectedIndex = LineDashPattern;
        }
    }

    private void OnArrowStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbArrowStyle == null) return;
        ArrowStyle = CmbArrowStyle.SelectedIndex;
        HasArrow = true;
    }

    private void OnLineDashChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbLineDash == null) return;
        LineDashPattern = CmbLineDash.SelectedIndex;
        IsDashed = LineDashPattern != 0;
        if (CmbRectDash != null && CmbRectDash.SelectedIndex != LineDashPattern)
        {
            CmbRectDash.SelectedIndex = LineDashPattern;
        }
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

    private void OnMosaicStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (CmbMosaicStyle == null) return;
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

    public bool IsSubToolbarVisible => SubToolbarBorder != null && SubToolbarBorder.Visibility == Visibility.Visible;

    public void CloseAllPopups()
    {
        if (PopupStrokeSlider != null && PopupStrokeSlider.IsOpen)
        {
            PopupStrokeSlider.IsOpen = false;
        }
        CloseOtherComboBoxes(null);
    }

    private void CloseOtherComboBoxes(ComboBox? keepOpen)
    {
        if (CmbRectDash != null && CmbRectDash != keepOpen && CmbRectDash.IsDropDownOpen)
            CmbRectDash.IsDropDownOpen = false;
        if (CmbArrowStyle != null && CmbArrowStyle != keepOpen && CmbArrowStyle.IsDropDownOpen)
            CmbArrowStyle.IsDropDownOpen = false;
        if (CmbLineDash != null && CmbLineDash != keepOpen && CmbLineDash.IsDropDownOpen)
            CmbLineDash.IsDropDownOpen = false;
        if (CmbFontFamily != null && CmbFontFamily != keepOpen && CmbFontFamily.IsDropDownOpen)
            CmbFontFamily.IsDropDownOpen = false;
        if (CmbFontSize != null && CmbFontSize != keepOpen && CmbFontSize.IsDropDownOpen)
            CmbFontSize.IsDropDownOpen = false;
        if (CmbMosaicStyle != null && CmbMosaicStyle != keepOpen && CmbMosaicStyle.IsDropDownOpen)
            CmbMosaicStyle.IsDropDownOpen = false;
    }

    private void OnComboBoxDropDownOpened(object sender, EventArgs e)
    {
        if (sender is ComboBox activeCmb)
        {
            if (PopupStrokeSlider != null && PopupStrokeSlider.IsOpen)
            {
                PopupStrokeSlider.IsOpen = false;
            }

            CloseOtherComboBoxes(activeCmb);
        }
    }

    private void OnStrokeSizeButtonClick(object sender, RoutedEventArgs e)
    {
        if (PopupStrokeSlider.IsOpen)
        {
            PopupStrokeSlider.IsOpen = false;
            return;
        }

        CloseOtherComboBoxes(null);

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
                case "TextBorder":
                    HasTextBorder = !HasTextBorder;
                    break;
                case "NumberFilled":
                    NumberStyle = 0;
                    break;
                case "NumberOutline":
                    NumberStyle = 1;
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
        CloseAllPopups();
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

    public static readonly DependencyProperty PopupPlacementProperty =
        DependencyProperty.Register(nameof(PopupPlacement), typeof(PlacementMode), typeof(ScreenshotToolbar),
            new PropertyMetadata(PlacementMode.Bottom));

    public PlacementMode PopupPlacement
    {
        get => (PlacementMode)GetValue(PopupPlacementProperty);
        set => SetValue(PopupPlacementProperty, value);
    }

    private bool _isSubToolbarAbove;
    public bool IsSubToolbarAbove => _isSubToolbarAbove;

    public double SubToolbarOccupiedHeight
    {
        get
        {
            if (SubToolbarBorder.Visibility != Visibility.Visible)
                return 0;
            SubToolbarBorder.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return SubToolbarBorder.DesiredSize.Height;
        }
    }

    public double MainToolbarHeight
    {
        get
        {
            MainToolbarBorder.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return MainToolbarBorder.DesiredSize.Height;
        }
    }

    public double MainToolbarWidth
    {
        get
        {
            MainToolbarBorder.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return MainToolbarBorder.DesiredSize.Width;
        }
    }

    public void SetSubToolbarAbove(bool above)
    {
        SetSubToolbarLayout(above, above ? PlacementMode.Top : PlacementMode.Bottom);
    }

    public void SetSubToolbarLayout(bool subToolbarAbove, PlacementMode popupPlacement)
    {
        PopupPlacement = popupPlacement;

        if (_isSubToolbarAbove == subToolbarAbove && ToolbarContainer.Children.Count == 2 &&
            ((subToolbarAbove && ToolbarContainer.Children[0] == SubToolbarBorder) || (!subToolbarAbove && ToolbarContainer.Children[0] == MainToolbarBorder)))
        {
            return;
        }

        _isSubToolbarAbove = subToolbarAbove;

        ToolbarContainer.Children.Clear();
        if (subToolbarAbove)
        {
            SubToolbarBorder.Margin = new Thickness(0, 0, 0, 6);
            ToolbarContainer.Children.Add(SubToolbarBorder);
            ToolbarContainer.Children.Add(MainToolbarBorder);
        }
        else
        {
            SubToolbarBorder.Margin = new Thickness(0, 6, 0, 0);
            ToolbarContainer.Children.Add(MainToolbarBorder);
            ToolbarContainer.Children.Add(SubToolbarBorder);
        }
    }

    public event Action<double, double>? ToolbarDragDelta;

    private Point _toolbarDragStartScreen;
    private bool _isDraggingToolbar;

    private void OnMainToolbarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed &&
            (e.OriginalSource == MainToolbarBorder ||
             e.OriginalSource is Border ||
             e.OriginalSource is StackPanel ||
             e.OriginalSource is Rectangle))
        {
            _isDraggingToolbar = true;
            _toolbarDragStartScreen = PointToScreen(e.GetPosition(this));
            MainToolbarBorder.CaptureMouse();
            e.Handled = true;
        }
    }

    private void OnMainToolbarMouseMove(object sender, MouseEventArgs e)
    {
        if (_isDraggingToolbar && e.LeftButton == MouseButtonState.Pressed)
        {
            Point currentScreen = PointToScreen(e.GetPosition(this));
            double deltaX = currentScreen.X - _toolbarDragStartScreen.X;
            double deltaY = currentScreen.Y - _toolbarDragStartScreen.Y;
            if (Math.Abs(deltaX) > 0.1 || Math.Abs(deltaY) > 0.1)
            {
                _toolbarDragStartScreen = currentScreen;
                ToolbarDragDelta?.Invoke(deltaX, deltaY);
            }
        }
    }

    private void OnMainToolbarMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_isDraggingToolbar)
        {
            _isDraggingToolbar = false;
            MainToolbarBorder.ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    private static void ClearSelectedAppearance(Button button)
    {
        button.ClearValue(ForegroundProperty);
        button.ClearValue(BackgroundProperty);
    }
}
