using System.Text.Json;
using System.Text.Json.Nodes;
using Polyglance.Core.Models;

namespace Polyglance.Core.Services;

public sealed class ConfigurationStoreException : Exception
{
    public ConfigurationStoreException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

public sealed class ConfigurationStore
{
    private const string LegacyWindowsAppcastUrl =
        "https://raw.githubusercontent.com/ldjx7/Polyglance/main/appcast-windows.xml";
    private const string CurrentWindowsAppcastUrl =
        "https://github.com/ldjx7/Polyglance/releases/latest/download/appcast-windows.xml";
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private readonly string _filePath;
    private readonly ICredentialStore _credentials;

    public ConfigurationStore()
    {
        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        _filePath = Path.Combine(appData, "Polyglance", "config.json");
        _credentials = new DpapiCredentialStore(
            Path.Combine(localAppData, "Polyglance", "credentials.dat"));
    }

    public ConfigurationStore(string filePath, ICredentialStore credentials)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
        _credentials = credentials ?? throw new ArgumentNullException(nameof(credentials));
    }

    public AppConfiguration Load()
    {
        try
        {
            bool hasStoredConfiguration = File.Exists(_filePath);
            string? storedJson = hasStoredConfiguration ? File.ReadAllText(_filePath) : null;
            JsonObject? storedObject = storedJson == null ? null : JsonNode.Parse(storedJson)?.AsObject();
            AppConfiguration configuration = storedJson == null
                ? new AppConfiguration()
                : JsonSerializer.Deserialize<AppConfiguration>(storedJson) ?? new AppConfiguration();

            string legacyPlaintextKey = configuration.ApiKey.Trim();
            if (legacyPlaintextKey.Length > 0)
            {
                _credentials.Save(legacyPlaintextKey);
                configuration.ApiKey = legacyPlaintextKey;
                WriteConfiguration(configuration);
            }
            else
            {
                configuration.ApiKey = _credentials.Load()?.Trim() ?? string.Empty;
            }

            if (string.Equals(configuration.AppcastUrl, LegacyWindowsAppcastUrl, StringComparison.Ordinal))
            {
                configuration.AppcastUrl = CurrentWindowsAppcastUrl;
                WriteConfiguration(configuration);
            }

            if (GlobalShortcutDefaults.IsCompleteLegacyDefaultSet(configuration))
            {
                GlobalShortcutDefaults.ApplyRecommendedDefaults(configuration);
                WriteConfiguration(configuration);
            }
            else if (hasStoredConfiguration && storedObject != null)
            {
                // New optional actions must not become active merely because an
                // existing user upgrades. Only the complete legacy default set
                // is migrated; customized configurations retain their choices.
                if (!storedObject.ContainsKey("hotkey_pin_clipboard_image"))
                    configuration.HotkeyPinClipboardImage = "";
                if (!storedObject.ContainsKey("hotkey_screen_recording"))
                    configuration.HotkeyScreenRecording = "";
                if (!storedObject.ContainsKey("hotkey_restore_most_recent_pin"))
                    configuration.HotkeyRestoreMostRecentPin = "";
            }

            return configuration;
        }
        catch (Exception error) when (error is not ConfigurationStoreException)
        {
            throw new ConfigurationStoreException("无法读取设置或受保护凭据。", error);
        }
    }

    public void Save(AppConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        try
        {
            string apiKey = configuration.ApiKey.Trim();
            if (apiKey.Length == 0)
                _credentials.Delete();
            else
                _credentials.Save(apiKey);

            WriteConfiguration(configuration);
        }
        catch (Exception error) when (error is not ConfigurationStoreException)
        {
            throw new ConfigurationStoreException("无法保存设置或受保护凭据。", error);
        }
    }

    private void WriteConfiguration(AppConfiguration configuration)
    {
        string? directory = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(directory))
            Directory.CreateDirectory(directory);

        JsonObject json = JsonSerializer.SerializeToNode(configuration, JsonOptions)?.AsObject()
            ?? throw new JsonException("无法序列化设置。");
        json.Remove("api_key");

        string temporaryPath = $"{_filePath}.tmp.{Guid.NewGuid():N}";
        try
        {
            File.WriteAllText(temporaryPath, json.ToJsonString(JsonOptions));
            File.Move(temporaryPath, _filePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }
}
