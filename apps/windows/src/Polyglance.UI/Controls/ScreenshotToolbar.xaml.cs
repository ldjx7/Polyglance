using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Polyglance.Core.Models;
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
    private bool _isPinAnnotationMode;

    private readonly Dictionary<string, Button> _buttonMap = new();
    private readonly HashSet<string> _actionIds = new(StringComparer.OrdinalIgnoreCase)
    {
        "ocr", "translate", "barcode", "pin", "longScreenshot", "screenRecording", "save", "cancel", "copy"
    };
    private List<ScreenshotToolbarItemConfig> _configuredItems = ScreenshotToolbarItemConfig.DefaultItems();

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
    internal bool IsOcrTranslationBusy { get; private set; }

    internal void SetOcrTranslationBusy(bool isBusy)
    {
        IsOcrTranslationBusy = isBusy;
        BtnTranslate.IsEnabled = !isBusy;
        BtnTranslate.ToolTip = isBusy ? "正在识别并翻译…" : "识别并翻译";
        BtnTranslate.Cursor = isBusy ? Cursors.Wait : null;
    }

    private DateTime _popupStrokeClosedTime = DateTime.MinValue;

    public ScreenshotToolbar()
    {
        InitializeComponent();
        InitializeButtonMap();
        RebuildToolbarLayout();
        PopupStrokeSlider.Closed += (s, e) => _popupStrokeClosedTime = DateTime.UtcNow;
        Mouse.AddPreviewMouseDownOutsideCapturedElementHandler(this, OnMouseDownOutsideCaptured);
    }

    private void InitializeButtonMap()
    {
        _buttonMap["pen"] = BtnPen;
        _buttonMap["rect"] = BtnRect;
        _buttonMap["ellipse"] = BtnEllipse;
        _buttonMap["line"] = BtnLine;
        _buttonMap["arrow"] = BtnArrow;
        _buttonMap["text"] = BtnText;
        _buttonMap["mosaic"] = BtnMosaic;
        _buttonMap["number"] = BtnNumber;
        _buttonMap["undo"] = BtnUndo;
        _buttonMap["redo"] = BtnRedo;
        _buttonMap["ocr"] = BtnOCR;
        _buttonMap["translate"] = BtnTranslate;
        _buttonMap["barcode"] = BtnBarcode;
        _buttonMap["pin"] = BtnPin;
        _buttonMap["longScreenshot"] = BtnLongScreenshot;
        _buttonMap["screenRecording"] = BtnScreenRecording;
        _buttonMap["save"] = BtnSave;
        _buttonMap["cancel"] = BtnCancel;
        _buttonMap["copy"] = BtnCopy;
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

    public void ApplyItemsConfiguration(List<ScreenshotToolbarItemConfig>? items)
    {
        _configuredItems = ScreenshotToolbarItemConfig.Normalize(items);
        RebuildToolbarLayout();
    }

    private List<Button> GetVisibleButtons()
    {
        var effectiveConfigs = _configuredItems.Where(i => i.IsVisible).ToList();
        if (effectiveConfigs.Count == 0)
        {
            effectiveConfigs = ScreenshotToolbarItemConfig.DefaultItems();
        }

        var visibleButtons = new List<Button>();
        bool finishAdded = false;

        foreach (var item in effectiveConfigs)
        {
            if (_buttonMap.TryGetValue(item.Id, out var btn))
            {
                if (_isPinAnnotationMode && _actionIds.Contains(item.Id))
                {
                    continue;
                }
                visibleButtons.Add(btn);

                if (_isPinAnnotationMode && !finishAdded && (item.Id == "redo" || item.Id == "undo"))
                {
                    visibleButtons.Add(BtnFinish);
                    finishAdded = true;
                }
            }
        }

        if (_isPinAnnotationMode && !finishAdded)
        {
            visibleButtons.Add(BtnFinish);
        }

        return visibleButtons;
    }

    private static void DetachFromParent(UIElement element)
    {
        if (element is FrameworkElement fe && fe.Parent is System.Windows.Controls.Panel parent)
        {
            parent.Children.Remove(element);
        }
    }

    private void RebuildToolbarLayout()
    {
        var visibleButtons = GetVisibleButtons();

        foreach (var kv in _buttonMap)
        {
            kv.Value.Visibility = visibleButtons.Contains(kv.Value) ? Visibility.Visible : Visibility.Collapsed;
        }
        BtnFinish.Visibility = _isPinAnnotationMode ? Visibility.Visible : Visibility.Collapsed;

        foreach (var btn in _buttonMap.Values)
        {
            DetachFromParent(btn);
        }
        DetachFromParent(BtnFinish);

        ToolRow.Children.Clear();
        ActionRow.Children.Clear();
        ToolbarRows.Children.Clear();

        if (_isCompactLayout)
        {
            ToolbarRows.Orientation = Orientation.Vertical;
            MainToolbarBorder.CornerRadius = new CornerRadius(12);

            int mid = (visibleButtons.Count + 1) / 2;
            for (int i = 0; i < mid; i++)
            {
                ToolRow.Children.Add(visibleButtons[i]);
            }
            for (int i = mid; i < visibleButtons.Count; i++)
            {
                ActionRow.Children.Add(visibleButtons[i]);
            }

            ToolRow.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            ActionRow.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;

            ToolbarRows.Children.Add(ToolRow);
            if (ActionRow.Children.Count > 0)
            {
                ToolbarRows.Children.Add(ActionRow);
            }
        }
        else
        {
            ToolbarRows.Orientation = Orientation.Horizontal;
            MainToolbarBorder.CornerRadius = new CornerRadius(22);

            foreach (var btn in visibleButtons)
            {
                ToolRow.Children.Add(btn);
            }

            ToolRow.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
            ToolbarRows.Children.Add(ToolRow);
        }
    }

    public void SetAnnotationMode(bool enabled)
    {
        _isAnnotationMode = enabled;
        _isPinAnnotationMode = false;
        RebuildToolbarLayout();
        if (!enabled)
        {
            SubToolbarBorder.Visibility = Visibility.Collapsed;
        }
    }

    public void SetPinAnnotationMode(bool enabled)
    {
        _isAnnotationMode = enabled;
        _isPinAnnotationMode = enabled;
        RebuildToolbarLayout();
        if (!enabled)
        {
            SubToolbarBorder.Visibility = Visibility.Collapsed;
        }
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
        RebuildToolbarLayout();
    }

    public double PreferredToolbarWidth
    {
        get
        {
            int count = Math.Max(1, GetVisibleButtons().Count);
            return 22 + count * 40;
        }
    }

    public bool ShouldUseCompact(double availableWidth)
    {
        int count = GetVisibleButtons().Count;
        if (count >= 18)
            return availableWidth < 700;
        return availableWidth < PreferredToolbarWidth + 16;
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

    private Point _toolbarDragStartPosition;
    private bool _isDraggingToolbar;

    internal static Vector CalculateDragDelta(Point startPosition, Point currentPosition) =>
        currentPosition - startPosition;

    private IInputElement DragCoordinateRoot() =>
        Window.GetWindow(this) is { } owner ? owner : this;

    private void OnMainToolbarMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed &&
            (e.OriginalSource == MainToolbarBorder ||
             e.OriginalSource is Border ||
             e.OriginalSource is StackPanel ||
             e.OriginalSource is Rectangle))
        {
            _isDraggingToolbar = true;
            // Canvas coordinates are WPF device-independent units. Keeping the
            // drag points in the fixed overlay-window space avoids treating
            // physical pixels as DIPs after crossing to a display with a
            // different scale factor.
            _toolbarDragStartPosition = e.GetPosition(DragCoordinateRoot());
            MainToolbarBorder.CaptureMouse();
            e.Handled = true;
        }
    }

    private void OnMainToolbarMouseMove(object sender, MouseEventArgs e)
    {
        if (_isDraggingToolbar && e.LeftButton == MouseButtonState.Pressed)
        {
            Point currentPosition = e.GetPosition(DragCoordinateRoot());
            Vector delta = CalculateDragDelta(_toolbarDragStartPosition, currentPosition);
            if (Math.Abs(delta.X) > 0.1 || Math.Abs(delta.Y) > 0.1)
            {
                _toolbarDragStartPosition = currentPosition;
                ToolbarDragDelta?.Invoke(delta.X, delta.Y);
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
