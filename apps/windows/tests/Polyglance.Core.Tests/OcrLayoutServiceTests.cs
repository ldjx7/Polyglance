using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class OcrLayoutServiceTests
{
    [Fact]
    public void MergesSameLineFragmentsIntoSingleLineWithProperSpacing()
    {
        var rawLines = new List<LayoutTextLine>
        {
            new() { Text = "<", X = 10, Y = 50, Width = 15, Height = 20 },
            new() { Text = ">", X = 35, Y = 50, Width = 15, Height = 20 },
            new() { Text = "录屏与系统录音", X = 60, Y = 50, Width = 150, Height = 20 }
        };

        var organized = OcrLayoutService.OrganizeLines(rawLines, 800, 600);

        Assert.Single(organized);
        Assert.Equal("< > 录屏与系统录音", organized[0].Text);
    }

    [Fact]
    public void PreservesTwoColumnReadingOrderWithoutInterleaving()
    {
        var rawLines = new List<LayoutTextLine>
        {
            // Left column (X: 50..200)
            new() { Text = "通用", X = 50, Y = 50, Width = 100, Height = 24 },
            new() { Text = "辅助功能", X = 50, Y = 100, Width = 100, Height = 24 },
            new() { Text = "网络", X = 50, Y = 150, Width = 100, Height = 24 },

            // Right column (X: 350..700, gutter 200..350)
            new() { Text = "隔空投送与接力", X = 350, Y = 50, Width = 200, Height = 24 },
            new() { Text = "软件更新", X = 350, Y = 100, Width = 200, Height = 24 },
            new() { Text = "存储空间", X = 350, Y = 150, Width = 200, Height = 24 }
        };

        var organized = OcrLayoutService.OrganizeLines(rawLines, 1000, 800);
        var doc = new OcrTextDocument(organized);

        Assert.Equal("通用\n辅助功能\n网络\n隔空投送与接力\n软件更新\n存储空间", doc.FullText);
    }

    [Fact]
    public void DoesNotFilterCjkShortLinesAsIcons()
    {
        var rawLines = new List<LayoutTextLine>
        {
            new() { Text = "•修复：", X = 73, Y = 316, Width = 52, Height = 18 },
            new() { Text = "1. Mac 点击 OCR 无反应：", X = 26, Y = 71, Width = 181, Height = 18 }
        };

        var organized = OcrLayoutService.OrganizeLines(rawLines, 1000, 800);
        Assert.Equal(2, organized.Count);
    }
}
