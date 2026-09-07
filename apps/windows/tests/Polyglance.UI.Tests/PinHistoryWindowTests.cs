using System;
using System.IO;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Polyglance.Platform.Pin;
using Polyglance.UI.Views;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Polyglance.UI.Tests;

public sealed class PinHistoryWindowTests : IDisposable
{
    private static void WaitFor(Task task)
    {
        var dispatcher = Dispatcher.CurrentDispatcher;
        var frame = new DispatcherFrame();
        _ = task.ContinueWith(_ => dispatcher.BeginInvoke(new Action(() => frame.Continue = false)));
        Dispatcher.PushFrame(frame);
        task.GetAwaiter().GetResult();
    }
    private readonly string _testDirectory;
    private readonly PinArchiveStore _store;

    public PinHistoryWindowTests()
    {
        _testDirectory = Path.Combine(Path.GetTempPath(), $"PinHistoryWindowTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_testDirectory);
        _store = new PinArchiveStore(_testDirectory);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_testDirectory))
                Directory.Delete(_testDirectory, true);
        }
        catch { }
    }

    private static BitmapSource CreateSolidBitmap(int width = 50, int height = 50)
    {
        byte[] pixels = new byte[width * height * 4];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 0x55;
            pixels[i + 1] = 0xAA;
            pixels[i + 2] = 0xFF;
            pixels[i + 3] = 0xFF;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
        bitmap.Freeze();
        return bitmap;
    }

    private static void RunInSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(Dispatcher.CurrentDispatcher));
                action();
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            ExceptionDispatchInfo.Capture(failure).Throw();
    }

    [Fact]
    public void PinWindow_RecordsArchiveWithCorrectSource()
    {
        RunInSta(() =>
        {
            var bitmap = CreateSolidBitmap(40, 40);
            var pin = new PinWindow(
                bitmap,
                null,
                null,
                _ => { },
                null,
                source: PinArchiveSource.Clipboard,
                saveToHistory: true,
                archiveStore: _store);

            WaitFor(_store.DrainAsync());
            var items = _store.List();
            Assert.Single(items);
            Assert.Equal(PinArchiveSource.Clipboard, items[0].Source);

            pin.Close();
        });
    }

    [Fact]
    public void PinWindow_WithSaveToHistoryFalse_DoesNotRecordInArchive()
    {
        RunInSta(() =>
        {
            var bitmap = CreateSolidBitmap(40, 40);
            var pin = new PinWindow(
                bitmap,
                null,
                null,
                _ => { },
                null,
                source: PinArchiveSource.Legacy,
                saveToHistory: false,
                archiveStore: _store);

            var items = _store.List();
            Assert.Empty(items);

            pin.Close();
        });
    }

    [Fact]
    public void PinHistoryWindow_RefreshItems_PopulatesDisplayItems()
    {
        RunInSta(() =>
        {
            var bitmap = CreateSolidBitmap(60, 40);
            _store.Append(bitmap, PinArchiveSource.Screenshot);

            var window = new PinHistoryWindow(null, null, _store);
            WaitFor(window.RefreshItems());

            Assert.Equal("(1)", window.TxtCount.Text);
            Assert.Equal(Visibility.Visible, window.LstHistory.Visibility);
            Assert.Equal(Visibility.Collapsed, window.EmptyPanel.Visibility);
            Assert.NotNull(window.LstHistory.SelectedItem);

            window.ExplicitClose();
        });
    }

    [Fact]
    public void PinHistoryWindow_PinItem_CreatesPinWithoutRecordingAgain()
    {
        RunInSta(() =>
        {
            var bitmap = CreateSolidBitmap(60, 40);
            var item = _store.Append(bitmap, PinArchiveSource.Screenshot);
            Assert.NotNull(item);
            Assert.Single(_store.List());

            var window = new PinHistoryWindow(null, null, _store);
            WaitFor(window.PinItem(item!));

            // Ensure no duplicate item was appended
            Assert.Single(_store.List());

            window.ExplicitClose();
        });
    }

    [Fact]
    public void PinHistoryManager_SetOverrideStore_RedirectsDefaultStore()
    {
        var tempStore = new PinArchiveStore(_testDirectory);
        try
        {
            PinHistoryManager.SetOverrideStore(tempStore);
            Assert.Same(tempStore, PinHistoryManager.DefaultStore);

            var bitmap = CreateSolidBitmap(30, 30);
            PinHistoryManager.SavePinToHistory(bitmap, PinArchiveSource.Screenshot);

            var pins = PinHistoryManager.GetRecentPins();
            Assert.Single(pins);
            Assert.Contains(tempStore.DirectoryPath, pins[0].FilePath);
        }
        finally
        {
            PinHistoryManager.SetOverrideStore(null);
        }
    }

    [Fact]
    public void PinHistoryWindow_Hide_ClearsThumbnailCache()
    {
        RunInSta(() =>
        {
            var bitmap = CreateSolidBitmap(60, 40);
            _store.Append(bitmap, PinArchiveSource.Screenshot);

            var window = new PinHistoryWindow(null, null, _store);
            WaitFor(window.RefreshItems());

            // Show window first so IsVisible transitions to true
            window.Show();

            // Give async task a brief moment to run or simulate loaded thumb
            if (window.LstHistory.ItemsSource is IEnumerable<PinHistoryDisplayItem> items)
            {
                var first = items.First();
                first.Thumbnail = bitmap;
                Assert.NotNull(first.Thumbnail);
            }

            // Window hide triggers OnIsVisibleChanged(false)
            window.Hide();

            if (window.LstHistory.ItemsSource is IEnumerable<PinHistoryDisplayItem> itemsAfter)
            {
                var first = itemsAfter.First();
                Assert.Null(first.Thumbnail);
            }

            window.ExplicitClose();
        });
    }
}
