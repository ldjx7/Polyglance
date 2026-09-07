using System;
using System.IO;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Polyglance.Platform.Pin;
using Polyglance.UI.Views;
using Xunit;

namespace Polyglance.UI.Tests;

public sealed class PinSessionWindowTests
{
    [Fact]
    public void RepeatedClipboardTraversesDistinctHistoryWithoutDuplicates()
    {
        Sta(() =>
        {
            string directory = Path.Combine(Path.GetTempPath(), "PinSequenceUI-" + Guid.NewGuid());
            try
            {
                var store = new PinArchiveStore(directory);
                var controller = PinSessionController.For(store);
                var older = new TextPinWindow("较早原文", store); older.Show(); older.Close();
                var recent = new TextPinWindow("最近原文", store); recent.Show(); recent.Close();
                Wait(controller.PinNextClipboardContent(null, "最近原文", null, null));
                Assert.Equal(1, controller.ActiveCount);
                Wait(controller.PinNextClipboardContent(null, "最近原文", null, null));
                Assert.Equal(2, controller.ActiveCount);
                Wait(controller.PinNextClipboardContent(null, "最近原文", null, null));
                Assert.Equal(2, controller.ActiveCount);
                Wait(store.DrainAsync());
                Assert.Equal(2, store.List().Count);
                Wait(controller.DestroyAll());
                Wait(controller.PrepareForTermination());
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        });
    }

    [Fact]
    public void ShortTextUsesCompactBorderlessCard()
    {
        Sta(() =>
        {
            string directory = Path.Combine(Path.GetTempPath(), "PinCompactUI-" + Guid.NewGuid());
            try
            {
                var store = new PinArchiveStore(directory);
                var window = new TextPinWindow("销毁测试贴图后，历史中消失，关闭恢复和重启都不能让它再次出现。", store);
                window.Show();
                Assert.Equal(WindowStyle.None, window.WindowStyle);
                Assert.True(window.Height < 80);
                Assert.True(window.Width > 500);
                window.Close();
                Wait(PinSessionController.For(store).PrepareForTermination());
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        });
    }

    private static void Wait(Task task)
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var frame = new DispatcherFrame();
        _ = task.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)));
        Dispatcher.PushFrame(frame);
        task.GetAwaiter().GetResult();
    }

    private static void Sta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
            try { action(); } catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); thread.Join();
        if (failure != null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    [Fact]
    public void ClosingTextPersistsSelectableOriginalAndRestoresThenDestroys()
    {
        Sta(() =>
        {
            string directory = Path.Combine(Path.GetTempPath(), "PinSessionUI-" + Guid.NewGuid());
            try
            {
                var store = new PinArchiveStore(directory);
                var controller = PinSessionController.For(store);
                var window = new TextPinWindow("原文\nselect and copy", store) { Left = 140, Top = 160, Width = 430, Height = 320, Opacity = .6 };
                window.Show();
                Assert.True(window.TextContent.IsReadOnly);
                window.TextContent.Select(0, 2);
                Assert.Equal("原文", window.TextContent.SelectedText);
                window.Close();
                Wait(store.DrainAsync());
                var closed = Assert.Single(store.LoadSessions());
                Assert.Equal(PinSessionStatus.Closed, closed.Status);
                Assert.Equal(.6, closed.Opacity);
                Assert.Equal(430, closed.Width);
                Wait(controller.Restore(false, null, null));
                Assert.Equal(PinSessionStatus.Active, Assert.Single(store.LoadSessions()).Status);
                Wait(controller.DestroyAll());
                Wait(store.DrainAsync());
                Assert.Empty(store.List());
                Assert.Empty(store.LoadSessions());
                Wait(controller.PrepareForTermination());
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        });
    }

    [Fact]
    public void ShutdownKeepsActiveStateAndStartupDoesNotReopenClosedPins()
    {
        Sta(() =>
        {
            string directory = Path.Combine(Path.GetTempPath(), "PinRestartUI-" + Guid.NewGuid());
            try
            {
                var store = new PinArchiveStore(directory);
                var controller = PinSessionController.For(store);
                var active = new TextPinWindow("仍在桌面", store) { Left = 130, Top = 150, Width = 420, Height = 310, Opacity = .6 };
                active.Show();
                var closed = new TextPinWindow("已关闭", store); closed.Show(); closed.Close();
                Wait(controller.PrepareForTermination()); active.Close();
                var reloaded = new PinArchiveStore(directory);
                var next = PinSessionController.For(reloaded);
                Wait(next.Restore(true, null, null));
                Wait(reloaded.DrainAsync());
                var records = reloaded.LoadSessions();
                var restored = Assert.Single(records, s => s.Status == PinSessionStatus.Active);
                Assert.Equal("仍在桌面", restored.Text);
                Assert.Equal(.6, restored.Opacity);
                Assert.Single(records, s => s.Status == PinSessionStatus.Closed);
                Wait(next.DestroyAll());
                Wait(next.PrepareForTermination());
            }
            finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        });
    }
}
