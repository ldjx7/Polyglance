using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Polyglance.Platform.Translation;

public sealed class MarianOnnxTranslator : IDisposable
{
    private readonly string _modelDirectory;
    private InferenceSession? _session;
    private InferenceSession? _encoderSession;
    private InferenceSession? _decoderSession;
    private readonly Dictionary<string, int> _vocab = new(StringComparer.Ordinal);
    private readonly Dictionary<int, string> _idToToken = [];
    private bool _initialized;
    private readonly object _initLock = new();

    public string ModelDirectory => _modelDirectory;

    public MarianOnnxTranslator(string modelDirectory)
    {
        _modelDirectory = modelDirectory;
    }

    public void EnsureInitialized()
    {
        if (_initialized) return;
        lock (_initLock)
        {
            if (_initialized) return;

            LoadVocabulary();
            var options = new SessionOptions();
            options.AppendExecutionProvider_CPU(0);

            string singleModel = Path.Combine(_modelDirectory, "model.onnx");
            string encoderModel = Path.Combine(_modelDirectory, "encoder.onnx");
            string decoderModel = Path.Combine(_modelDirectory, "decoder.onnx");

            if (File.Exists(singleModel))
            {
                _session = new InferenceSession(singleModel, options);
            }
            else if (File.Exists(encoderModel) && File.Exists(decoderModel))
            {
                _encoderSession = new InferenceSession(encoderModel, options);
                _decoderSession = new InferenceSession(decoderModel, options);
            }
            else
            {
                var onnxFile = Directory.EnumerateFiles(_modelDirectory, "*.onnx", SearchOption.AllDirectories).FirstOrDefault();
                if (onnxFile != null)
                {
                    _session = new InferenceSession(onnxFile, options);
                }
                else
                {
                    throw new FileNotFoundException("未在模型目录中找到 ONNX 权重文件", _modelDirectory);
                }
            }

            _initialized = true;
        }
    }

    private void LoadVocabulary()
    {
        string vocabJson = Path.Combine(_modelDirectory, "vocab.json");
        string vocabTxt = Path.Combine(_modelDirectory, "vocab.txt");

        if (File.Exists(vocabJson))
        {
            try
            {
                string content = File.ReadAllText(vocabJson);
                var dict = JsonSerializer.Deserialize<Dictionary<string, int>>(content);
                if (dict != null)
                {
                    foreach (var kvp in dict)
                    {
                        _vocab[kvp.Key] = kvp.Value;
                        _idToToken[kvp.Value] = kvp.Key;
                    }
                }
            }
            catch { }
        }
        else if (File.Exists(vocabTxt))
        {
            try
            {
                var lines = File.ReadAllLines(vocabTxt);
                for (int i = 0; i < lines.Length; i++)
                {
                    string token = lines[i].Trim();
                    if (!string.IsNullOrEmpty(token))
                    {
                        _vocab[token] = i;
                        _idToToken[i] = token;
                    }
                }
            }
            catch { }
        }
    }

    public Task<string> TranslateAsync(string text)
    {
        EnsureInitialized();

        return Task.Run(() =>
        {
            if (string.IsNullOrWhiteSpace(text)) return string.Empty;

            var tokenIds = Tokenize(text);
            if (tokenIds.Count == 0) return text;

            if (_session != null)
            {
                return RunSingleModelInference(tokenIds, text);
            }
            else if (_encoderSession != null && _decoderSession != null)
            {
                return RunEncoderDecoderInference(tokenIds, text);
            }

            return text;
        });
    }

    private string RunSingleModelInference(List<long> tokenIds, string originalText)
    {
        var inputMeta = _session!.InputMetadata;
        var inputList = new List<NamedOnnxValue>();

        var inputIdsTensor = new DenseTensor<long>(tokenIds.ToArray(), new[] { 1, tokenIds.Count });
        string inputIdsName = inputMeta.Keys.FirstOrDefault(k => k.Contains("input_ids", StringComparison.OrdinalIgnoreCase)) ?? inputMeta.Keys.First();
        inputList.Add(NamedOnnxValue.CreateFromTensor(inputIdsName, inputIdsTensor));

        string? attnMaskName = inputMeta.Keys.FirstOrDefault(k => k.Contains("attention_mask", StringComparison.OrdinalIgnoreCase));
        if (attnMaskName != null)
        {
            var mask = Enumerable.Repeat(1L, tokenIds.Count).ToArray();
            var maskTensor = new DenseTensor<long>(mask, new[] { 1, tokenIds.Count });
            inputList.Add(NamedOnnxValue.CreateFromTensor(attnMaskName, maskTensor));
        }

        using var results = _session.Run(inputList);
        var outputTensor = results.First().Value;

        if (outputTensor is DenseTensor<long> seqTensor)
        {
            var outputIds = seqTensor.ToArray();
            return Detokenize(outputIds);
        }

        return originalText;
    }

    private string RunEncoderDecoderInference(List<long> tokenIds, string originalText)
    {
        var encInputs = new List<NamedOnnxValue>();
        var inputIdsTensor = new DenseTensor<long>(tokenIds.ToArray(), new[] { 1, tokenIds.Count });
        string encInputName = _encoderSession!.InputMetadata.Keys.FirstOrDefault(k => k.Contains("input_ids", StringComparison.OrdinalIgnoreCase)) ?? _encoderSession.InputMetadata.Keys.First();
        encInputs.Add(NamedOnnxValue.CreateFromTensor(encInputName, inputIdsTensor));

        string? encMaskName = _encoderSession.InputMetadata.Keys.FirstOrDefault(k => k.Contains("attention_mask", StringComparison.OrdinalIgnoreCase));
        if (encMaskName != null)
        {
            var mask = Enumerable.Repeat(1L, tokenIds.Count).ToArray();
            encInputs.Add(NamedOnnxValue.CreateFromTensor(encMaskName, new DenseTensor<long>(mask, new[] { 1, tokenIds.Count })));
        }

        using var encResults = _encoderSession.Run(encInputs);
        var lastHiddenState = encResults.First().Value;

        var generatedTokens = new List<long>();
        long currentToken = 65000;
        if (_vocab.TryGetValue("<pad>", out int pad)) currentToken = pad;
        else if (_vocab.TryGetValue("<s>", out int bos)) currentToken = bos;

        generatedTokens.Add(currentToken);
        int maxTokens = Math.Max(32, tokenIds.Count * 3);

        for (int step = 0; step < maxTokens; step++)
        {
            var decInputs = new List<NamedOnnxValue>();
            var decIdsTensor = new DenseTensor<long>(generatedTokens.ToArray(), new[] { 1, generatedTokens.Count });
            string decInputName = _decoderSession!.InputMetadata.Keys.FirstOrDefault(k => k.Contains("input_ids", StringComparison.OrdinalIgnoreCase)) ?? _decoderSession.InputMetadata.Keys.First();
            decInputs.Add(NamedOnnxValue.CreateFromTensor(decInputName, decIdsTensor));

            string? encHiddenName = _decoderSession.InputMetadata.Keys.FirstOrDefault(k => k.Contains("encoder_hidden", StringComparison.OrdinalIgnoreCase));
            if (encHiddenName != null && lastHiddenState is DenseTensor<float> hiddenFloat)
            {
                decInputs.Add(NamedOnnxValue.CreateFromTensor(encHiddenName, hiddenFloat));
            }

            string? encAttnMaskName = _decoderSession.InputMetadata.Keys.FirstOrDefault(k => k.Contains("encoder_attention_mask", StringComparison.OrdinalIgnoreCase));
            if (encAttnMaskName != null)
            {
                var mask = Enumerable.Repeat(1L, tokenIds.Count).ToArray();
                decInputs.Add(NamedOnnxValue.CreateFromTensor(encAttnMaskName, new DenseTensor<long>(mask, new[] { 1, tokenIds.Count })));
            }

            using var decResults = _decoderSession.Run(decInputs);
            var logits = decResults.First().Value;

            if (logits is DenseTensor<float> logitsTensor)
            {
                int vocabSize = (int)logitsTensor.Dimensions[^1];
                int offset = (generatedTokens.Count - 1) * vocabSize;
                var slice = logitsTensor.Buffer.Span.Slice(offset, vocabSize);

                int bestToken = 0;
                float bestScore = float.NegativeInfinity;
                for (int i = 0; i < slice.Length; i++)
                {
                    if (slice[i] > bestScore)
                    {
                        bestScore = slice[i];
                        bestToken = i;
                    }
                }

                if (_vocab.TryGetValue("</s>", out int eos) && bestToken == eos) break;
                if (bestToken == 0) break;

                generatedTokens.Add(bestToken);
            }
            else
            {
                break;
            }
        }

        return Detokenize(generatedTokens.ToArray());
    }

    private List<long> Tokenize(string text)
    {
        var tokens = new List<long>();
        if (_vocab.Count == 0)
        {
            foreach (char c in text)
            {
                tokens.Add(c);
            }
            tokens.Add(0);
            return tokens;
        }

        if (_vocab.TryGetValue(">>cmn_Hans<<", out int cmnId))
        {
            tokens.Add(cmnId);
        }

        string spaced = text
            .Replace(",", " , ")
            .Replace(".", " . ")
            .Replace("?", " ? ")
            .Replace("!", " ! ")
            .Replace(";", " ; ")
            .Replace(":", " : ");

        string[] words = spaced.Split([' ', '\t', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        foreach (var word in words)
        {
            string piece = "\u2581" + word;
            string spacePiece = " " + word;
            if (_vocab.TryGetValue(piece, out int id))
            {
                tokens.Add(id);
            }
            else if (_vocab.TryGetValue(spacePiece, out int spId))
            {
                tokens.Add(spId);
            }
            else if (_vocab.TryGetValue(word, out int rawId))
            {
                tokens.Add(rawId);
            }
            else
            {
                for (int i = 0; i < word.Length; i++)
                {
                    string ch = word[i].ToString();
                    string chPiece = (i == 0 ? "\u2581" : "") + ch;
                    if (_vocab.TryGetValue(chPiece, out int cpId))
                    {
                        tokens.Add(cpId);
                    }
                    else if (_vocab.TryGetValue(ch, out int cId))
                    {
                        tokens.Add(cId);
                    }
                    else if (_vocab.TryGetValue("<unk>", out int unkId))
                    {
                        tokens.Add(unkId);
                    }
                }
            }
        }

        if (_vocab.TryGetValue("</s>", out int eosId))
        {
            tokens.Add(eosId);
        }
        else
        {
            tokens.Add(0);
        }

        return tokens;
    }

    private string Detokenize(long[] tokenIds)
    {
        var sb = new StringBuilder();
        foreach (long id in tokenIds)
        {
            if (_idToToken.TryGetValue((int)id, out string? token))
            {
                if (token is "<s>" or "</s>" or "<pad>" or "<unk>" or ">>cmn_Hans<<") continue;
                if (token.StartsWith("\u2581"))
                {
                    sb.Append(token.Substring(1));
                }
                else if (token.StartsWith(" "))
                {
                    if (sb.Length > 0) sb.Append(' ');
                    sb.Append(token.Substring(1));
                }
                else
                {
                    sb.Append(token);
                }
            }
            else if (_vocab.Count == 0 && id is >= 32 and <= 65535)
            {
                sb.Append((char)id);
            }
        }

        return sb.ToString().Trim();
    }

    public void Dispose()
    {
        _session?.Dispose();
        _encoderSession?.Dispose();
        _decoderSession?.Dispose();
        _session = null;
        _encoderSession = null;
        _decoderSession = null;
        _initialized = false;
    }
}
