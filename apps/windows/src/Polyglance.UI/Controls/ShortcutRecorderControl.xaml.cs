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
        new PropertyMetadata("", (d, e) => ((ShortcutRecorderControl)d).UpdateDisplayText()));

    public string Hotkey
    {
        get => (string)GetValue(HotkeyProperty);
        set => SetValue(HotkeyProperty, value);
    }

    private bool _isRecording = false;
    private string? _hint;

    public ShortcutRecorderControl()
    {
        InitializeComponent();
        UpdateDisplayText();
    }

    private void UpdateDisplayText()
    {
        if (_isRecording)
        {
            TxtHotkey.Text = _hint ?? "请按下新快捷键…";
            TxtHotkey.Foreground = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            ContainerBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(10, 132, 255));
            ContainerBorder.Background = new SolidColorBrush(Color.FromArgb(30, 10, 132, 255));
        }
        else
        {
            TxtHotkey.Text = FormatHotkeyForDisplay(Hotkey);
            TxtHotkey.Foreground = (System.Windows.Media.Brush)FindResource("TextFillColorPrimaryBrush");
            ContainerBorder.BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235));
            ContainerBorder.Background = new SolidColorBrush(Color.FromRgb(243, 244, 246));
        }
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        // Recording starts here rather than from the focus event alone. Ending
        // a recording clears keyboard focus without moving logical focus, so
        // clicking the same box again does not necessarily raise a focus event,
        // and the control would stay deaf to every later attempt.
        Focus();
        BeginRecording();
    }

    private void OnGotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        BeginRecording();
    }

    private void OnLostKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        EndRecording();
    }

    private void BeginRecording()
    {
        if (_isRecording)
        {
            return;
        }
        _isRecording = true;
        _hint = null;
        UpdateDisplayText();
    }

    private void EndRecording()
    {
        if (!_isRecording)
        {
            return;
        }
        _isRecording = false;
        _hint = null;
        UpdateDisplayText();
    }

    private void ShowHint(string hint)
    {
        _hint = hint;
        UpdateDisplayText();
    }

    /// <summary>
    /// Recovers the physical key behind a keystroke that an input method or the
    /// Alt menu handler has already claimed.
    /// </summary>
    private static Key ResolveKey(KeyEventArgs e)
    {
        Key key = e.Key;
        if (key == Key.System)
        {
            key = e.SystemKey;
        }
        if (key == Key.ImeProcessed || key == Key.DeadCharProcessed)
        {
            key = e.ImeProcessedKey != Key.None ? e.ImeProcessedKey : e.DeadCharProcessedKey;
        }
        return key;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (!_isRecording) return;

        Key key = ResolveKey(e);

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
            EndRecording();
            Keyboard.ClearFocus();
            e.Handled = true;
            return;
        }

        if (key == Key.Back || key == Key.Delete)
        {
            Hotkey = "";
            EndRecording();
            Keyboard.ClearFocus();
            e.Handled = true;
            return;
        }

        if (key == Key.None || KeyInterop.VirtualKeyFromKey(key) == 0)
        {
            // An input method or a dead key swallowed the keystroke and left
            // nothing that can be registered globally.
            ShowHint("无法识别，请切换英文输入法");
            e.Handled = true;
            return;
        }

        // Windows treats a shortcut without Ctrl, Alt or Win as a global claim
        // on an ordinary key, which would swallow that key everywhere. Keep
        // recording rather than storing something that cannot work.
        if ((Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt | ModifierKeys.Windows)) == 0)
        {
            ShowHint("请搭配 Ctrl / Alt / Win");
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
        EndRecording();
        Keyboard.ClearFocus();
        e.Handled = true;
    }

    internal static string FormatHotkeyForDisplay(string? hotkey)
    {
        if (string.IsNullOrWhiteSpace(hotkey))
            return "未设置";

        string[] parts = hotkey.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length > 0
            && parts[^1].Length == 2
            && parts[^1][0] == 'D'
            && char.IsDigit(parts[^1][1]))
        {
            parts[^1] = parts[^1][1].ToString();
        }

        return string.Join(" + ", parts);
    }
}
