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
                SubToolbarBorder.Visibility = Visibility.Visible;
                ToolSelected?.Invoke(tool);
            }
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
