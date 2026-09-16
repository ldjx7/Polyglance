using System;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;

namespace Polyglance.Platform.Update;

public sealed class GitHubUpdateProvider : IAppUpdateProvider
{
    private readonly Func<string> _appcastUrlAccessor;

    public DistributionChannel Channel => DistributionChannel.GitHub;
    public bool SupportsBetaChannel => true;
    public bool SupportsSkippedVersions => true;

    public GitHubUpdateProvider(string appcastUrl)
        : this(() => appcastUrl)
    {
    }

    public GitHubUpdateProvider(Func<string> appcastUrlAccessor)
    {
        _appcastUrlAccessor = appcastUrlAccessor ?? throw new ArgumentNullException(nameof(appcastUrlAccessor));
    }

    public Task<UpdateCheckResult> CheckForUpdatesAsync(
        bool includeBeta = false,
        string? skippedVersion = null,
        CancellationToken cancellationToken = default)
    {
        string url = _appcastUrlAccessor();
        return AppUpdater.CheckForUpdatesAsync(url, includeBeta, skippedVersion);
    }

    public PreparedUpdate? PreparedUpdate { get; private set; }

    public async Task<PreparedUpdate?> PrepareUpdateAsync(
        UpdateInfo update,
        IProgress<UpdateDownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(update);
        PreparedUpdate? prepared = await AppUpdater.DownloadAndPrepareUpdateAsync(update.DownloadUrl, progress);
        PreparedUpdate = prepared;
        return prepared;
    }

    public void ApplyPreparedUpdate()
    {
        if (PreparedUpdate == null) throw new InvalidOperationException("未找到已就绪的更新包。");
        PreparedUpdate.ApplyAndRestart();
    }

    public async Task<UpdateInstallResult> InstallUpdateAsync(
        UpdateInfo update,
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(update);
        if (string.IsNullOrWhiteSpace(update.DownloadUrl))
        {
            return UpdateInstallResult.Fail("更新下载地址无效。");
        }

        try
        {
            PreparedUpdate? prepared = await PrepareUpdateAsync(update, progress, cancellationToken);
            if (prepared == null)
            {
                return UpdateInstallResult.Fail("下载或解压更新包失败，请稍后重试。");
            }

            prepared.ApplyAndRestart();
            return UpdateInstallResult.Success("更新已准备就绪，正在重启应用...");
        }
        catch (OperationCanceledException)
        {
            return UpdateInstallResult.Cancelled();
        }
        catch (Exception ex)
        {
            return UpdateInstallResult.Fail($"安装更新失败: {ex.Message}");
        }
    }
}
