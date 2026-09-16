using System;
using System.IO;

namespace Polyglance.Core.Services;

public static class DataDirectoryManager
{
    public static string DefaultRootDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Polyglance"
    );

    private static string? _customRootDirectory;

    public static string? CustomRootDirectory
    {
        get => _customRootDirectory;
        set => _customRootDirectory = string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    public static string EffectiveRootDirectory => !string.IsNullOrWhiteSpace(_customRootDirectory)
        ? _customRootDirectory
        : DefaultRootDirectory;

    public static string ModelsDirectory => Path.Combine(EffectiveRootDirectory, "models");

    public static string HistoryDirectory => Path.Combine(EffectiveRootDirectory, "history");

    public static string TranslationHistoryFilePath => Path.Combine(HistoryDirectory, "translation_history.json");

    public static string PinHistoryDirectory => Path.Combine(EffectiveRootDirectory, "PinHistory");

    public static event Action? RootDirectoryChanged;

    public static void ApplyRootDirectory(string? customRoot)
    {
        CustomRootDirectory = customRoot;
        RootDirectoryChanged?.Invoke();
    }

    public static void Migrate(string sourceRoot, string destinationRoot)
    {
        if (string.IsNullOrWhiteSpace(sourceRoot) || string.IsNullOrWhiteSpace(destinationRoot))
            return;

        try
        {
            if (string.Equals(Path.GetFullPath(sourceRoot).TrimEnd('\\', '/'), Path.GetFullPath(destinationRoot).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))
                return;

            // 1. History
            string sourceHistoryFile = Path.Combine(sourceRoot, "history", "translation_history.json");
            string legacyHistoryFile = Path.Combine(sourceRoot, "translation_history.json");
            string destHistoryDir = Path.Combine(destinationRoot, "history");
            string destHistoryFile = Path.Combine(destHistoryDir, "translation_history.json");

            string? actualSourceHistory = File.Exists(sourceHistoryFile) ? sourceHistoryFile : (File.Exists(legacyHistoryFile) ? legacyHistoryFile : null);
            if (actualSourceHistory != null && !File.Exists(destHistoryFile))
            {
                Directory.CreateDirectory(destHistoryDir);
                File.Copy(actualSourceHistory, destHistoryFile, overwrite: false);
            }

            // 2. PinHistory
            string sourcePinDir = Path.Combine(sourceRoot, "PinHistory");
            string destPinDir = Path.Combine(destinationRoot, "PinHistory");
            if (Directory.Exists(sourcePinDir))
            {
                Directory.CreateDirectory(destPinDir);
                foreach (var file in Directory.EnumerateFiles(sourcePinDir))
                {
                    string fileName = Path.GetFileName(file);
                    string destFile = Path.Combine(destPinDir, fileName);
                    if (!File.Exists(destFile))
                    {
                        File.Copy(file, destFile, overwrite: false);
                    }
                }
            }

            // 3. Models
            string sourceModelsDir = Path.Combine(sourceRoot, "models");
            string destModelsDir = Path.Combine(destinationRoot, "models");
            if (Directory.Exists(sourceModelsDir))
            {
                CopyDirectoryRecursive(sourceModelsDir, destModelsDir);
            }
        }
        catch
        {
        }
    }

    private static void CopyDirectoryRecursive(string source, string destination)
    {
        Directory.CreateDirectory(destination);
        foreach (var file in Directory.EnumerateFiles(source))
        {
            string destFile = Path.Combine(destination, Path.GetFileName(file));
            if (!File.Exists(destFile))
            {
                File.Copy(file, destFile, overwrite: false);
            }
        }
        foreach (var subDir in Directory.EnumerateDirectories(source))
        {
            string destSubDir = Path.Combine(destination, Path.GetFileName(subDir));
            CopyDirectoryRecursive(subDir, destSubDir);
        }
    }
}
