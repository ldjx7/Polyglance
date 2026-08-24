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
}
