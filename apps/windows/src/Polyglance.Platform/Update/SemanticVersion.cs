namespace Polyglance.Platform.Update;

internal sealed class SemanticVersion : IComparable<SemanticVersion>
{
    private readonly string[] _prereleaseIdentifiers;

    private SemanticVersion(int major, int minor, int patch, string[] prereleaseIdentifiers)
    {
        Major = major;
        Minor = minor;
        Patch = patch;
        _prereleaseIdentifiers = prereleaseIdentifiers;
    }

    public int Major { get; }
    public int Minor { get; }
    public int Patch { get; }

    public static bool TryParse(string? value, out SemanticVersion? version)
    {
        version = null;
        if (string.IsNullOrWhiteSpace(value))
            return false;

        string normalized = value.Trim();
        if (normalized.StartsWith('v') || normalized.StartsWith('V'))
            normalized = normalized[1..];

        normalized = normalized.Split('+', 2)[0];
        string[] versionAndPrerelease = normalized.Split('-', 2);
        string[] core = versionAndPrerelease[0].Split('.');
        if (core.Length != 3
            || !int.TryParse(core[0], out int major)
            || !int.TryParse(core[1], out int minor)
            || !int.TryParse(core[2], out int patch)
            || major < 0
            || minor < 0
            || patch < 0)
        {
            return false;
        }

        string[] prereleaseIdentifiers = versionAndPrerelease.Length == 2
            ? versionAndPrerelease[1].Split('.')
            : [];
        if (prereleaseIdentifiers.Any(identifier => identifier.Length == 0))
            return false;

        version = new SemanticVersion(major, minor, patch, prereleaseIdentifiers);
        return true;
    }

    public int CompareTo(SemanticVersion? other)
    {
        if (other is null)
            return 1;

        int coreComparison = Major.CompareTo(other.Major);
        if (coreComparison == 0) coreComparison = Minor.CompareTo(other.Minor);
        if (coreComparison == 0) coreComparison = Patch.CompareTo(other.Patch);
        if (coreComparison != 0)
            return coreComparison;

        bool hasPrerelease = _prereleaseIdentifiers.Length > 0;
        bool otherHasPrerelease = other._prereleaseIdentifiers.Length > 0;
        if (!hasPrerelease && !otherHasPrerelease) return 0;
        if (!hasPrerelease) return 1;
        if (!otherHasPrerelease) return -1;

        int sharedLength = Math.Min(_prereleaseIdentifiers.Length, other._prereleaseIdentifiers.Length);
        for (int index = 0; index < sharedLength; index++)
        {
            int identifierComparison = CompareIdentifier(
                _prereleaseIdentifiers[index],
                other._prereleaseIdentifiers[index]);
            if (identifierComparison != 0)
                return identifierComparison;
        }

        return _prereleaseIdentifiers.Length.CompareTo(other._prereleaseIdentifiers.Length);
    }

    private static int CompareIdentifier(string left, string right)
    {
        bool leftIsNumeric = int.TryParse(left, out int leftNumber);
        bool rightIsNumeric = int.TryParse(right, out int rightNumber);
        if (leftIsNumeric && rightIsNumeric)
            return leftNumber.CompareTo(rightNumber);
        if (leftIsNumeric) return -1;
        if (rightIsNumeric) return 1;
        return string.Compare(left, right, StringComparison.Ordinal);
    }
}
