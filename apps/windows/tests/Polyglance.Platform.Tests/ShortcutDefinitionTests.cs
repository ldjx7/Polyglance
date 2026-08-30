using Polyglance.Platform.HotKey;
using Polyglance.Platform.Interop;

namespace Polyglance.Platform.Tests;

public sealed class ShortcutDefinitionTests
{
    [Theory]
    [InlineData("Ctrl+Shift+D1", 0x31)]
    [InlineData("Ctrl+Shift+1", 0x31)]
    [InlineData("Alt+A", 0x41)]
    [InlineData("Ctrl+OemComma", 0xBC)]
    [InlineData("Ctrl+NumPad5", 0x65)]
    [InlineData("Ctrl+F5", 0x74)]
    public void RecordedKeyNamesResolveToVirtualKeyCodes(string value, uint expectedVirtualKey)
    {
        Assert.True(ShortcutDefinition.TryParse(value, out ShortcutDefinition? definition, out _));
        Assert.Equal(expectedVirtualKey, definition!.VirtualKey);
    }

    [Fact]
    public void ModifiersAccumulateIntoTheRegisterHotKeyMask()
    {
        Assert.True(ShortcutDefinition.TryParse("Ctrl+Alt+Shift+Win+K", out ShortcutDefinition? definition, out _));

        Assert.Equal(
            NativeWin32.MOD_CONTROL | NativeWin32.MOD_ALT | NativeWin32.MOD_SHIFT | NativeWin32.MOD_WIN,
            definition!.Modifiers);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("Ctrl+Alt")]
    [InlineData("A")]
    [InlineData("Shift+A")]
    [InlineData("Ctrl+ImeProcessed")]
    [InlineData("Ctrl+12")]
    [InlineData("Ctrl+A+B")]
    public void UnregistrableShortcutsAreRejectedWithAReason(string value)
    {
        Assert.False(ShortcutDefinition.TryParse(value, out ShortcutDefinition? definition, out string? error));
        Assert.Null(definition);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void SpacedShortcutStringsFromOlderConfigurationsStillParse()
    {
        Assert.True(ShortcutDefinition.TryParse("Ctrl + Shift + D4", out ShortcutDefinition? definition, out _));

        Assert.Equal(NativeWin32.MOD_CONTROL | NativeWin32.MOD_SHIFT, definition!.Modifiers);
        Assert.Equal((uint)0x34, definition.VirtualKey);
    }
}
