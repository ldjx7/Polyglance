using System;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Polyglance.UI.Controls;

public partial class ShortcutRecorderControl : UserControl
{
    public static readonly DependencyProperty HotkeyProperty = DependencyProperty.Register(
        nameof(Hotkey), typeof(string), typeof(ShortcutRecorderControl),
        new PropertyMetadata("Alt+A", (d, e) => ((ShortcutRecorderControl)d).UpdateDisplayText()));

    public string Hotkey
    {
        get => (string)GetValue(HotkeyProperty);
        set => SetValue(HotkeyProperty, value);
    }

    private bool _isRecording = false;

    public ShortcutRecorderControl()
    {
        InitializeComponent();
        UpdateDisplayText();
    }

    private void UpdateDisplayText()
    {
        if (_isRecording)
        {
            TxtHotkey.Text = "请按下新快捷键…";
            TxtHotkey.Foreground = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            ContainerBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            ContainerBorder.Background = new SolidColorBrush(Color.FromArgb(30, 10, 132, 255));
        }
        else
        {
            TxtHotkey.Text = string.IsNullOrWhiteSpace(Hotkey) ? "无" : Hotkey.Replace("+", " + ");
            TxtHotkey.Foreground = (System.Windows.Media.Brush)FindResource("TextFillColorPrimaryBrush");
            ContainerBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235));
            ContainerBorder.Background = new SolidColorBrush(Color.FromRgb(243, 244, 246));
        }
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        Focus();
    }

    private void OnGotFocus(object sender, RoutedEventArgs e)
    {
        _isRecording = true;
        UpdateDisplayText();
    }

    private void OnLostFocus(object sender, RoutedEventArgs e)
    {
        _isRecording = false;
        UpdateDisplayText();
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_isRecording) return;

        Key key = e.Key == Key.System ? e.SystemKey : e.Key;

        // Ignore standalone modifiers
        if (key == Key.LeftCtrl || key == Key.RightCtrl ||
            key == Key.LeftAlt || key == Key.RightAlt ||
            key == Key.LeftShift || key == Key.RightShift ||
            key == Key.LWin || key == Key.RWin)
        {
            return;
        }

        if (key == Key.Escape)
        {
            _isRecording = false;
            Keyboard.ClearFocus();
            UpdateDisplayText();
            e.Handled = true;
            return;
        }

        var sb = new StringBuilder();
        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
            sb.Append("Ctrl+");
        if ((Keyboard.Modifiers & ModifierKeys.Alt) == ModifierKeys.Alt)
            sb.Append("Alt+");
        if ((Keyboard.Modifiers & ModifierKeys.Shift) == ModifierKeys.Shift)
            sb.Append("Shift+");
        if ((Keyboard.Modifiers & ModifierKeys.Windows) == ModifierKeys.Windows)
            sb.Append("Win+");

        sb.Append(key.ToString());

        Hotkey = sb.ToString();
        _isRecording = false;
        Keyboard.ClearFocus();
        UpdateDisplayText();
        e.Handled = true;
    }
}
