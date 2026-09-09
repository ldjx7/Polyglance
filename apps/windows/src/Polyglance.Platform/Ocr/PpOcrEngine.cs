using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Polyglance.Core.Models;
using Polyglance.Core.Services;

namespace Polyglance.Platform.Ocr;

public sealed class PpOcrEngine : IOcrEngine, IDisposable
{
    public string Id => "ppocr";
    public string DisplayName => "PP-OCRv4 离线模型 (ONNX)";

    private readonly string? _detPath;
    private readonly string? _recPath;
    private readonly string? _keysPath;
    private readonly List<string> _keys = [];
    private InferenceSession? _detSession;
    private InferenceSession? _recSession;
    private bool _initialized;
    private readonly object _initLock = new();

    public bool IsAvailable => _detPath != null && _recPath != null && _keysPath != null;

    public PpOcrEngine()
    {
        string[] searchPaths =
        [
            Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "models", "ocr"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Polyglance", "models", "ocr")
        ];

        foreach (var dir in searchPaths)
        {
            if (!Directory.Exists(dir)) continue;

            string? det = FindFile(dir, "det.onnx", "ch_PP-OCRv4_det_infer.onnx");
            string? rec = FindFile(dir, "rec.onnx", "ch_PP-OCRv4_rec_infer.onnx");
            string? keys = FindFile(dir, "keys.txt", "ppocr_keys_v1.txt");

            if (det != null && rec != null && keys != null)
            {
                _detPath = det;
                _recPath = rec;
                _keysPath = keys;
                break;
            }
        }
    }

    private static string? FindFile(string dir, params string[] names)
    {
        foreach (var name in names)
        {
            string fullPath = Path.Combine(dir, name);
            if (File.Exists(fullPath))
            {
                return fullPath;
            }
        }
        return null;
    }

    private void EnsureInitialized()
    {
        if (_initialized) return;

        lock (_initLock)
        {
            if (_initialized) return;

            if (!IsAvailable)
            {
                throw new InvalidOperationException("PP-OCRv4 离线模型文件未找到。");
            }

            var sessionOptions = new SessionOptions
            {
                GraphOptimizationLevel = GraphOptimizationLevel.ORT_ENABLE_ALL,
                InterOpNumThreads = Environment.ProcessorCount,
                IntraOpNumThreads = Environment.ProcessorCount
            };

            _detSession = new InferenceSession(_detPath!, sessionOptions);
            _recSession = new InferenceSession(_recPath!, sessionOptions);

            _keys.Clear();
            _keys.Add(""); // 0th index is CTC blank
            foreach (var line in File.ReadAllLines(_keysPath!))
            {
                _keys.Add(line);
            }
            _keys.Add(" "); // Space token

            _initialized = true;
        }
    }

    public Task<OcrTextDocument> RecognizeDocumentAsync(BitmapSource bitmap)
    {
        EnsureInitialized();

        return Task.Run(() =>
        {
            int width = bitmap.PixelWidth;
            int height = bitmap.PixelHeight;

            var bgra = new byte[width * height * 4];
            bitmap.CopyPixels(bgra, width * 4, 0);

            // DBNet detection
            var boxes = DetectBoxes(bgra, width, height);
            if (boxes.Count == 0)
            {
                return new OcrTextDocument([]);
            }

            // Text recognition
            var lines = new List<LayoutTextLine>();
            foreach (var box in boxes)
            {
                string text = RecognizeBox(bgra, width, height, box);
                if (string.IsNullOrWhiteSpace(text)) continue;

                var words = SubdivideCjkWords(text, box.X, box.Y, box.Width, box.Height);
                lines.Add(new LayoutTextLine
                {
                    Text = text,
                    X = box.X,
                    Y = box.Y,
                    Width = box.Width,
                    Height = box.Height,
                    Words = words
                });
            }

            var organizedLines = OcrLayoutService.OrganizeLines(lines, width, height);
            return new OcrTextDocument(organizedLines);
        });
    }

    private List<NativeRect> DetectBoxes(byte[] bgra, int width, int height)
    {
        // Resize to 32 multiple, max dimension 960
        int maxSide = Math.Max(width, height);
        double scale = maxSide > 960 ? (960.0 / maxSide) : 1.0;
        int targetW = Math.Max(32, ((int)(width * scale) / 32) * 32);
        int targetH = Math.Max(32, ((int)(height * scale) / 32) * 32);

        var tensor = new DenseTensor<float>([1, 3, targetH, targetW]);
        double scaleX = (double)width / targetW;
        double scaleY = (double)height / targetH;

        // ImageNet normalization: (x / 255 - mean) / std
        float meanR = 0.485f, meanG = 0.456f, meanB = 0.406f;
        float stdR = 0.229f, stdG = 0.224f, stdB = 0.225f;

        for (int ty = 0; ty < targetH; ty++)
        {
            int sy = Math.Min(height - 1, (int)(ty * scaleY));
            int srcRow = sy * width * 4;
            for (int tx = 0; tx < targetW; tx++)
            {
                int sx = Math.Min(width - 1, (int)(tx * scaleX));
                int srcIdx = srcRow + sx * 4;

                float b = bgra[srcIdx] / 255.0f;
                float g = bgra[srcIdx + 1] / 255.0f;
                float r = bgra[srcIdx + 2] / 255.0f;

                tensor[0, 0, ty, tx] = (r - meanR) / stdR;
                tensor[0, 1, ty, tx] = (g - meanG) / stdG;
                tensor[0, 2, ty, tx] = (b - meanB) / stdB;
            }
        }

        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor(_detSession!.InputMetadata.Keys.First(), tensor)
        };

        using var outputs = _detSession.Run(inputs);
        var pred = outputs.First().AsTensor<float>();

        // Find connected bounding components from thresholded mask (> 0.3)
        var visited = new bool[targetH, targetW];
        var rawBoxes = new List<NativeRect>();

        for (int y = 0; y < targetH; y++)
        {
            for (int x = 0; x < targetW; x++)
            {
                if (pred[0, 0, y, x] > 0.3f && !visited[y, x])
                {
                    int minBx = x, maxBx = x, minBy = y, maxBy = y;
                    var queue = new Queue<(int X, int Y)>();
                    queue.Enqueue((x, y));
                    visited[y, x] = true;

                    while (queue.Count > 0)
                    {
                        var (cx, cy) = queue.Dequeue();
                        minBx = Math.Min(minBx, cx);
                        maxBx = Math.Max(maxBx, cx);
                        minBy = Math.Min(minBy, cy);
                        maxBy = Math.Max(maxBy, cy);

                        int[] dx = [0, 1, 0, -1];
                        int[] dy = [-1, 0, 1, 0];
                        for (int i = 0; i < 4; i++)
                        {
                            int nx = cx + dx[i];
                            int ny = cy + dy[i];
                            if (nx >= 0 && nx < targetW && ny >= 0 && ny < targetH && !visited[ny, nx] && pred[0, 0, ny, nx] > 0.3f)
                            {
                                visited[ny, nx] = true;
                                queue.Enqueue((nx, ny));
                            }
                        }
                    }

                    int bw = maxBx - minBx + 1;
                    int bh = maxBy - minBy + 1;
                    if (bw >= 3 && bh >= 3)
                    {
                        float sumScore = 0f;
                        int count = 0;
                        for (int py = minBy; py <= maxBy; py++)
                        {
                            for (int px = minBx; px <= maxBx; px++)
                            {
                                if (visited[py, px])
                                {
                                    sumScore += pred[0, 0, py, px];
                                    count++;
                                }
                            }
                        }
                        float avgBoxScore = count > 0 ? sumScore / count : 0f;
                        if (avgBoxScore < 0.50f) continue;

                        double unclip = Math.Min(bh * 0.4, 4.0);
                        double unclipX = unclip;
                        double unclipY = unclip;
                        double origX = Math.Max(0, (minBx - unclipX) * scaleX);
                        double origY = Math.Max(0, (minBy - unclipY) * scaleY);
                        double origW = Math.Min(width - origX, (bw + unclipX * 2) * scaleX);
                        double origH = Math.Min(height - origY, (bh + unclipY * 2) * scaleY);

                        rawBoxes.Add(new NativeRect(origX, origY, origW, origH));
                    }
                }
            }
        }

        return rawBoxes;
    }

    private string RecognizeBox(byte[] bgra, int width, int height, NativeRect box)
    {
        int bx = Math.Max(0, (int)box.X);
        int by = Math.Max(0, (int)box.Y);
        int bw = Math.Min(width - bx, (int)box.Width);
        int bh = Math.Min(height - by, (int)box.Height);
        if (bw < 2 || bh < 2) return "";

        int recH = 48;
        int recW = Math.Max(16, (int)(48.0 * bw / bh));
        var tensor = new DenseTensor<float>([1, 3, recH, recW]);

        double scaleX = (double)bw / recW;
        double scaleY = (double)bh / recH;

        for (int ty = 0; ty < recH; ty++)
        {
            int sy = by + Math.Min(bh - 1, (int)(ty * scaleY));
            int srcRow = sy * width * 4;
            for (int tx = 0; tx < recW; tx++)
            {
                int sx = bx + Math.Min(bw - 1, (int)(tx * scaleX));
                int srcIdx = srcRow + sx * 4;

                // Normalize: (pixel / 255 - 0.5) / 0.5
                tensor[0, 0, ty, tx] = (bgra[srcIdx + 2] / 255.0f - 0.5f) / 0.5f;
                tensor[0, 1, ty, tx] = (bgra[srcIdx + 1] / 255.0f - 0.5f) / 0.5f;
                tensor[0, 2, ty, tx] = (bgra[srcIdx] / 255.0f - 0.5f) / 0.5f;
            }
        }

        var inputs = new List<NamedOnnxValue>
        {
            NamedOnnxValue.CreateFromTensor(_recSession!.InputMetadata.Keys.First(), tensor)
        };

        using var outputs = _recSession.Run(inputs);
        var pred = outputs.First().AsTensor<float>();

        // CTC greedy decode
        int timeSteps = pred.Dimensions[1];
        int numClasses = pred.Dimensions[2];

        var chars = new List<string>();
        int lastIdx = -1;

        float totalScore = 0f;
        int scoreCount = 0;

        for (int t = 0; t < timeSteps; t++)
        {
            int maxIdx = 0;
            float maxVal = pred[0, t, 0];
            for (int c = 1; c < numClasses; c++)
            {
                if (pred[0, t, c] > maxVal)
                {
                    maxVal = pred[0, t, c];
                    maxIdx = c;
                }
            }

            if (maxIdx > 0 && maxIdx != lastIdx)
            {
                if (maxIdx < _keys.Count)
                {
                    chars.Add(_keys[maxIdx]);
                    totalScore += maxVal;
                    scoreCount++;
                }
            }
            lastIdx = maxIdx;
        }

        float avgScore = scoreCount > 0 ? totalScore / scoreCount : 0f;
        string resultText = string.Concat(chars).Trim();
        if (string.IsNullOrEmpty(resultText)) return "";

        if (IsIconOrNoiseArtifact(resultText, box.Width, box.Height, avgScore))
        {
            return "";
        }

        if (resultText.Length >= 3)
        {
            if (resultText.StartsWith("@") || resultText.StartsWith("~") || resultText.StartsWith("^") || resultText.StartsWith("•"))
            {
                resultText = resultText[1..].Trim();
            }
            if (resultText.EndsWith("~") || resultText.EndsWith("^") || resultText.EndsWith("•"))
            {
                resultText = resultText[..^1].Trim();
            }
        }

        resultText = CleanIconArtifacts(resultText);

        return resultText;
    }

    private static string CleanIconArtifacts(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        text = System.Text.RegularExpressions.Regex.Replace(
            text,
            @"([:：•·\-\*]\s*)([A-Za-z@~^#])\s+([A-Z][a-zA-Z0-9_\.]+|\w+\.(?:swift|cs|rs|py|js|ts|cpp|c|h|java|kt|go|html|css|json|xml|md)\b)",
            "$1$3");
        text = System.Text.RegularExpressions.Regex.Replace(
            text,
            @"^(\s*)([A-Za-z@~^#])\s+([A-Z][a-zA-Z0-9_\.]+|\w+\.(?:swift|cs|rs|py|js|ts|cpp|c|h|java|kt|go|html|css|json|xml|md)\b)",
            "$1$3");
        return text;
    }

    private static bool IsIconOrNoiseArtifact(string text, double width, double height, float avgScore)
    {
        if (string.IsNullOrWhiteSpace(text)) return true;

        if (text.Any(c => c >= '\u3400' && c <= '\u9FFF')) return false;
        if (text.Length >= 3 && text.Any(char.IsLetterOrDigit)) return false;

        if (avgScore < 0.40f) return true;

        double aspectRatio = width / Math.Max(1.0, height);
        bool isRoughlySquare = aspectRatio >= 0.55 && aspectRatio <= 1.55;
        bool isSmallBox = width <= 48 && height <= 48;

        if (text.Length <= 2)
        {
            if (isRoughlySquare && isSmallBox)
            {
                if (text.All(c => !char.IsLetterOrDigit(c))) return true;

                if (text.Length == 1 && text[0] < 0x2E80)
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static List<LayoutTextWord> SubdivideCjkWords(string text, double x, double y, double width, double height)
    {
        var words = new List<LayoutTextWord>();
        if (string.IsNullOrEmpty(text)) return words;

        double charWidth = width / text.Length;
        for (int i = 0; i < text.Length; i++)
        {
            words.Add(new LayoutTextWord
            {
                Text = text[i].ToString(),
                X = x + i * charWidth,
                Y = y,
                Width = Math.Max(1.0, charWidth),
                Height = height
            });
        }
        return words;
    }

    public void Dispose()
    {
        _detSession?.Dispose();
        _recSession?.Dispose();
        _detSession = null;
        _recSession = null;
        _initialized = false;
    }
}
