using Polyglance.UI;
using Xunit;

namespace Polyglance.UI.Tests;

public class CommandLineOptionsTests
{
    [Fact]
    public void EmptyArgs_IsNotCliMode()
    {
        var opts = CommandLineOptions.Parse(Array.Empty<string>());
        Assert.False(opts.IsCliMode);
        Assert.False(opts.Capture);
        Assert.False(opts.Record);
        Assert.False(opts.Ocr);
        Assert.Null(opts.OutputPath);
    }

    [Fact]
    public void CaptureArgs_ParsesCorrectly()
    {
        var opts = CommandLineOptions.Parse(new[] { "--capture", "--no-translate" });
        Assert.True(opts.IsCliMode);
        Assert.True(opts.Capture);
        Assert.False(opts.Record);
        Assert.True(opts.HideTranslation);
    }

    [Fact]
    public void RecordArgs_ParsesCorrectly()
    {
        var opts = CommandLineOptions.Parse(new[] { "-r" });
        Assert.True(opts.IsCliMode);
        Assert.True(opts.Record);
        Assert.False(opts.Capture);
    }

    [Fact]
    public void OutputPath_ParsesCorrectly()
    {
        var opts = CommandLineOptions.Parse(new[] { "--output", @"C:\temp\screen.png" });
        Assert.True(opts.IsCliMode);
        Assert.True(opts.Capture); // defaults to capture when only output is given
        Assert.Equal(@"C:\temp\screen.png", opts.OutputPath);
    }

    [Fact]
    public void IpcSerializationRoundTrip()
    {
        var original = new CommandLineOptions
        {
            IsCliMode = true,
            Capture = true,
            OutputPath = @"D:\images\test.png",
            HideTranslation = true
        };

        string serialized = original.SerializeToIpcCommand();
        var deserialized = CommandLineOptions.DeserializeFromIpcCommand(serialized);

        Assert.True(deserialized.IsCliMode);
        Assert.True(deserialized.Capture);
        Assert.Equal(@"D:\images\test.png", deserialized.OutputPath);
        Assert.True(deserialized.HideTranslation);
    }
}
