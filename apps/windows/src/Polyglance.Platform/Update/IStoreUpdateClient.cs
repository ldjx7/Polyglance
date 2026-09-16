using System;
using System.Threading;
using System.Threading.Tasks;

namespace Polyglance.Platform.Update;

public sealed class StoreUpdateCheckResult
{
    public bool HasUpdates { get; init; }
    public string Version { get; init; } = "";
    public string Title { get; init; } = "";
    public string Description { get; init; } = "";
    public string ErrorMessage { get; init; } = "";
    public bool IsSuccess { get; init; }

    public static StoreUpdateCheckResult NoUpdate() =>
        new() { IsSuccess = true, HasUpdates = false };

    public static StoreUpdateCheckResult UpdateAvailable(string version, string title = "", string description = "") =>
        new() { IsSuccess = true, HasUpdates = true, Version = version, Title = title, Description = description };

    public static StoreUpdateCheckResult Error(string message) =>
        new() { IsSuccess = false, HasUpdates = false, ErrorMessage = message };
}

public interface IStoreUpdateClient
{
    Task<StoreUpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default);

    Task<UpdateInstallResult> DownloadAndInstallUpdatesAsync(
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default);
}
