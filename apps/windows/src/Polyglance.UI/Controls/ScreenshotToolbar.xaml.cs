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

    public double CurrentStrokeSize { get; private set; } = 4;
    public Color CurrentColor { get; private set; } = Color.FromRgb(0xEF, 0x44, 0x44);

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
