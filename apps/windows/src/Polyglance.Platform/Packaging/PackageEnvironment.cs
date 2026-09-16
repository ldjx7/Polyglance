using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Polyglance.Platform.Packaging;

public enum DistributionChannel
{
    GitHub,
    MicrosoftStore
}

public static class PackageEnvironment
{
    public const int ErrorSuccess = 0;
    public const int ErrorInsufficientBuffer = 122;
    public const int AppModelErrorNoPackage = 15700;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetCurrentPackageFullName(ref int packageFullNameLength, StringBuilder? packageFullName);

    private static bool? _isPackagedOverride;

    public static bool IsPackaged => _isPackagedOverride ?? _isPackagedDefault.Value;

    private static readonly Lazy<bool> _isPackagedDefault = new(CheckIsPackaged);

    public static DistributionChannel DistributionChannel =>
        IsPackaged ? DistributionChannel.MicrosoftStore : DistributionChannel.GitHub;

    internal static void SetPackagedOverrideForTesting(bool? isPackaged)
    {
        _isPackagedOverride = isPackaged;
    }

    private static bool CheckIsPackaged()
    {
        try
        {
            int length = 0;
            int result = GetCurrentPackageFullName(ref length, null);
            return ClassifyPackageIdentityResult(result);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[PackageEnvironment] Error querying package identity: {ex.Message}");
            return false;
        }
    }

    internal static bool ClassifyPackageIdentityResult(int result) => result switch
    {
        ErrorSuccess => true,
        ErrorInsufficientBuffer => true,
        AppModelErrorNoPackage => false,
        _ => LogAndFallback(result)
    };

    private static bool LogAndFallback(int result)
    {
        Debug.WriteLine($"[PackageEnvironment] Unexpected GetCurrentPackageFullName result: {result}. Fallback to Unpackaged.");
        return false;
    }
}
