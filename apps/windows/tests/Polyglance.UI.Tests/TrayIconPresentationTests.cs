using Polyglance.UI;

namespace Polyglance.UI.Tests;

public sealed class TrayIconPresentationTests
{
    [Fact]
    public void TooltipShowsOnlyTheProductName()
    {
        Assert.Equal("Polyglance", TrayIconPresentation.TooltipText);
    }
}
