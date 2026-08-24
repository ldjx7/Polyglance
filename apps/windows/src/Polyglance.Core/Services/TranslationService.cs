using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Polyglance.Core.Models;
using Polyglance.Core.Native;

namespace Polyglance.Core.Services;

public sealed class TranslationService : IDisposable
{
    private IntPtr _engine = IntPtr.Zero;
    private bool _disposed;

    public TranslationService()
    {
        int ret = NativeMethods.polyglance_engine_new(out _engine);
        if (ret != 0 || _engine == IntPtr.Zero)
        {
            throw new InvalidOperationException($"Failed to initialize Polyglance Rust engine (code: {ret})");
        }
    }

    public Task<TranslationResult> TranslateAsync(
        string text,
        string targetLanguage,
        string? sourceLanguage,
        AppConfiguration config)
    {
        if (_disposed || _engine == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(TranslationService));

        return Task.Run(() =>
        {
            var input = new
            {
                provider = config.Provider.ToLowerInvariant(),
                endpoint = config.Endpoint,
                api_key = config.ApiKey,
                model = config.Model,
                text = text,
                source_language = sourceLanguage,
                target_language = targetLanguage
            };

            string inputJson = JsonSerializer.Serialize(input);
            int ret = NativeMethods.polyglance_translate(_engine, inputJson, out IntPtr outPtr);
            if (ret != 0 || outPtr == IntPtr.Zero)
            {
                string friendly = ret switch
                {
                    1 => "输入文本内容无效",
                    2 => "服务配置无效，请在偏好设置中检查",
                    3 => "未配置有效 API Key（请在偏好设置中填写 OpenAI / DeepSeek 等兼容 Key）",
                    4 => "请求频次超限，请稍后重试",
                    5 => config.Provider.Contains("google", StringComparison.OrdinalIgnoreCase)
                        ? "无法直连 Google 翻译服务器（国内网络需开启代理或推荐切换至 Microsoft 翻译）"
                        : "网络连接失败，请检查网络连接或系统代理",
                    6 => "翻译服务商响应异常",
                    7 => "服务商返回内容解析失败",
                    _ => $"翻译失败 (错误码: {ret})"
                };
                throw new Exception(friendly);
            }

            try
            {
                string json = Marshal.PtrToStringUTF8(outPtr) ?? "{}";
                return JsonSerializer.Deserialize<TranslationResult>(json)
                       ?? throw new InvalidOperationException("Invalid translation response payload");
            }
            finally
            {
                NativeMethods.polyglance_free_string(outPtr);
            }
        });
    }

    public static List<LayoutParagraph> AggregateParagraphs(IReadOnlyList<LayoutTextLine> lines)
    {
        string linesJson = JsonSerializer.Serialize(lines);
        int ret = NativeMethods.polyglance_layout_paragraphs(linesJson, out IntPtr outPtr);
        if (ret != 0 || outPtr == IntPtr.Zero)
        {
            return new List<LayoutParagraph>();
        }

        try
        {
            string json = Marshal.PtrToStringUTF8(outPtr) ?? "[]";
            return JsonSerializer.Deserialize<List<LayoutParagraph>>(json) ?? new List<LayoutParagraph>();
        }
        finally
        {
            NativeMethods.polyglance_free_string(outPtr);
        }
    }

    public static List<SegmentPair> GetSentencePairs(string sourceText, string targetText)
    {
        int ret = NativeMethods.polyglance_alignment_pairs(sourceText, targetText, out IntPtr outPtr);
        if (ret != 0 || outPtr == IntPtr.Zero)
        {
            return new List<SegmentPair>();
        }

        try
        {
            string json = Marshal.PtrToStringUTF8(outPtr) ?? "[]";
            return JsonSerializer.Deserialize<List<SegmentPair>>(json) ?? new List<SegmentPair>();
        }
        finally
        {
            NativeMethods.polyglance_free_string(outPtr);
        }
    }

    public void Dispose()
    {
        if (!_disposed)
        {
            if (_engine != IntPtr.Zero)
            {
                NativeMethods.polyglance_engine_free(_engine);
                _engine = IntPtr.Zero;
            }
            _disposed = true;
        }
    }
}
