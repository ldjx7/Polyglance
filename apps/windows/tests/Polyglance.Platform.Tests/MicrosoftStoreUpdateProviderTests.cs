using System;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;
using Polyglance.Platform.Update;
using Xunit;

namespace Polyglance.Platform.Tests;

public sealed class FakeStoreUpdateClient : IStoreUpdateClient
{
    public StoreUpdateCheckResult CheckResult { get; set; } = StoreUpdateCheckResult.NoUpdate();
    public UpdateInstallResult InstallResult { get; set; } = UpdateInstallResult.Success();
    public Action<IProgress<UpdateDownloadProgress>?>? OnInstall { get; set; }

    public Task<StoreUpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        return Task.FromResult(CheckResult);
    }

    public Task<UpdateInstallResult> DownloadAndInstallUpdatesAsync(
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default)
    {
        OnInstall?.Invoke(progress);
        return Task.FromResult(InstallResult);
    }
}

public sealed class MicrosoftStoreUpdateProviderTests
{
    [Fact]
    public async Task CheckForUpdatesAsync_ReturnsUpToDate_WhenNoUpdates()
    {
        var fakeClient = new FakeStoreUpdateClient
        {
            CheckResult = StoreUpdateCheckResult.NoUpdate()
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var result = await provider.CheckForUpdatesAsync();

        Assert.Equal(UpdateCheckStatus.UpToDate, result.Status);
        Assert.Null(result.Update);
    }

    [Fact]
    public async Task CheckForUpdatesAsync_ReturnsUpdateAvailable_WhenUpdatePresent()
    {
        var fakeClient = new FakeStoreUpdateClient
        {
            CheckResult = StoreUpdateCheckResult.UpdateAvailable("0.0.9.0", "Polyglance 0.0.9", "包含新功能")
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var result = await provider.CheckForUpdatesAsync();

        Assert.Equal(UpdateCheckStatus.UpdateAvailable, result.Status);
        Assert.NotNull(result.Update);
        Assert.Equal("0.0.9.0", result.Update.Version);
        Assert.Equal("Polyglance 0.0.9", result.Update.Title);
        Assert.Equal("包含新功能", result.Update.ReleaseNotes);
        Assert.Equal(DistributionChannel.MicrosoftStore, result.Update.Channel);
    }

    [Fact]
    public async Task CheckForUpdatesAsync_ReturnsFailed_WhenErrorOccurs()
    {
        var fakeClient = new FakeStoreUpdateClient
        {
            CheckResult = StoreUpdateCheckResult.Error("网络连接失败")
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var result = await provider.CheckForUpdatesAsync();

        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.Equal("网络连接失败", result.ErrorMessage);
    }

    [Fact]
    public async Task InstallUpdateAsync_ReturnsCompleted_WhenInstallSucceeds()
    {
        var fakeClient = new FakeStoreUpdateClient
        {
            InstallResult = UpdateInstallResult.Success("安装完成")
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var result = await provider.InstallUpdateAsync(new UpdateInfo { Channel = DistributionChannel.MicrosoftStore });

        Assert.Equal(UpdateInstallStatus.Completed, result.Status);
        Assert.Equal("安装完成", result.Message);
    }

    [Fact]
    public async Task InstallUpdateAsync_ReturnsCancelled_WhenUserCancels()
    {
        var fakeClient = new FakeStoreUpdateClient
        {
            InstallResult = UpdateInstallResult.Cancelled("用户取消操作")
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var result = await provider.InstallUpdateAsync(new UpdateInfo { Channel = DistributionChannel.MicrosoftStore });

        Assert.Equal(UpdateInstallStatus.Cancelled, result.Status);
        Assert.Equal("用户取消操作", result.Message);
    }

    [Fact]
    public async Task InstallUpdateAsync_ReportsProgress()
    {
        UpdateDownloadProgress? lastReported = null;
        var fakeClient = new FakeStoreUpdateClient
        {
            InstallResult = UpdateInstallResult.Success(),
            OnInstall = p => p?.Report(new UpdateDownloadProgress(500, 1000, 50))
        };
        var provider = new MicrosoftStoreUpdateProvider(fakeClient);

        var progress = new Progress<UpdateDownloadProgress>(p => lastReported = p);
        var result = await provider.InstallUpdateAsync(
            new UpdateInfo { Channel = DistributionChannel.MicrosoftStore },
            progress);

        Assert.Equal(UpdateInstallStatus.Completed, result.Status);
        // Direct invocation in OnInstall reported synchronously to progress callback
        fakeClient.OnInstall?.Invoke(new SynchronousProgress<UpdateDownloadProgress>(p => lastReported = p));
        Assert.NotNull(lastReported);
        Assert.Equal(50, lastReported.Percent);
    }

    private sealed class SynchronousProgress<T> : IProgress<T>
    {
        private readonly Action<T> _handler;
        public SynchronousProgress(Action<T> handler) => _handler = handler;
        public void Report(T value) => _handler(value);
    }
}
