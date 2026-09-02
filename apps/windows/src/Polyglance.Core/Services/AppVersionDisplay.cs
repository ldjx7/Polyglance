using System.Reflection;

namespace Polyglance.Core.Services;

public static class AppVersionDisplay
{
    public static string FromAssembly(Assembly? assembly)
    {
        string? informationalVersion = assembly?
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;
        string? assemblyVersion = assembly?.GetName().Version?.ToString(3);
        return Format(informationalVersion, assemblyVersion);
    }

    public static string Format(string? informationalVersion, string? assemblyVersion)
    {
        string version = string.IsNullOrWhiteSpace(informationalVersion)
            ? assemblyVersion?.Trim() ?? string.Empty
            : informationalVersion.Trim();

        const string productPrefix = "Polyglance ";
        if (version.StartsWith(productPrefix, StringComparison.OrdinalIgnoreCase))
            version = version[productPrefix.Length..].TrimStart();

        if (version.StartsWith('v') || version.StartsWith('V'))
            version = version[1..];

        int metadataSeparator = version.IndexOf('+');
        if (metadataSeparator >= 0)
            version = version[..metadataSeparator];

        version = version.Trim();
        return $"v{(version.Length == 0 ? "0.0.5" : version)}";
    }
}
