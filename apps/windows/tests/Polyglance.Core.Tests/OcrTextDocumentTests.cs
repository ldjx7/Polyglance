using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class OcrTextDocumentTests
{
    [Fact]
    public void FullTextPreservesLineReadingOrder()
    {
        var document = new OcrTextDocument([
            Line("Hello world", 0, 0, Word("Hello", 0, 0), Word("world", 55, 0)),
            Line("你好世界", 0, 30, Word("你好", 0, 30), Word("世界", 32, 30))
        ]);

        Assert.Equal("Hello world\n你好世界", document.FullText);
    }

    [Fact]
    public void SelectedTextReturnsOnlyIntersectingWordsInReadingOrder()
    {
        var document = new OcrTextDocument([
            Line("Hello world", 0, 0, Word("Hello", 0, 0), Word("world", 55, 0)),
            Line("你好世界", 0, 30, Word("你好", 0, 30), Word("世界", 32, 30))
        ]);

        string text = document.SelectedText(new NativeRect(50, -2, 60, 54));

        Assert.Equal("world\n世界", text);
    }

    [Fact]
    public void SelectedTextFallsBackToIntersectingLineWhenWordBoxesAreUnavailable()
    {
        var document = new OcrTextDocument([
            new LayoutTextLine
            {
                Text = "legacy OCR line",
                X = 10,
                Y = 20,
                Width = 140,
                Height = 24
            }
        ]);

        Assert.Equal("legacy OCR line", document.SelectedText(new NativeRect(20, 25, 20, 10)));
    }

    [Fact]
    public void EmptySelectionUsesAllTextLikeMacOcrSelection()
    {
        var document = new OcrTextDocument([
            Line("Copy everything", 0, 0, Word("Copy", 0, 0), Word("everything", 44, 0))
        ]);

        Assert.Equal("Copy everything", document.SelectedText(new NativeRect(0, 0, 0, 0)));
    }

    private static LayoutTextLine Line(
        string text,
        double x,
        double y,
        params LayoutTextWord[] words) => new()
    {
        Text = text,
        X = x,
        Y = y,
        Width = words.Max(word => word.X + word.Width) - x,
        Height = words.Max(word => word.Height),
        Words = [.. words]
    };

    private static LayoutTextWord Word(string text, double x, double y) => new()
    {
        Text = text,
        X = x,
        Y = y,
        Width = Math.Max(24, text.Length * 10),
        Height = 20
    };
}
