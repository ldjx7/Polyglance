using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Pin;
using Application = System.Windows.Application;

namespace Polyglance.UI.Views;

/// UI-thread owner of pin lifetimes. Disk operations use the archive's serial queue.
internal sealed class PinSessionController
{
    private static readonly ConditionalWeakTable<PinArchiveStore, PinSessionController> Controllers = new();
    internal static PinSessionController For(PinArchiveStore? store = null) =>
        Controllers.GetValue(store ?? PinHistoryManager.DefaultStore, s => new(s));

    private sealed class Binding(Window window, PinSessionRecord state, Func<PinSessionRecord, PinSessionRecord> capture,
        Func<BitmapSource?>? annotatedImage)
    {
        public Window Window = window;
        public PinSessionRecord State = state;
        public Func<PinSessionRecord, PinSessionRecord> Capture = capture;
        public Func<BitmapSource?>? AnnotatedImage = annotatedImage;
    }

    private readonly PinArchiveStore _store;
    private readonly Dictionary<Window, Binding> _windows = new();
    private readonly HashSet<string> _destroying = new();
    private readonly DispatcherTimer _timer;
    private bool _terminating;
    private bool _restoring;

    private PinSessionController(PinArchiveStore store)
    {
        _store = store;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _timer.Tick += (_, _) => SaveActive();
    }

    internal int ActiveCount => _windows.Count;

    internal async Task PinNextClipboardContent(BitmapSource? candidateImage, string? candidateText,
        TranslationService? service, AppConfiguration? configuration)
    {
        if (candidateImage == null && string.IsNullOrEmpty(candidateText))
        {
            if (Clipboard.ContainsImage())
            {
                candidateImage = Clipboard.GetImage();
            }
            else if (Clipboard.ContainsText())
            {
                candidateText = Clipboard.GetText();
            }
            else
            {
                return;
            }
        }

        if (candidateImage != null)
        {
            if ((long)candidateImage.PixelWidth * candidateImage.PixelHeight > 100_000_000)
                throw new InvalidOperationException("图片尺寸过大，无法安全贴图。");
        }
        if (!string.IsNullOrEmpty(candidateText))
        {
            if (System.Text.Encoding.UTF8.GetByteCount(candidateText) > 1048576)
                throw new InvalidOperationException("剪贴板文本超过 1 MB，无法贴出。");
        }

        bool isCandidateActive = false;
        if (!string.IsNullOrEmpty(candidateText))
        {
            isCandidateActive = _windows.Values.Any(b =>
                (b.Window as TextPinWindow)?.TextContent.Text == candidateText
                || b.State.Text == candidateText);
        }
        else if (candidateImage != null)
        {
            isCandidateActive = _windows.Values.Any(b =>
                b.Window is PinWindow pin && BitmapsEqual(pin.Bitmap, candidateImage));
        }

        if (!isCandidateActive)
        {
            if (!string.IsNullOrEmpty(candidateText))
            {
                var sessions = await _store.Schedule(s => s.LoadSessions());
                var existing = sessions.LastOrDefault(s => s.Text == candidateText);
                var window = new TextPinWindow(candidateText, _store, existing?.ArchiveId, existing);
                window.Show();
                KeepVisible(window);
                SaveActive();
            }
            else if (candidateImage != null)
            {
                var historyItems = await _store.Schedule(s => s.List());
                string? existingId = null;
                foreach (var item in historyItems)
                {
                    if (item.PixelWidth == candidateImage.PixelWidth && item.PixelHeight == candidateImage.PixelHeight)
                    {
                        var img = await _store.Schedule(s => s.LoadImage(item.Id));
                        if (img != null && BitmapsEqual(img, candidateImage))
                        {
                            existingId = item.Id;
                            break;
                        }
                    }
                }

                if (existingId != null)
                {
                    var sessions = await _store.Schedule(s => s.LoadSessions());
                    var existingSession = sessions.LastOrDefault(s => s.ArchiveId == existingId);
                    Open(candidateImage, existingId, service, configuration, existingSession);
                }
                else
                {
                    var placement = PinPositioning.CalculatePlacementForCursor(candidateImage.PixelWidth, candidateImage.PixelHeight);
                    var window = new PinWindow(candidateImage, service, configuration, Clipboard.SetText,
                        capturedDisplaySize: new Size(placement.ImageWidthDips, placement.ImageHeightDips),
                        source: PinArchiveSource.Clipboard, saveToHistory: true, archiveStore: _store)
                    {
                        Left = placement.WindowLeftDips,
                        Top = placement.WindowTopDips
                    };
                    window.Show();
                    KeepVisible(window);
                    SaveActive();
                }
            }
            return;
        }

        var history = await _store.Schedule(s => s.List());
        var allSessions = await _store.Schedule(s => s.LoadSessions());
        var activeIds = _windows.Values.Select(b => b.State.ArchiveId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var activeTexts = _windows.Values
            .Select(b => (b.Window as TextPinWindow)?.TextContent.Text ?? b.State.Text)
            .Where(t => t != null)
            .ToHashSet();

        foreach (var item in history)
        {
            if (activeIds.Contains(item.Id)) continue;
            var session = allSessions.LastOrDefault(s => string.Equals(s.ArchiveId, item.Id, StringComparison.OrdinalIgnoreCase));
            if (!string.IsNullOrEmpty(session?.Text))
            {
                if (activeTexts.Contains(session.Text)) continue;
                var window = new TextPinWindow(session.Text, _store, item.Id, session);
                window.Show();
                KeepVisible(window);
                SaveActive();
                return;
            }
            else
            {
                var img = await _store.Schedule(s => s.LoadImage(item.Id));
                if (img == null) continue;
                if (_windows.Values.Any(b => b.Window is PinWindow p && BitmapsEqual(p.Bitmap, img))) continue;
                Open(img, item.Id, service, configuration, session);
                return;
            }
        }
    }

    private static bool BitmapsEqual(BitmapSource? a, BitmapSource? b)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;
        if (a.PixelWidth != b.PixelWidth || a.PixelHeight != b.PixelHeight) return false;
        if (a.Format != b.Format)
        {
            var fa = new FormatConvertedBitmap(a, PixelFormats.Pbgra32, null, 0);
            var fb = new FormatConvertedBitmap(b, PixelFormats.Pbgra32, null, 0);
            return BitmapsEqual(fa, fb);
        }
        int stride = (a.PixelWidth * a.Format.BitsPerPixel + 7) / 8;
        byte[] bytesA = new byte[stride * a.PixelHeight];
        byte[] bytesB = new byte[stride * b.PixelHeight];
        a.CopyPixels(bytesA, stride, 0);
        b.CopyPixels(bytesB, stride, 0);
        return bytesA.AsSpan().SequenceEqual(bytesB);
    }

    internal void Register(Window window, BitmapSource image, PinArchiveSource source, bool save,
        string? archiveId, PinSessionRecord? session, string? text,
        Func<PinSessionRecord, PinSessionRecord> capture, Func<BitmapSource?>? annotatedImage = null)
    {
        if (!save && archiveId == null && session == null) return;
        string id = session?.ArchiveId ?? archiveId ?? Guid.NewGuid().ToString("N");
        var state = (session ?? new PinSessionRecord { ArchiveId = id, Text = text }) with { Status = PinSessionStatus.Active };
        _windows[window] = new(window, state, capture, annotatedImage);
        if (save) PinArchiveRecording.Record(image, source, _store, id);
        Save(state);
        window.Loaded += (_, _) => SaveActive();
        window.Closed += (_, _) =>
        {
            if (!_windows.Remove(window, out var binding)) return;
            if (!_terminating && !_destroying.Contains(binding.State.ArchiveId))
            {
                SaveAnnotatedImage(binding);
                Save(binding.Capture(binding.State) with { Status = PinSessionStatus.Closed });
            }
            if (_windows.Count == 0) _timer.Stop();
        };
        _timer.Start();
    }

    private async void Save(PinSessionRecord state)
    {
        try
        {
            bool failed = await _store.Schedule(s => !s.SaveSession(state) && s.LoadImage(state.ArchiveId) != null);
            if (failed) Report("未能保存贴图状态。请检查磁盘空间和历史目录权限。");
        }
        catch { Report("未能保存贴图状态。请检查磁盘空间和历史目录权限。"); }
    }

    internal void SaveActive()
    {
        if (_terminating) return;
        foreach (var binding in _windows.Values)
        {
            if (!binding.Window.IsLoaded || _destroying.Contains(binding.State.ArchiveId)) continue;
            var state = binding.Capture(binding.State);
            if (state != binding.State && state.IsValid) { binding.State = state; Save(state); }
        }
    }

    internal async Task PrepareForTermination()
    {
        SaveActive();
        foreach (var binding in _windows.Values) SaveAnnotatedImage(binding);
        _terminating = true;
        _timer.Stop();
        await _store.DrainAsync();
    }

    private async void SaveAnnotatedImage(Binding binding)
    {
        try
        {
            var image = binding.AnnotatedImage?.Invoke();
            if (image == null) return;
            if (!image.IsFrozen) { image = image.Clone(); image.Freeze(); }
            bool failed = await _store.Schedule(s => !s.ReplaceImage(image, binding.State.ArchiveId) && s.LoadImage(binding.State.ArchiveId) != null);
            if (failed) Report("未能保存贴图标注，请检查历史目录的空间和权限。");
        }
        catch { Report("未能保存贴图标注，请重试。"); }
    }

    internal async Task Destroy(Window window)
    {
        if (!_windows.TryGetValue(window, out var binding)) { window.Close(); return; }
        string id = binding.State.ArchiveId;
        if (!_destroying.Add(id)) return;
        try
        {
            var result = await _store.Schedule(s => s.Delete(id));
            if (!result.IsSuccess) { Report(result.ErrorMessage ?? "未能销毁贴图，请重试。"); return; }
            var related = _windows.Values.Where(b => b.State.ArchiveId == id).ToArray();
            ClearClipboardIfMatching(related);
            foreach (var b in related)
            {
                _windows.Remove(b.Window);
                b.Window.Close();
            }
        }
        catch { Report("未能销毁贴图，请检查磁盘权限后重试。"); }
        finally { _destroying.Remove(id); }
    }

    private static void ClearClipboardIfMatching(IEnumerable<Binding> bindings)
    {
        try
        {
            foreach (var b in bindings)
            {
                if (b.State.Text != null)
                {
                    if (Clipboard.ContainsText())
                    {
                        var clipText = Clipboard.GetText();
                        if (NormalizeText(clipText) == NormalizeText(b.State.Text))
                        {
                            Clipboard.Clear();
                        }
                    }
                }
                else
                {
                    if (Clipboard.ContainsImage())
                    {
                        Clipboard.Clear();
                    }
                }
            }
        }
        catch { }
    }

    private static string NormalizeText(string? text) =>
        (text ?? "").Replace("\r\n", "\n").Trim();

    internal async Task DestroyAll()
    {
        var allWindows = _windows.Values.ToArray();
        ClearClipboardIfMatching(allWindows);
        foreach (var window in _windows.Keys.ToArray()) await Destroy(window);
    }

    internal async Task Restore(bool startup, TranslationService? service, AppConfiguration? configuration)
    {
        if (_restoring || _terminating) return;
        _restoring = true;
        try
        {
            var saved = await _store.Schedule(s => { _ = s.List(); return s.LoadSessions(); });
            var candidates = startup ? saved.Where(s => s.Status == PinSessionStatus.Active).ToArray()
                : saved.Where(s => s.Status == PinSessionStatus.Closed).TakeLast(1).ToArray();
            long remainingBytes = 512L * 1024 * 1024;
            var items = await _store.Schedule(s => s.List().ToDictionary(i => i.Id));
            bool skipped = false;
            foreach (var state in candidates)
            {
                if (_terminating || _destroying.Contains(state.ArchiveId)
                    || _windows.Values.Any(w => w.State.Id == state.Id)) continue;
                if (!items.TryGetValue(state.ArchiveId, out var item)) continue;
                long bytes = (long)item.PixelWidth * item.PixelHeight * 4;
                if (bytes > remainingBytes) { skipped = true; continue; }
                var image = await _store.Schedule(s => s.LoadImage(state.ArchiveId));
                if (image == null || _terminating || _destroying.Contains(state.ArchiveId)) continue;
                remainingBytes -= bytes;
                Open(image, state.ArchiveId, service, configuration, state);
            }
            await _store.DrainAsync();
            if (skipped) Report("部分贴图未自动恢复：自动恢复的图片内存预算为 512 MiB，其余记录仍可从贴图历史手动贴出。");
        }
        catch { Report("未能恢复贴图。已有历史文件未被清空。"); }
        finally { _restoring = false; }
    }

    internal async Task OpenHistory(BitmapSource image, string id, TranslationService? service, AppConfiguration? configuration)
    {
        var previous = await _store.Schedule(s => s.LoadSessions().LastOrDefault(r => r.ArchiveId == id));
        Open(image, id, service, configuration, null, previous?.Text);
    }

    private void Open(BitmapSource image, string id, TranslationService? service, AppConfiguration? configuration,
        PinSessionRecord? state, string? text = null)
    {
        text ??= state?.Text;
        Window window;
        if (text != null)
            window = new TextPinWindow(text, _store, id, state);
        else
        {
            var placement = PinPositioning.CalculatePlacementForCursor(image.PixelWidth, image.PixelHeight);
            window = new PinWindow(image, service, configuration, Clipboard.SetText,
                capturedDisplaySize: state == null ? new Size(placement.ImageWidthDips, placement.ImageHeightDips) : new Size(state.Width, state.Height),
                saveToHistory: false, archiveStore: _store, archiveId: id, session: state)
            {
                Left = state?.X ?? placement.WindowLeftDips,
                Top = state?.Y ?? placement.WindowTopDips
            };
        }
        window.Show();
        KeepVisible(window);
        SaveActive();
    }

    internal static void KeepVisible(Window window)
    {
        // Query the actual HWND in physical pixels, avoiding comparisons between mixed-DPI DIP spaces.
        var handle = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        if (!Polyglance.Platform.Interop.NativeWin32.GetWindowRect(handle, out var rect)) return;
        var physical = new System.Drawing.Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
        if (System.Windows.Forms.Screen.AllScreens.Any(s =>
            System.Drawing.Rectangle.Intersect(s.WorkingArea, physical) is var overlap && overlap.Width >= 80 && overlap.Height >= 60)) return;
        var placement = PinPositioning.CalculatePlacementForCursor((int)Math.Max(1, window.ActualWidth), (int)Math.Max(1, window.ActualHeight));
        window.Left = placement.WindowLeftDips;
        window.Top = placement.WindowTopDips;
    }

    internal static void Report(string message)
    {
        if (Application.Current != null) MessageBox.Show(message, "Polyglance · 贴图", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
}
