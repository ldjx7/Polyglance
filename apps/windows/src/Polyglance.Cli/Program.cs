using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Polyglance.Core.Models;
using Polyglance.Core.Services;
using Polyglance.Platform.Ocr;

namespace Polyglance.Cli;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        if (args.Length == 0 || args[0] is "-h" or "--help" or "help")
        {
            PrintHelp();
            return 0;
        }

        string command = args[0].ToLowerInvariant();
        try
        {
            switch (command)
            {
                case "version" or "-v" or "--version":
                    Console.WriteLine($"Polyglance C# CLI {AppVersionDisplay.FromAssembly(typeof(Program).Assembly)}");
                    return 0;

                case "config":
                    var configStore = new ConfigurationStore();
                    var config = configStore.Load();
                    var publicConfig = JsonSerializer.SerializeToNode(config)?.AsObject()
                        ?? new JsonObject();
                    foreach (string secretName in new[] { "api_key", "deepl_auth_key", "baidu_secret_key", "youdao_secret", "volcano_access_key", "volcano_secret_key" })
                        publicConfig.Remove(secretName);
                    if (publicConfig["custom_ai_configs"] is JsonArray customConfigs)
                    {
                        foreach (JsonNode? item in customConfigs)
                            (item as JsonObject)?.Remove("api_key");
                    }
                    Console.WriteLine(publicConfig.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                    return 0;

                case "translate":
                    return await RunTranslateAsync(args);

                case "ocr":
                    return await RunOcrAsync(args);

                default:
                    Console.Error.WriteLine($"未知命令: {command}");
                    PrintHelp();
                    return 1;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"执行失败: {ex.Message}");
            return 1;
        }
    }

    private static async Task<int> RunTranslateAsync(string[] args)
    {
        string? text = null;
        string? provider = null;
        string targetLanguage = "zh-CN";
        string? sourceLanguage = null;

        for (int i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--provider" or "-p" when i + 1 < args.Length:
                    provider = args[++i];
                    break;
                case "--target" or "-t" when i + 1 < args.Length:
                    targetLanguage = args[++i];
                    break;
                case "--source" or "-s" when i + 1 < args.Length:
                    sourceLanguage = args[++i];
                    break;
                default:
                    if (!args[i].StartsWith('-'))
                    {
                        text = text == null ? args[i] : $"{text} {args[i]}";
                    }
                    break;
            }
        }

        if (string.IsNullOrWhiteSpace(text))
        {
            Console.Error.WriteLine("错误: 请指定要翻译的文本。例如: polyglance-csharp-cli translate \"Hello world\"");
            return 1;
        }

        var config = new ConfigurationStore().Load();
        using var service = new TranslationService();
        var result = await service.TranslateAsync(
            text: text,
            targetLanguage: targetLanguage,
            sourceLanguage: sourceLanguage,
            config: config,
            providerOverride: provider
        );

        Console.WriteLine(result.Text);
        return 0;
    }

    private static async Task<int> RunOcrAsync(string[] args)
    {
        string? filePath = null;
        string? engine = null;

        for (int i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--engine" or "-e" when i + 1 < args.Length:
                    engine = args[++i];
                    break;
                default:
                    if (!args[i].StartsWith('-') && filePath == null)
                    {
                        filePath = args[i];
                    }
                    break;
            }
        }

        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath))
        {
            Console.Error.WriteLine($"错误: 图片文件不存在: {filePath}");
            return 1;
        }

        var uri = new Uri(Path.GetFullPath(filePath));
        var bitmap = BitmapFrame.Create(uri, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);

        var doc = await OcrService.RecognizeDocumentAsync(bitmap, engine);
        Console.WriteLine(doc.FullText);
        return 0;
    }

    private static void PrintHelp()
    {
        Console.WriteLine("Polyglance C# CLI 命令行工具");
        Console.WriteLine();
        Console.WriteLine("用法:");
        Console.WriteLine("  polyglance-csharp-cli <命令> [参数]");
        Console.WriteLine();
        Console.WriteLine("可用命令:");
        Console.WriteLine("  translate <文本> [--provider <服务商>] [--target <目标语言>] [--source <源语言>]");
        Console.WriteLine("  ocr <图片路径> [--engine <system|ppocr>]");
        Console.WriteLine("  config");
        Console.WriteLine("  version");
    }
}
