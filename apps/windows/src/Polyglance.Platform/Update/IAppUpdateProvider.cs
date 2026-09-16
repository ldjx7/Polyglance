using System;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;

namespace Polyglance.Platform.Update;

public interface IAppUpdateProvider
{
    DistributionChannel Channel { get; }
    bool SupportsBetaChannel { get; }
    bool SupportsSkippedVersions { get; }

    Task<UpdateCheckResult> CheckForUpdatesAsync(
        bool includeBeta = false,
        string? skippedVersion = null,
        CancellationToken cancellationToken = default);

    Task<UpdateInstallResult> InstallUpdateAsync(
        UpdateInfo update,
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default);
}
