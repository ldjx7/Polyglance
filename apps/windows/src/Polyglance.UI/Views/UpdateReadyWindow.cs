using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;

namespace Polyglance.UI.Views;

internal sealed class UpdateReadyWindow : Window
{
    internal string Version { get; }

    internal UpdateReadyWindow(string version, Func<Task> install)
    {
        Version = version;
        Title = "Polyglance 更新已就绪";
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        ShowActivated = false;
        SetResourceReference(BackgroundProperty, "ApplicationBackgroundBrush");
        SetResourceReference(ForegroundProperty, "TextFillColorPrimaryBrush");
        var content = new StackPanel { Margin = new Thickness(20) };
        var message = new TextBlock
        {
            Text = $"版本 {version} 已下载并校验完成。",
            TextWrapping = TextWrapping.Wrap,
            FontSize = 15,
            Margin = new Thickness(0, 0, 0, 20)
        };
        content.Children.Add(message);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var details = new Wpf.Ui.Controls.Button { Content = "更新详情", Margin = new Thickness(0, 0, 8, 0) };
        details.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo("https://github.com/ldjx7/Polyglance/releases/tag/" + Uri.EscapeDataString("v" + version)) { UseShellExecute = true }); }
            catch (Exception error) { Debug.WriteLine(error.Message); }
        };
        var later = new Wpf.Ui.Controls.Button { Content = "下次启动安装", IsDefault = true, IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        later.Click += (_, _) => Close();
        var restart = new Wpf.Ui.Controls.Button { Content = "立即重启更新", Appearance = Wpf.Ui.Controls.ControlAppearance.Primary };
        restart.Click += async (_, _) =>
        {
            restart.IsEnabled = false;
            later.IsEnabled = false;
            try { await install(); }
            catch (Exception error)
            {
                message.Text = $"更新安装失败：{error.Message}";
                restart.IsEnabled = true;
                later.IsEnabled = true;
            }
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Escape) return;
            Close();
            e.Handled = true;
        };
        buttons.Children.Add(details);
        buttons.Children.Add(later);
        buttons.Children.Add(restart);
        content.Children.Add(buttons);
        Content = content;
    }
}
