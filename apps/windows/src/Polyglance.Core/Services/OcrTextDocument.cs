using System.Text;
using Polyglance.Core.Models;

namespace Polyglance.Core.Services;

/// <summary>
/// Platform-neutral OCR result used by the selectable OCR UI on both normal
/// screenshots and stitched screenshots.
/// </summary>
public sealed class OcrTextDocument
{
    public OcrTextDocument(IEnumerable<LayoutTextLine> lines)
    {
        Lines = [.. lines];
    }

    public IReadOnlyList<LayoutTextLine> Lines { get; }

    public string FullText => string.Join(
        "\n",
        Lines.Select(line => line.Text.Trim()).Where(text => text.Length > 0));

    /// <summary>
    /// Returns content intersecting the drag selection in reading order. An
    /// empty selection means all text, matching the macOS OCR result window.
    /// </summary>
    public string SelectedText(NativeRect selection)
    {
        if (selection.Width <= 0 || selection.Height <= 0)
        {
            return FullText;
        }

        var selectedLines = new List<string>();
        foreach (var line in Lines)
        {
            var selectedWords = line.Words
                .Where(word => Intersects(selection, word.X, word.Y, word.Width, word.Height))
                .Select(word => word.Text.Trim())
                .Where(text => text.Length > 0)
                .ToList();

            if (selectedWords.Count > 0)
            {
                selectedLines.Add(JoinWords(selectedWords));
            }
            else if (line.Words.Count == 0
                     && Intersects(selection, line.X, line.Y, line.Width, line.Height)
                     && !string.IsNullOrWhiteSpace(line.Text))
            {
                selectedLines.Add(line.Text.Trim());
            }
        }

        return string.Join("\n", selectedLines);
    }

    private static bool Intersects(
        NativeRect selection,
        double x,
        double y,
        double width,
        double height)
    {
        double left = Math.Min(selection.X, selection.X + selection.Width);
        double top = Math.Min(selection.Y, selection.Y + selection.Height);
        double right = Math.Max(selection.X, selection.X + selection.Width);
        double bottom = Math.Max(selection.Y, selection.Y + selection.Height);
        return x < right && x + width > left && y < bottom && y + height > top;
    }

    private static string JoinWords(IReadOnlyList<string> words)
    {
        var result = new StringBuilder();
        for (int index = 0; index < words.Count; index++)
        {
            if (index > 0 && NeedsSpace(words[index - 1], words[index]))
            {
                result.Append(' ');
            }
            result.Append(words[index]);
        }
        return result.ToString();
    }

    private static bool NeedsSpace(string left, string right) =>
        left.Length > 0
        && right.Length > 0
        && !IsCjk(left[^1])
        && !IsCjk(right[0])
        && !char.IsPunctuation(right[0]);

    private static bool IsCjk(char value) =>
        value is >= '\u3400' and <= '\u9FFF'
        or >= '\uF900' and <= '\uFAFF';
}
