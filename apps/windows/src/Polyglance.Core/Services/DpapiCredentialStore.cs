using System.Security.Cryptography;
using System.Text;

namespace Polyglance.Core.Services;

public interface ICredentialStore
{
    string? Load();
    void Save(string value);
    void Delete();
}

public sealed class DpapiCredentialStore : ICredentialStore
{
    private static readonly byte[] OptionalEntropy = Encoding.UTF8.GetBytes("Polyglance.CustomAI.v1");
    private readonly string _filePath;

    public DpapiCredentialStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public string? Load()
    {
        if (!File.Exists(_filePath))
            return null;

        byte[] protectedBytes = File.ReadAllBytes(_filePath);
        byte[] plaintext = ProtectedData.Unprotect(
            protectedBytes,
            OptionalEntropy,
            DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(plaintext);
    }

    public void Save(string value)
    {
        ArgumentNullException.ThrowIfNull(value);
        string? directory = Path.GetDirectoryName(_filePath);
        if (!string.IsNullOrEmpty(directory))
            Directory.CreateDirectory(directory);

        byte[] protectedBytes = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value),
            OptionalEntropy,
            DataProtectionScope.CurrentUser);

        string temporaryPath = $"{_filePath}.tmp.{Guid.NewGuid():N}";
        try
        {
            File.WriteAllBytes(temporaryPath, protectedBytes);
            File.Move(temporaryPath, _filePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
                File.Delete(temporaryPath);
        }
    }

    public void Delete()
    {
        if (File.Exists(_filePath))
            File.Delete(_filePath);
    }
}
