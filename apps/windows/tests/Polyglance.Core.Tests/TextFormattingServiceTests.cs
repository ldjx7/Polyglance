using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class TextFormattingServiceTests
{
    [Fact]
    public void SmartMergeLines_MergesChineseLinesWithoutSpace()
    {
        var input = "这是一个由于换行产生的\n句子被切断了。";
        var result = TextFormattingService.SmartMergeLines(input);
        Assert.Equal("这是一个由于换行产生的句子被切断了。", result);
    }

    [Fact]
    public void SmartMergeLines_MergesEnglishLinesWithSpace()
    {
        var input = "This is a sentence that was\nbroken across lines.";
        var result = TextFormattingService.SmartMergeLines(input);
        Assert.Equal("This is a sentence that was broken across lines.", result);
    }

    [Fact]
    public void SmartMergeLines_PreservesParagraphBreaks()
    {
        var input = "第一段第一行。\n\n第二段第一行。\n第二段第二行。";
        var result = TextFormattingService.SmartMergeLines(input);
        Assert.Equal("第一段第一行。\n\n第二段第一行。\n第二段第二行。", result);
    }

    [Fact]
    public void SmartMergeLines_PreservesListItems()
    {
        var input = "说明如下：\n- 第一项内容\n- 第二项内容";
        var result = TextFormattingService.SmartMergeLines(input);
        Assert.Equal("说明如下：\n- 第一项内容\n- 第二项内容", result);
    }

    [Fact]
    public void ApplyPanguSpacing_AddsSpaceBetweenCjkAndAlphaNumeric()
    {
        var input = "使用Polyglance进行OCR识别，准确率达到99.9%以上。";
        var result = TextFormattingService.ApplyPanguSpacing(input);
        Assert.Equal("使用 Polyglance 进行 OCR 识别，准确率达到 99.9% 以上。", result);
    }

    [Fact]
    public void RemoveExtraneousSpaces_RemovesSpacesBetweenCjk()
    {
        var input = "你 好 世 界 ， 这 是 一 段 测 试 。 Hello World!";
        var result = TextFormattingService.RemoveExtraneousSpaces(input);
        Assert.Equal("你好世界，这是一段测试。Hello World!", result);
    }

    [Fact]
    public void Format_SmartMergeCombinesMergeAndPangu()
    {
        var input = "这是第一行具有OCR\n识别能力的文本。";
        var result = TextFormattingService.Format(input, TextFormattingMode.SmartMerge);
        Assert.Equal("这是第一行具有 OCR 识别能力的文本。", result);
    }

    [Fact]
    public void Format_LayoutLines_RejoinsHyphenatedWords()
    {
        var lines = new System.Collections.Generic.List<Polyglance.Core.Models.LayoutTextLine>
        {
            new() { Text = "trans-", X = 10, Y = 10, Width = 100, Height = 20 },
            new() { Text = "port", X = 10, Y = 35, Width = 100, Height = 20 }
        };
        var result = TextFormattingService.Format(lines, TextFormattingMode.SmartMerge);
        Assert.Equal("transport", result);
    }
}
