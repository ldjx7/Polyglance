using Polyglance.Platform.Text;

namespace Polyglance.Platform.Tests;

public sealed class SelectedTextReaderTests
{
    [Fact]
    public async Task DirectSelectionWinsWithoutTouchingTheClipboard()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            DirectSelection = "  selected text\r\n"
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Equal("selected text", result);
        Assert.Equal(0, environment.CaptureClipboardCalls);
        Assert.Equal(0, environment.SendCopyCalls);
    }

    [Fact]
    public async Task FailedCopyNeverReturnsThePreviousClipboardText()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            ClipboardText = "stale clipboard"
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Null(result);
        Assert.Equal(1, environment.SendCopyCalls);
        Assert.Equal("stale clipboard", environment.ClipboardText);
        Assert.Equal(1, environment.RestoreClipboardCalls);
    }

    [Fact]
    public async Task CopyFallbackReturnsTheNewSelectionAndRestoresTheClipboard()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            ClipboardText = "previous clipboard",
            CopiedSelection = "  copied selection  "
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Equal("copied selection", result);
        Assert.Equal("previous clipboard", environment.ClipboardText);
        Assert.Equal(1, environment.RestoreClipboardCalls);
    }

    [Fact]
    public async Task CopyWaitsForGlobalHotkeyModifiersToBeReleased()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            ClipboardText = "previous clipboard",
            CopiedSelection = "selected",
            ModifierStates = new Queue<bool>([true, true, false])
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Equal("selected", result);
        Assert.True(environment.ModifierChecks >= 3);
        Assert.True(environment.DelayCalls >= 2);
        Assert.Equal(1, environment.SendCopyCalls);
    }

    [Fact]
    public async Task ClipboardChangedBySomeoneElseIsNotOverwrittenDuringRestore()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            ClipboardText = "previous clipboard",
            CopiedSelection = "selected",
            ChangeClipboardWhileReading = "newer clipboard"
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Equal("selected", result);
        Assert.Equal("newer clipboard", environment.ClipboardText);
        Assert.Equal(0, environment.RestoreClipboardCalls);
    }

    [Fact]
    public async Task ClipboardIsNotClearedWhenItsContentsCannotBePreserved()
    {
        var environment = new FakeSelectedTextEnvironment
        {
            ClipboardText = "important clipboard",
            CopiedSelection = "selected",
            ThrowWhileCapturingClipboard = true
        };

        string? result = await new SelectedTextCapturePipeline(environment).ReadAsync();

        Assert.Null(result);
        Assert.Equal("important clipboard", environment.ClipboardText);
        Assert.Equal(0, environment.ClearClipboardCalls);
        Assert.Equal(0, environment.SendCopyCalls);
    }

    private sealed class FakeSelectedTextEnvironment : ISelectedTextCaptureEnvironment
    {
        private string? _snapshot;
        private bool _readAfterCopy;

        public string? DirectSelection { get; init; }
        public string? ClipboardText { get; set; }
        public string? CopiedSelection { get; init; }
        public string? ChangeClipboardWhileReading { get; init; }
        public bool ThrowWhileCapturingClipboard { get; init; }
        public Queue<bool> ModifierStates { get; init; } = new();
        public uint ClipboardSequenceNumber { get; private set; } = 10;
        public int CaptureClipboardCalls { get; private set; }
        public int ClearClipboardCalls { get; private set; }
        public int RestoreClipboardCalls { get; private set; }
        public int SendCopyCalls { get; private set; }
        public int ModifierChecks { get; private set; }
        public int DelayCalls { get; private set; }

        public string? ReadFocusedSelection() => DirectSelection;

        public ClipboardSnapshot CaptureClipboard()
        {
            CaptureClipboardCalls++;
            if (ThrowWhileCapturingClipboard)
            {
                throw new InvalidOperationException("clipboard busy");
            }
            _snapshot = ClipboardText;
            return new ClipboardSnapshot(_snapshot);
        }

        public void ClearClipboard()
        {
            ClearClipboardCalls++;
            ClipboardText = null;
            ClipboardSequenceNumber++;
        }

        public bool AreShortcutModifiersPressed()
        {
            ModifierChecks++;
            return ModifierStates.Count > 0 && ModifierStates.Dequeue();
        }

        public bool SendCopyShortcut()
        {
            SendCopyCalls++;
            if (CopiedSelection != null)
            {
                ClipboardText = CopiedSelection;
                ClipboardSequenceNumber++;
            }
            return true;
        }

        public string? ReadClipboardText()
        {
            string? result = ClipboardText;
            if (!_readAfterCopy && ChangeClipboardWhileReading != null)
            {
                _readAfterCopy = true;
                ClipboardText = ChangeClipboardWhileReading;
                ClipboardSequenceNumber++;
            }
            return result;
        }

        public void RestoreClipboard(ClipboardSnapshot snapshot)
        {
            RestoreClipboardCalls++;
            ClipboardText = (string?)snapshot.Value;
            ClipboardSequenceNumber++;
        }

        public Task DelayAsync(TimeSpan delay)
        {
            DelayCalls++;
            return Task.CompletedTask;
        }
    }
}
