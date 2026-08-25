using Polyglance.Platform.Capture;

namespace Polyglance.Platform.Tests;

public sealed class UnderlyingWindowScrollerTests
{
    [Fact]
    public void WheelTargetWalksFromTopLevelWindowToDeepestChild()
    {
        var root = new IntPtr(1);
        var child = new IntPtr(2);
        var grandchild = new IntPtr(3);
        var children = new Dictionary<IntPtr, IntPtr>
        {
            [root] = child,
            [child] = grandchild,
            [grandchild] = IntPtr.Zero
        };

        IntPtr target = UnderlyingWindowScroller.WalkToDeepestChild(
            root,
            window => children[window]);

        Assert.Equal(grandchild, target);
    }

    [Fact]
    public void WheelTargetStopsWhenBrokenWindowTreeReturnsItsParent()
    {
        var root = new IntPtr(10);

        IntPtr target = UnderlyingWindowScroller.WalkToDeepestChild(
            root,
            _ => root);

        Assert.Equal(root, target);
    }

    [Fact]
    public void WheelTargetStopsAtLastValidWindowWhenChildLookupFails()
    {
        var root = new IntPtr(20);
        var child = new IntPtr(21);

        IntPtr target = UnderlyingWindowScroller.WalkToDeepestChild(
            root,
            window => window == root ? child : IntPtr.Zero);

        Assert.Equal(child, target);
    }

    [Theory]
    [InlineData(120, 0x00780000L)]
    [InlineData(-120, 0xFF880000L)]
    public void WheelDeltaIsEncodedInTheHighWord(int delta, long expected)
    {
        Assert.Equal(new IntPtr(expected), UnderlyingWindowScroller.EncodeWheelWParam(delta));
    }

    [Fact]
    public void ScreenPointUsesSignedSixteenBitCoordinates()
    {
        Assert.Equal(
            new IntPtr(unchecked((300 << 16) | (ushort)-20)),
            UnderlyingWindowScroller.EncodePointLParam(-20, 300));
    }
}
