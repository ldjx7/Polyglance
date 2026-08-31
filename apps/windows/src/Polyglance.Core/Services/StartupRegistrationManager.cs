using System;

namespace Polyglance.Core.Services;

public interface IStartupValueStore
{
    string? Read(string name);
    void Write(string name, string value);
    void Delete(string name);
}

public sealed class StartupRegistrationManager
{
    public const string ValueName = "Polyglance";

    private readonly IStartupValueStore _store;

    public StartupRegistrationManager(IStartupValueStore store, string executablePath)
    {
        ArgumentNullException.ThrowIfNull(store);

        string normalizedPath = executablePath?.Trim() ?? string.Empty;
        if (normalizedPath.Length == 0 || normalizedPath.Contains('"'))
        {
            throw new ArgumentException("A valid executable path is required.", nameof(executablePath));
        }

        _store = store;
        StartupCommand = $"\"{normalizedPath}\" --autostart";
    }

    public string StartupCommand { get; }

    public bool IsEnabled => string.Equals(
        _store.Read(ValueName),
        StartupCommand,
        StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Preserves an existing startup preference when an update changes the
    /// installation directory or replaces the legacy Polyglance.UI.exe name.
    /// Unknown commands are never adopted or overwritten.
    /// </summary>
    public bool RefreshRegistration()
    {
        string? registeredCommand = _store.Read(ValueName);
        if (string.Equals(registeredCommand, StartupCommand, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (!IsRecognizedPolyglanceCommand(registeredCommand))
        {
            return false;
        }

        _store.Write(ValueName, StartupCommand);
        return true;
    }

    public void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            _store.Write(ValueName, StartupCommand);
        }
        else
        {
            _store.Delete(ValueName);
        }
    }

    private static bool IsRecognizedPolyglanceCommand(string? command)
    {
        string trimmed = command?.Trim() ?? string.Empty;
        if (trimmed.Length < 3 || trimmed[0] != '"')
        {
            return false;
        }

        int closingQuote = trimmed.IndexOf('"', 1);
        if (closingQuote <= 1)
        {
            return false;
        }

        string arguments = trimmed[(closingQuote + 1)..].Trim();
        if (arguments.Length > 0
            && !arguments.Equals("--autostart", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string executablePath = trimmed[1..closingQuote];
        int separator = Math.Max(
            executablePath.LastIndexOf('\\'),
            executablePath.LastIndexOf('/'));
        string executableName = executablePath[(separator + 1)..];
        return executableName.Equals("Polyglance.exe", StringComparison.OrdinalIgnoreCase)
            || executableName.Equals("Polyglance.UI.exe", StringComparison.OrdinalIgnoreCase);
    }
}
