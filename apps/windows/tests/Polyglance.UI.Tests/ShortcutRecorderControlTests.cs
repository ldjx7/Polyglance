using Polyglance.UI.Controls;

namespace Polyglance.UI.Tests;

public sealed class ShortcutRecorderControlTests
{
    [Theory]
    [InlineData("Ctrl+Shift+D1", "Ctrl + Shift + 1")]
    [InlineData("Ctrl+Shift+D4", "Ctrl + Shift + 4")]
    [InlineData("", "未设置")]
    public void ShortcutDisplayUsesReadableNumberKeysAndUnassignedLabel(
        string value,
        string expected)
    {
        Assert.Equal(expected, ShortcutRecorderControl.FormatHotkeyForDisplay(value));
    }
}
