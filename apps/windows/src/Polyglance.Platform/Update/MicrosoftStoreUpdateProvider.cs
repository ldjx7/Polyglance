using System;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;

namespace Polyglance.Platform.Update;

public sealed class MicrosoftStoreUpdateProvider : IAppUpdateProvider
{
    private readonly IStoreUpdateClient _client;

    public DistributionChannel Channel => DistributionChannel.MicrosoftStore;
    public bool SupportsBetaChannel => false;
    public bool SupportsSkippedVersions => false;

    public MicrosoftStoreUpdateProvider(IStoreUpdateClient? client = null)
    {
        _client = client ?? new WindowsStoreUpdateClient();
    }

    public async Task<UpdateCheckResult> CheckForUpdatesAsync(
        bool includeBeta = false,
        string? skippedVersion = null,
        CancellationToken cancellationToken = default)
    {
        StoreUpdateCheckResult storeResult = await _client.CheckForUpdatesAsync(cancellationToken);

        if (!storeResult.IsSuccess)
        {
            return new UpdateCheckResult
            {
                Status = UpdateCheckStatus.Failed,
                ErrorMessage = storeResult.ErrorMessage
            };
        }

        if (!storeResult.HasUpdates)
        {
            return new UpdateCheckResult
            {
                Status = UpdateCheckStatus.UpToDate
            };
        }

        var updateInfo = new UpdateInfo
        {
            Version = storeResult.Version,
            Title = storeResult.Title,
            ReleaseNotes = storeResult.Description,
            Channel = DistributionChannel.MicrosoftStore
        };

        return new UpdateCheckResult
        {
            Status = UpdateCheckStatus.UpdateAvailable,
            Update = updateInfo
        };
    }

    public Task<UpdateInstallResult> InstallUpdateAsync(
        UpdateInfo update,
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default)
    {
        return _client.DownloadAndInstallUpdatesAsync(progress, ownerWindowHandle, cancellationToken);
    }
}
