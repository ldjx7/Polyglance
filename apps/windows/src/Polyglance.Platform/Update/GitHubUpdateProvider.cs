using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;

namespace Polyglance.Platform.Update;

public sealed class GitHubUpdateProvider : IAppUpdateProvider
{
    private readonly Func<string> _appcastUrlAccessor;
    private readonly SemaphoreSlim _preparation = new(1, 1);
    private string? _preparedVersion;
    private bool _preparedVerified;

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
    public UpdateInfo? PreparedInfo { get; private set; }

    public async Task RestorePreparedUpdateAsync()
    {
        var pending = await PendingUpdateStore.RestoreAsync();
        if (pending == null) return;
        PreparedUpdate = pending.Value.Prepared;
        PreparedInfo = pending.Value.Info;
        _preparedVerified = true;
        _preparedVersion = Key(PreparedInfo);
    }

    private static string Key(UpdateInfo info) => info.Version + "|" + info.BuildVersion + "|" + info.DownloadUrl;

    public bool HasPreparedUpdate => PreparedUpdate != null && PreparedInfo != null
        && File.Exists(PreparedUpdate.BatchScriptPath) && File.Exists(PreparedUpdate.PackagePath);

    public void MarkInstallationStarted() => PendingUpdateStore.Clear();

    public async Task<PreparedUpdate?> PrepareUpdateAsync(
        UpdateInfo update,
        IProgress<UpdateDownloadProgress>? progress = null,
        CancellationToken cancellationToken = default,
        bool requireVerifiedPackage = false)
    {
        ArgumentNullException.ThrowIfNull(update);
        await _preparation.WaitAsync(cancellationToken);
        try
        {
            string key = Key(update);
            if (HasPreparedUpdate && (_preparedVersion == key || (PreparedInfo != null
                && Version.TryParse(PreparedInfo.BuildVersion, out var preparedBuild)
                && !PendingUpdateStore.IsNewer(update, PreparedInfo.Version, preparedBuild)))
                && (!requireVerifiedPackage || _preparedVerified)) return PreparedUpdate;
            PreparedUpdate? prepared = await AppUpdater.DownloadAndPrepareUpdateAsync(
                update.DownloadUrl, progress, true, cancellationToken);
            if (prepared != null)
            {
                cancellationToken.ThrowIfCancellationRequested();
                try { PendingUpdateStore.Save(update, prepared); }
                catch (Exception error)
                {
                    Debug.WriteLine($"Unable to save pending update: {error.Message}");
                    try
                    {
                        File.Delete(prepared.PackagePath!);
                        File.Delete(prepared.BatchScriptPath);
                        if (prepared.ExtractedDirectory != null) Directory.Delete(prepared.ExtractedDirectory, true);
                    }
                    catch { }
                    return null;
                }
                var previous = PreparedUpdate;
                PreparedUpdate = prepared;
                PreparedInfo = update;
                _preparedVersion = key;
                _preparedVerified = true;
                if (previous?.PackagePath != null && previous.PackagePath != prepared.PackagePath)
                {
                    try
                    {
                        File.Delete(previous.PackagePath);
                        File.Delete(previous.BatchScriptPath);
                        if (previous.ExtractedDirectory != null) Directory.Delete(previous.ExtractedDirectory, true);
                    }
                    catch { }
                }
            }
            return prepared;
        }
        finally { _preparation.Release(); }
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
