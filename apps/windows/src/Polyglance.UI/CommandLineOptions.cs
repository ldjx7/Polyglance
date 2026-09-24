using System;
using System.Collections.Generic;

namespace Polyglance.UI;

public sealed class CommandLineOptions
{
    public bool IsCliMode { get; set; }
    public bool Capture { get; set; }
    public bool Record { get; set; }
    public bool Ocr { get; set; }
    public string? OutputPath { get; set; }
    public bool HideTranslation { get; set; }
    public bool ShowHelp { get; set; }
    public string? ConfigPath { get; set; }
    public string? ToolbarItems { get; set; }
    public bool GenerateConfig { get; set; }
    public bool InitConfig { get; set; }
    public bool DumpConfig { get; set; }

    public static CommandLineOptions Parse(string[] args)
    {
        var opts = new CommandLineOptions();
        if (args == null || args.Length == 0)
            return opts;

        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            if (string.IsNullOrWhiteSpace(arg))
                continue;

            if (arg.Equals("--capture", StringComparison.OrdinalIgnoreCase) ||
                arg.Equals("-c", StringComparison.OrdinalIgnoreCase) ||
                arg.Equals("/capture", StringComparison.OrdinalIgnoreCase))
            {
                opts.Capture = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--record", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-r", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("/record", StringComparison.OrdinalIgnoreCase))
            {
                opts.Record = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--ocr", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-o", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("/ocr", StringComparison.OrdinalIgnoreCase))
            {
                opts.Ocr = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--no-translate", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("--hide-translation", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("--white-label", StringComparison.OrdinalIgnoreCase))
            {
                opts.HideTranslation = true;
            }
            else if (arg.Equals("--config", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-cfg", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length)
                {
                    opts.ConfigPath = args[++i];
                }
            }
            else if (arg.StartsWith("--config=", StringComparison.OrdinalIgnoreCase))
            {
                opts.ConfigPath = arg.Substring("--config=".Length);
            }
            else if (arg.Equals("--toolbar", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("--tools", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length)
                {
                    opts.ToolbarItems = args[++i];
                    opts.IsCliMode = true;
                }
            }
            else if (arg.StartsWith("--toolbar=", StringComparison.OrdinalIgnoreCase))
            {
                opts.ToolbarItems = arg.Substring("--toolbar=".Length);
                opts.IsCliMode = true;
            }
            else if (arg.StartsWith("--tools=", StringComparison.OrdinalIgnoreCase))
            {
                opts.ToolbarItems = arg.Substring("--tools=".Length);
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--output", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-out", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < args.Length)
                {
                    opts.OutputPath = args[++i];
                    opts.IsCliMode = true;
                }
            }
            else if (arg.StartsWith("--output=", StringComparison.OrdinalIgnoreCase))
            {
                opts.OutputPath = arg.Substring("--output=".Length);
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--generate-config", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("--create-config", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-g", StringComparison.OrdinalIgnoreCase))
            {
                opts.GenerateConfig = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--init-config", StringComparison.OrdinalIgnoreCase))
            {
                opts.InitConfig = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--dump-config", StringComparison.OrdinalIgnoreCase))
            {
                opts.DumpConfig = true;
                opts.IsCliMode = true;
            }
            else if (arg.Equals("--help", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("-h", StringComparison.OrdinalIgnoreCase) ||
                     arg.Equals("/?", StringComparison.OrdinalIgnoreCase))
            {
                opts.ShowHelp = true;
                opts.IsCliMode = true;
            }
        }

        if (opts.IsCliMode && !opts.Capture && !opts.Record && !opts.Ocr && !opts.ShowHelp)
        {
            opts.Capture = true;
        }

        return opts;
    }

    public string SerializeToIpcCommand()
    {
        var parts = new List<string>();
        if (Capture) parts.Add("capture");
        else if (Record) parts.Add("record");
        else if (Ocr) parts.Add("ocr");

        if (!string.IsNullOrEmpty(OutputPath))
            parts.Add($"out={Uri.EscapeDataString(OutputPath)}");
        if (HideTranslation)
            parts.Add("no-translate=1");
        if (!string.IsNullOrEmpty(ConfigPath))
            parts.Add($"cfg={Uri.EscapeDataString(ConfigPath)}");
        if (!string.IsNullOrEmpty(ToolbarItems))
            parts.Add($"tools={Uri.EscapeDataString(ToolbarItems)}");

        return string.Join(";", parts);
    }

    public static CommandLineOptions DeserializeFromIpcCommand(string cmd)
    {
        var opts = new CommandLineOptions { IsCliMode = true };
        if (string.IsNullOrWhiteSpace(cmd))
            return opts;

        var parts = cmd.Split(';');
        foreach (var part in parts)
        {
            if (part.Equals("capture", StringComparison.OrdinalIgnoreCase)) opts.Capture = true;
            else if (part.Equals("record", StringComparison.OrdinalIgnoreCase)) opts.Record = true;
            else if (part.Equals("ocr", StringComparison.OrdinalIgnoreCase)) opts.Ocr = true;
            else if (part.StartsWith("out=", StringComparison.OrdinalIgnoreCase))
                opts.OutputPath = Uri.UnescapeDataString(part.Substring(4));
            else if (part.Equals("no-translate=1", StringComparison.OrdinalIgnoreCase))
                opts.HideTranslation = true;
            else if (part.StartsWith("cfg=", StringComparison.OrdinalIgnoreCase))
                opts.ConfigPath = Uri.UnescapeDataString(part.Substring(4));
            else if (part.StartsWith("tools=", StringComparison.OrdinalIgnoreCase))
                opts.ToolbarItems = Uri.UnescapeDataString(part.Substring(6));
        }
        if (!opts.Capture && !opts.Record && !opts.Ocr) opts.Capture = true;
        return opts;
    }
}
