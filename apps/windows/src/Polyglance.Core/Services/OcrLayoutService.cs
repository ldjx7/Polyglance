using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Polyglance.Core.Models;

namespace Polyglance.Core.Services;

public static class OcrLayoutService
{
    public static List<LayoutTextLine> OrganizeLines(
        IEnumerable<LayoutTextLine> rawLines,
        double imageWidth,
        double imageHeight)
    {
        var lines = rawLines
            .Where(line => !string.IsNullOrWhiteSpace(line.Text) && line.Width > 0 && line.Height > 0)
            .ToList();

        if (lines.Count == 0)
        {
            return [];
        }

        double medianHeight = CalculateMedianHeight(lines);
        lines = lines.Where(l => !IsIconArtifact(l, medianHeight)).ToList();
        if (lines.Count == 0)
        {
            return [];
        }

        var blocks = PartitionIntoBlocks(lines, imageWidth, imageHeight, medianHeight);

        var result = new List<LayoutTextLine>();
        foreach (var block in blocks)
        {
            var blockLines = ClusterLinesInBlock(block, medianHeight);
            result.AddRange(blockLines);
        }

        return result;
    }

    private static double CalculateMedianHeight(List<LayoutTextLine> lines)
    {
        var heights = lines.Select(l => l.Height).Where(h => h > 0).OrderBy(h => h).ToList();
        if (heights.Count == 0) return 20.0;
        return heights[heights.Count / 2];
    }

    private static List<List<LayoutTextLine>> PartitionIntoBlocks(
        List<LayoutTextLine> lines,
        double imageWidth,
        double imageHeight,
        double medianHeight)
    {
        if (lines.Count < 4)
        {
            return [lines];
        }

        double minX = lines.Min(l => l.X);
        double maxX = lines.Max(l => l.X + l.Width);
        double totalWidth = maxX - minX;

        if (totalWidth < Math.Max(imageWidth * 0.25, medianHeight * 5.0))
        {
            return [lines];
        }

        double minGutterWidth = Math.Max(imageWidth * 0.025, medianHeight * 1.2);
        var sortedByX = lines.OrderBy(l => l.X).ToList();

        (List<LayoutTextLine> Left, List<LayoutTextLine> Right, List<LayoutTextLine> Headers, List<LayoutTextLine> Footers, double GutterWidth)? bestSplit = null;

        for (int i = 0; i < sortedByX.Count - 1; i++)
        {
            double leftCandidateMaxX = sortedByX.Take(i + 1).Max(l => l.X + l.Width);
            double rightCandidateMinX = sortedByX.Skip(i + 1).Min(l => l.X);
            double gutter = rightCandidateMinX - leftCandidateMaxX;

            if (gutter < minGutterWidth) continue;

            double gStart = leftCandidateMaxX;
            double gEnd = rightCandidateMinX;

            var crossing = lines.Where(l => l.X < gEnd && l.X + l.Width > gStart).ToList();
            var leftItems = lines.Where(l => l.X + l.Width <= gStart).ToList();
            var rightItems = lines.Where(l => l.X >= gEnd).ToList();

            if (leftItems.Count < 2 || rightItems.Count < 2) continue;

            double leftMinY = leftItems.Min(l => l.Y);
            double leftMaxY = leftItems.Max(l => l.Y + l.Height);
            double rightMinY = rightItems.Min(l => l.Y);
            double rightMaxY = rightItems.Max(l => l.Y + l.Height);

            // In Y-down coordinates, top is MinY, bottom is MaxY
            double columnTopY = Math.Max(leftMinY, rightMinY);
            double columnBottomY = Math.Min(leftMaxY, rightMaxY);
            double verticalOverlap = columnBottomY - columnTopY;

            if (columnBottomY <= columnTopY || verticalOverlap < Math.Max(imageHeight * 0.04, medianHeight * 1.8))
            {
                continue;
            }

            var headers = crossing.Where(l => l.Y + l.Height <= columnTopY + medianHeight * 0.5).ToList();
            var footers = crossing.Where(l => l.Y >= columnBottomY - medianHeight * 0.5).ToList();

            if (headers.Count + footers.Count != crossing.Count)
            {
                continue;
            }

            double leftWidth = leftItems.Max(l => l.X + l.Width) - leftItems.Min(l => l.X);
            double rightWidth = rightItems.Max(l => l.X + l.Width) - rightItems.Min(l => l.X);

            if (leftWidth < Math.Max(imageWidth * 0.10, medianHeight * 2.0) ||
                rightWidth < Math.Max(imageWidth * 0.10, medianHeight * 2.0))
            {
                continue;
            }

            if (bestSplit == null || gutter > bestSplit.Value.GutterWidth)
            {
                bestSplit = (leftItems, rightItems, headers, footers, gutter);
            }
        }

        if (bestSplit.HasValue)
        {
            var result = new List<List<LayoutTextLine>>();
            if (bestSplit.Value.Headers.Count > 0)
            {
                result.Add(bestSplit.Value.Headers);
            }
            result.AddRange(PartitionIntoBlocks(bestSplit.Value.Left, imageWidth, imageHeight, medianHeight));
            result.AddRange(PartitionIntoBlocks(bestSplit.Value.Right, imageWidth, imageHeight, medianHeight));
            if (bestSplit.Value.Footers.Count > 0)
            {
                result.Add(bestSplit.Value.Footers);
            }
            return result;
        }

        return [lines];
    }

    private static List<LayoutTextLine> ClusterLinesInBlock(
        List<LayoutTextLine> lines,
        double medianHeight)
    {
        if (lines.Count == 0) return [];

        // Sort top to bottom (Y ascending in Y-down space)
        var topToBottom = lines.OrderBy(l => l.Y).ThenBy(l => l.X).ToList();

        var clusters = new List<List<LayoutTextLine>>();
        foreach (var line in topToBottom)
        {
            bool added = false;
            foreach (var cluster in clusters)
            {
                if (BelongsToSameVisualLine(cluster, line, medianHeight))
                {
                    cluster.Add(line);
                    added = true;
                    break;
                }
            }

            if (!added)
            {
                clusters.Add([line]);
            }
        }

        // Sort clusters by average Y
        var sortedClusters = clusters
            .OrderBy(c => c.Average(l => l.Y + l.Height / 2.0))
            .ToList();

        var output = new List<LayoutTextLine>();
        foreach (var cluster in sortedClusters)
        {
            output.Add(MergeClusterIntoSingleLine(cluster));
        }

        return output;
    }

    private static bool BelongsToSameVisualLine(List<LayoutTextLine> cluster, LayoutTextLine candidate, double medianHeight)
    {
        double clusterMinY = cluster.Min(l => l.Y);
        double clusterMaxY = cluster.Max(l => l.Y + l.Height);
        double clusterHeight = clusterMaxY - clusterMinY;

        double candMinY = candidate.Y;
        double candMaxY = candidate.Y + candidate.Height;
        double candHeight = candidate.Height;

        double overlap = Math.Min(clusterMaxY, candMaxY) - Math.Max(clusterMinY, candMinY);
        double shortestHeight = Math.Min(clusterHeight, candHeight);

        bool verticalMatch = (shortestHeight > 0 && overlap >= shortestHeight * 0.45) ||
                             (Math.Abs((clusterMinY + clusterMaxY) / 2.0 - (candMinY + candMaxY) / 2.0) <= Math.Max(clusterHeight, candHeight) * 0.35);

        if (!verticalMatch) return false;

        double clusterMinX = cluster.Min(l => l.X);
        double clusterMaxX = cluster.Max(l => l.X + l.Width);
        double gap;
        if (candidate.X >= clusterMaxX)
            gap = candidate.X - clusterMaxX;
        else if (candidate.X + candidate.Width <= clusterMinX)
            gap = clusterMinX - (candidate.X + candidate.Width);
        else
            gap = 0;

        double maxAllowedGap = Math.Max(medianHeight * 2.5, 45.0);
        return gap <= maxAllowedGap;
    }

    private static LayoutTextLine MergeClusterIntoSingleLine(List<LayoutTextLine> cluster)
    {
        var sorted = cluster.OrderBy(l => l.X).ToList();
        if (sorted.Count == 1)
        {
            return sorted[0];
        }

        var fullText = new StringBuilder();
        var allWords = new List<LayoutTextWord>();
        double minX = sorted.Min(l => l.X);
        double minY = sorted.Min(l => l.Y);
        double maxX = sorted.Max(l => l.X + l.Width);
        double maxY = sorted.Max(l => l.Y + l.Height);

        for (int i = 0; i < sorted.Count; i++)
        {
            var cur = sorted[i];
            string separator = "";

            if (i > 0)
            {
                var prev = sorted[i - 1];
                double gap = cur.X - (prev.X + prev.Width);
                double lineHeight = Math.Min(prev.Height, cur.Height);
                separator = SeparatorBetween(fullText.ToString(), cur.Text, gap, lineHeight);
            }

            fullText.Append(separator);
            fullText.Append(cur.Text);

            if (cur.Words.Count > 0)
            {
                allWords.AddRange(cur.Words);
            }
            else
            {
                allWords.Add(new LayoutTextWord
                {
                    Text = cur.Text,
                    X = cur.X,
                    Y = cur.Y,
                    Width = cur.Width,
                    Height = cur.Height
                });
            }
        }

        return new LayoutTextLine
        {
            Text = fullText.ToString(),
            X = minX,
            Y = minY,
            Width = maxX - minX,
            Height = maxY - minY,
            Words = allWords
        };
    }

    private static string SeparatorBetween(string leftText, string rightText, double gap, double lineHeight)
    {
        if (string.IsNullOrEmpty(leftText) || string.IsNullOrEmpty(rightText))
            return "";

        char lastChar = leftText[^1];
        char firstChar = rightText[0];

        if (char.IsWhiteSpace(lastChar) || char.IsWhiteSpace(firstChar))
            return "";

        bool isLeftCjk = TextFormattingService.IsCjk(lastChar);
        bool isRightCjk = TextFormattingService.IsCjk(firstChar);

        if (IsPunctuation(firstChar))
            return "";

        double relGap = lineHeight > 0 ? gap / lineHeight : gap;

        if (isLeftCjk && isRightCjk)
        {
            if (relGap >= 0.75)
                return " ";
            return "";
        }

        if ((isLeftCjk && !isRightCjk) || (!isLeftCjk && isRightCjk))
        {
            return " ";
        }

        if (relGap >= 0.15 || (char.IsLetter(lastChar) && char.IsLetter(firstChar)) || (char.IsDigit(lastChar) && char.IsLetter(firstChar)))
        {
            return " ";
        }

        return "";
    }

    private static bool IsPunctuation(char c) =>
        c is ',' or '.' or '!' or '?' or ';' or ':' or ')' or ']' or '}' or
             '、' or '，' or '。' or '！' or '？' or '；' or '：' or '）' or '】' or '”' or '’';

    private static bool IsIconArtifact(LayoutTextLine line, double medianHeight)
    {
        string text = line.Text.Trim();
        if (string.IsNullOrEmpty(text)) return true;

        if (text.Any(c => c >= '\u3400' && c <= '\u9FFF')) return false;
        if (text.Length >= 3 && text.Any(char.IsLetterOrDigit)) return false;

        double aspectRatio = line.Width / Math.Max(1.0, line.Height);
        bool isRoughlySquare = aspectRatio >= 0.55 && aspectRatio <= 1.55;
        bool isSmallBox = (line.Width <= 48 && line.Height <= 48) || (line.Height <= medianHeight * 1.5 && line.Width <= medianHeight * 1.6);

        if (isRoughlySquare && isSmallBox)
        {
            if (text.Length <= 2 && (text == "@" || text == "~"))
                return true;

            if (text.Length == 1 && char.IsLetter(text[0]) && text[0] < 0x2E80)
                return true;
        }

        return false;
    }
}
