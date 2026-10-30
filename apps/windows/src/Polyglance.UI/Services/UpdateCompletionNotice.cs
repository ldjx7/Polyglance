using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Polyglance.Platform.Update;
using CheckBox = System.Windows.Controls.CheckBox;
using HorizontalAlignment = System.Windows.HorizontalAlignment;

namespace Polyglance.UI.Services;

internal static class UpdateCompletionNotice
{
    private sealed class NoticeState
    {
        public string BuildVersion { get; set; } = "";
        public bool SuppressNotice { get; set; }
    }

    private static string StatePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Polyglance", "update-state.json");

    internal static void ShowIfNeeded()
    {
        NoticeState state;
        try { state = JsonSerializer.Deserialize<NoticeState>(File.ReadAllText(StatePath)) ?? new(); }
        catch { state = new(); }
        bool upgraded = Version.TryParse(state.BuildVersion, out var previous)
            && AppUpdater.CurrentVersion > previous;
        state.BuildVersion = AppUpdater.CurrentVersion.ToString();
        Save(state);
        if (!upgraded || state.SuppressNotice) return;

        string version = AppUpdater.CurrentSemanticVersion;
        var window = new Window
        {
            Title = "Polyglance 升级成功",
            Width = 380,
            SizeToContent = SizeToContent.Height,
            ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ShowInTaskbar = false,
            ShowActivated = false
        };
        window.SetResourceReference(Window.BackgroundProperty, "ApplicationBackgroundBrush");
        window.SetResourceReference(Window.ForegroundProperty, "TextFillColorPrimaryBrush");
        var content = new StackPanel { Margin = new Thickness(20) };
        content.Children.Add(new TextBlock
        {
            Text = $"Polyglance 已成功升级至 {version}",
            FontSize = 16,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 22)
        });
        var controls = new DockPanel();
        var suppress = new CheckBox { Content = "不再提示", VerticalAlignment = VerticalAlignment.Center };
        controls.Children.Add(suppress);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        var details = new Wpf.Ui.Controls.Button { Content = "更新详情", Appearance = Wpf.Ui.Controls.ControlAppearance.Primary, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 8, 0) };
        details.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo(
                    "https://github.com/ldjx7/Polyglance/releases/tag/" + Uri.EscapeDataString("v" + version)) { UseShellExecute = true });
            }
            catch (Exception error) { Debug.WriteLine(error.Message); }
            window.Close();
        };
        var close = new Wpf.Ui.Controls.Button { Content = "关闭", Padding = new Thickness(14, 6, 14, 6) };
        close.Click += (_, _) => window.Close();
        window.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Escape) return;
            window.Close();
            e.Handled = true;
        };
        buttons.Children.Add(details);
        buttons.Children.Add(close);
        controls.Children.Add(buttons);
        content.Children.Add(controls);
        window.Content = content;
        window.Closed += (_, _) => { state.SuppressNotice = suppress.IsChecked == true; Save(state); };
        window.Show();
    }

    private static void Save(NoticeState state)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!);
            File.WriteAllText(StatePath + ".tmp", JsonSerializer.Serialize(state));
            File.Move(StatePath + ".tmp", StatePath, true);
        }
        catch (Exception error) { Debug.WriteLine($"Unable to save update notice state: {error.Message}"); }
    }
}
