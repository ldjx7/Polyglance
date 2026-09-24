using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.IO.Path;
using System.Windows.Threading;
using Polyglance.Platform.Capture;
using Polyglance.Platform.Recording;

class Program
{
    [STAThread]
    static void Main()
    {
        var app = new Application();
        var canvas = new Canvas { Background = Brushes.DarkBlue };
        var bar = new Rectangle { Width = 60, Height = 500, Fill = Brushes.Lime };
        var top = new Rectangle { Width = 1000, Height = 60, Fill = Brushes.Red };
        var bottom = new Rectangle { Width = 1000, Height = 60, Fill = Brushes.Blue };
        Canvas.SetTop(bottom, 580);
        var text = new TextBlock { Foreground = Brushes.White, FontSize = 40 };
        Canvas.SetTop(text, 180);
        canvas.Children.Add(top);canvas.Children.Add(bottom);canvas.Children.Add(bar);canvas.Children.Add(text);
        var window = new Window { Width = 1000, Height = 640, Left = 50, Top = 50,
            WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, Topmost = true, Content = canvas };
        var animation = Stopwatch.StartNew();
        CompositionTarget.Rendering += (_, _) => {
            double seconds = animation.Elapsed.TotalSeconds;
            Canvas.SetLeft(bar, seconds * 250 % 900);
            Canvas.SetTop(bar, 65);
            text.Text = $"Polyglance recording test {seconds:F3}";
        };
        window.Loaded += async (_, _) => {
            var dir = Path.Combine(AppContext.BaseDirectory, "results");
            Directory.CreateDirectory(dir);
            try {
                File.Delete(Path.Combine(dir, "done.txt"));
                File.Delete(Path.Combine(dir, "error.txt"));
                await Task.Delay(700);
                var origin = canvas.PointToScreen(new Point(0,0));
                var end = canvas.PointToScreen(new Point(canvas.ActualWidth,canvas.ActualHeight));
                var region = new Int32Rect((int)origin.X,(int)origin.Y,(int)(end.X-origin.X)&~1,(int)(end.Y-origin.Y)&~1);
                var opts = ScreenRecordingMediaOptions.Create(ScreenRecordingContainer.Mp4,false,false,false);
                await using (var session = new LegacyRecordingSession(System.IO.Path.Combine(dir,"before-temp"),region.Width,region.Height,30,88,8_000_000,opts)) {
                    var times=new List<double>();var watch=Stopwatch.StartNew();Task pending=Task.CompletedTask;
                    var timer=new DispatcherTimer(DispatcherPriority.Render) { Interval=TimeSpan.FromMilliseconds(1000.0/30) };
                    timer.Tick += async (_,_) => {
                        if(!pending.IsCompleted)return;
                        int target=Math.Max(1,(int)Math.Ceiling(watch.Elapsed.TotalSeconds*30));
                        if(target<=session.FramesWritten)return;
                        double time=watch.Elapsed.TotalSeconds;
                        pending=Task.Run(()=>{var frame=ScreenCapture.CaptureRegion(region,false);session.AppendFrame(frame,Math.Max(1,target-session.FramesWritten));});
                        await pending;times.Add(time);
                    };
                    timer.Start();await Task.Delay(5000);timer.Stop();await pending;watch.Stop();
                    var finish=Stopwatch.StartNew();await session.FinishAsync(System.IO.Path.Combine(dir,"before.mp4"));
                    File.WriteAllText(System.IO.Path.Combine(dir,"before.json"),JsonSerializer.Serialize(new { region.Width,region.Height,Duration=watch.Elapsed.TotalSeconds,CapturedFrames=times.Count,WrittenFrames=session.FramesWritten,FinalizeMs=finish.Elapsed.TotalMilliseconds,Times=times }));
                }
                await Task.Delay(500);
                await using(var session = new ScreenRecordingMp4Session(System.IO.Path.Combine(dir,"after-temp"),region.Width,region.Height,30,8_000_000,opts)) {
                    using var loop = new ScreenRecordingCaptureLoop(region,30,false,session);
                    await Task.Delay(5000);await loop.StopAsync();
                    var finish=Stopwatch.StartNew();await session.FinishAsync(System.IO.Path.Combine(dir,"after.mp4"),loop.Duration);
                    File.WriteAllText(System.IO.Path.Combine(dir,"after.json"),JsonSerializer.Serialize(new{ Capture=loop.Statistics,FinalizeMs=finish.Elapsed.TotalMilliseconds}));
                }
                File.WriteAllText(System.IO.Path.Combine(dir,"done.txt"),"OK");
            } catch(Exception error) {File.WriteAllText(System.IO.Path.Combine(dir,"error.txt"),error.ToString());}
            window.Close();
        };
        app.Run(window);
    }
}
