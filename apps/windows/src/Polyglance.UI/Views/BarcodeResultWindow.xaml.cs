using System.Media;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Polyglance.Core.Services;

namespace Polyglance.UI.Views;

/// <summary>
/// Keeps the selected screenshot in place and puts one interactive marker at
/// the center of every recognized code. Hovering or clicking a marker reveals
/// its decoded content without replacing the whole selection with a list.
/// </summary>
public sealed partial class BarcodeResultWindow : Window
{
    internal const double MarkerDiameter = 22;
    internal const double MarkerCoreDiameter = 11;

    private static readonly SolidColorBrush SecondaryTextBrush =
        new(Color.FromRgb(0x88, 0x88, 0x88));

    private readonly IReadOnlyList<BarcodeObservation> _observations;
    private readonly DispatcherTimer _popupCloseTimer;
    private Popup? _hoverPopup;
    private bool _dismissalStarted;

    internal int MarkerCount => MarkerCanvas.Children.Count;

    public BarcodeResultWindow(
        IReadOnlyList<BarcodeObservation> observations,
        BitmapSource image,
        Rect anchorScreenFrame)
    {
        InitializeComponent();
        _observations = observations;

        Left = anchorScreenFrame.Left;
        Top = anchorScreenFrame.Top;
        Width = Math.Max(1, anchorScreenFrame.Width);
        Height = Math.Max(1, anchorScreenFrame.Height);
        PreviewImage.Source = image;
        HeaderText.Text = HeaderTitle(observations);

        _popupCloseTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(240)
        };
        _popupCloseTimer.Tick += (_, _) =>
        {
            _popupCloseTimer.Stop();
            CloseHoverPopup();
        };

        BuildMarkers(new Size(Width, Height));
    }

    private void BuildMarkers(Size overlaySize)
    {
        foreach (var observation in _observations)
        {
            var marker = MakeMarker();
            var center = MarkerCenter(observation, overlaySize);
            Canvas.SetLeft(marker, center.X - marker.Width / 2);
            Canvas.SetTop(marker, center.Y - marker.Height / 2);
            marker.MouseEnter += (_, _) => ShowPopup(marker, observation);
            marker.MouseLeave += (_, _) => SchedulePopupClose();
            marker.MouseLeftButtonDown += (_, eventArgs) =>
            {
                ShowPopup(marker, observation);
                eventArgs.Handled = true;
            };
            AutomationProperties.SetName(marker, $"查看{observation.Symbology.Title()}内容");
            MarkerCanvas.Children.Add(marker);
        }
    }

    private static Grid MakeMarker()
    {
        var marker = new Grid
        {
            Width = MarkerDiameter,
            Height = MarkerDiameter,
            Cursor = Cursors.Hand,
            Background = Brushes.Transparent
        };
        marker.Children.Add(new Ellipse
        {
            Fill = Brushes.White,
            Effect = new DropShadowEffect
            {
                Color = Colors.Black,
                Opacity = 0.28,
                BlurRadius = 6,
                ShadowDepth = 1
            }
        });
        marker.Children.Add(new Ellipse
        {
            Width = MarkerCoreDiameter,
            Height = MarkerCoreDiameter,
            Fill = new SolidColorBrush(Color.FromRgb(0x0A, 0x84, 0xFF)),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center
        });
        return marker;
    }

    private void ShowPopup(FrameworkElement marker, BarcodeObservation observation)
    {
        _popupCloseTimer.Stop();
        CloseHoverPopup();

        var card = BuildPopupCard(observation);
        card.MouseEnter += (_, _) => _popupCloseTimer.Stop();
        card.MouseLeave += (_, _) => SchedulePopupClose();

        _hoverPopup = new Popup
        {
            PlacementTarget = marker,
            Placement = PlacementMode.Bottom,
            HorizontalOffset = 0,
            VerticalOffset = 5,
            AllowsTransparency = true,
            StaysOpen = true,
            Child = card,
            IsOpen = true
        };
    }

    private Border BuildPopupCard(BarcodeObservation observation)
    {
        var content = observation.Content;
        var panel = new StackPanel { Margin = new Thickness(12) };
        panel.Children.Add(new TextBlock
        {
            Text = observation.Symbology.Title(),
            FontSize = 11,
            Foreground = SecondaryTextBrush
        });
        panel.Children.Add(BuildContentView(content));
        panel.Children.Add(BuildActionsView(content));

        return new Border
        {
            Width = 300,
            Background = Brushes.White,
            BorderBrush = new SolidColorBrush(Color.FromArgb(0x24, 0, 0, 0)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Effect = new DropShadowEffect
            {
                Color = Colors.Black,
                Opacity = 0.24,
                BlurRadius = 16,
                ShadowDepth = 3,
                Direction = 270
            },
            Child = panel
        };
    }

    internal static UIElement BuildContentView(BarcodeContent content)
    {
        switch (content)
        {
            case BarcodeContent.Url url:
                return BuildExpandableText(url.Uri.AbsoluteUri, 150);
            case BarcodeContent.Otp otp:
                var otpPanel = new StackPanel { Margin = new Thickness(0, 4, 0, 6) };
                otpPanel.Children.Add(BuildExpandableText(otp.Uri.AbsoluteUri, 150));
                otpPanel.Children.Add(new TextBlock
                {
                    Text = "两步验证密钥，可导入密码管理器",
                    FontSize = 11,
                    Foreground = SecondaryTextBrush
                });
                return otpPanel;
            case BarcodeContent.Wifi wifi:
                var wifiPanel = new StackPanel { Margin = new Thickness(0, 4, 0, 6) };
                var networkLine = new StackPanel { Orientation = Orientation.Horizontal };
                networkLine.Children.Add(new TextBlock
                {
                    Text = "\uE701",
                    FontFamily = new System.Windows.Media.FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
                    FontSize = 14,
                    VerticalAlignment = VerticalAlignment.Center
                });
                networkLine.Children.Add(new TextBlock
                {
                    Text = wifi.Ssid,
                    FontSize = 12,
                    Margin = new Thickness(6, 0, 0, 0),
                    VerticalAlignment = VerticalAlignment.Center
                });
                wifiPanel.Children.Add(networkLine);
                if (!string.IsNullOrEmpty(wifi.Password))
                {
                    wifiPanel.Children.Add(new TextBlock
                    {
                        Text = $"密码：{wifi.Password}",
                        FontSize = 12
                    });
                }
                if (!string.IsNullOrEmpty(wifi.Security))
                {
                    wifiPanel.Children.Add(new TextBlock
                    {
                        Text = $"加密方式：{wifi.Security}",
                        FontSize = 11,
                        Foreground = SecondaryTextBrush
                    });
                }
                return wifiPanel;
            default:
                return BuildExpandableText(((BarcodeContent.Text)content).Value, 180);
        }
    }

    private static UIElement BuildExpandableText(string text, double maximumHeight)
    {
        var value = new TextBlock
        {
            Text = text,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap
        };
        return new ScrollViewer
        {
            Content = value,
            MaxHeight = maximumHeight,
            Margin = new Thickness(0, 4, 0, 6),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
    }

    private UIElement BuildActionsView(BarcodeContent content)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var copyTitle = content is BarcodeContent.Wifi ? "复制密码" : "复制";
        var copyButton = MakeActionButton(copyTitle);
        copyButton.IsEnabled = content.CopiedText.Length > 0;
        copyButton.Click += (_, _) =>
        {
            try
            {
                Clipboard.SetText(content.CopiedText);
                copyButton.Content = "已复制";
            }
            catch (ExternalException)
            {
                SystemSounds.Beep.Play();
            }
        };
        panel.Children.Add(copyButton);

        if (content is BarcodeContent.Url url)
        {
            var openButton = MakeActionButton("打开链接");
            openButton.Margin = new Thickness(6, 0, 0, 0);
            openButton.Click += (_, _) => ConfirmOpen(url.Uri);
            panel.Children.Add(openButton);
        }
        return panel;
    }

    private static Button MakeActionButton(string title) => new()
    {
        Content = title,
        MinWidth = 60,
        Height = 26,
        Padding = new Thickness(8, 0, 8, 0),
        Cursor = Cursors.Hand
    };

    private void ConfirmOpen(Uri uri)
    {
        var result = MessageBox.Show(
            this,
            uri.AbsoluteUri,
            "打开链接？",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Information);
        if (result != MessageBoxResult.OK)
        {
            return;
        }

        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = uri.AbsoluteUri,
                UseShellExecute = true
            });
            Dismiss();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法打开链接", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void SchedulePopupClose()
    {
        _popupCloseTimer.Stop();
        _popupCloseTimer.Start();
    }

    private void CloseHoverPopup()
    {
        if (_hoverPopup is null)
        {
            return;
        }
        _hoverPopup.IsOpen = false;
        _hoverPopup.Child = null;
        _hoverPopup = null;
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Dismiss();
        }
    }

    protected override void OnPreviewMouseDoubleClick(MouseButtonEventArgs e)
    {
        if (HandlePointerDoubleClick(e.ChangedButton))
        {
            e.Handled = true;
            return;
        }
        base.OnPreviewMouseDoubleClick(e);
    }

    internal bool HandlePointerDoubleClick(MouseButton button)
    {
        if (button != MouseButton.Left)
        {
            return false;
        }
        Dismiss();
        return true;
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        Dismiss();
    }

    internal void Dismiss()
    {
        if (_dismissalStarted)
        {
            return;
        }
        _dismissalStarted = true;
        _popupCloseTimer.Stop();
        CloseHoverPopup();
        Close();
    }

    protected override void OnClosed(EventArgs e)
    {
        _dismissalStarted = true;
        _popupCloseTimer.Stop();
        CloseHoverPopup();
        base.OnClosed(e);
    }

    internal static Point MarkerCenter(BarcodeObservation observation, Size overlaySize) => new(
        observation.BoundingBox.X * overlaySize.Width
            + observation.BoundingBox.Width * overlaySize.Width / 2,
        (1 - observation.BoundingBox.Y - observation.BoundingBox.Height / 2)
            * overlaySize.Height);

    internal static string HeaderTitle(IReadOnlyList<BarcodeObservation> observations) =>
        observations.Count == 1
            ? observations[0].Symbology.Title()
            : $"识别到 {observations.Count} 个二维码";
}
