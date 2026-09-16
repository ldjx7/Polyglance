using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Windows.Services.Store;

namespace Polyglance.Platform.Update;

[ComImport]
[Guid("3E68D4BD-7135-4D10-8018-9FB6D9F33FA1")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IInitializeWithWindow
{
    void Initialize(IntPtr hwnd);
}

public sealed class WindowsStoreUpdateClient : IStoreUpdateClient
{
    private StoreContext? _storeContext;
    private IReadOnlyList<StorePackageUpdate>? _pendingUpdates;

    private StoreContext GetOrCreateStoreContext(IntPtr ownerWindowHandle = default)
    {
        if (_storeContext == null)
        {
            _storeContext = StoreContext.GetDefault();
            if (ownerWindowHandle != IntPtr.Zero)
            {
                try
                {
                    var initWindow = (IInitializeWithWindow)(object)_storeContext;
                    initWindow.Initialize(ownerWindowHandle);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[StoreContext] IInitializeWithWindow failed: {ex.Message}");
                }
            }
        }
        return _storeContext;
    }

    public async Task<StoreUpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            StoreContext context = GetOrCreateStoreContext();
            IReadOnlyList<StorePackageUpdate> updates = await context.GetAppAndOptionalStorePackageUpdatesAsync().AsTask(cancellationToken);

            _pendingUpdates = updates;

            if (updates == null || updates.Count == 0)
            {
                return StoreUpdateCheckResult.NoUpdate();
            }

            string version = "";
            string title = "Microsoft Store 新版本可用";
            foreach (var pkgUpdate in updates)
            {
                if (pkgUpdate.Package != null)
                {
                    var pkgVer = pkgUpdate.Package.Id.Version;
                    version = $"{pkgVer.Major}.{pkgVer.Minor}.{pkgVer.Build}.{pkgVer.Revision}";
                    if (!string.IsNullOrWhiteSpace(pkgUpdate.Package.DisplayName))
                    {
                        title = pkgUpdate.Package.DisplayName;
                    }
                    break;
                }
            }

            return StoreUpdateCheckResult.UpdateAvailable(
                version: string.IsNullOrWhiteSpace(version) ? "最新版" : version,
                title: title,
                description: "Microsoft Store 准备了新的应用程序包更新。");
        }
        catch (OperationCanceledException)
        {
            return StoreUpdateCheckResult.Error("已取消检查更新。");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WindowsStoreUpdateClient] CheckForUpdates error: {ex}");
            return StoreUpdateCheckResult.Error("暂时无法连接 Microsoft Store，请检查网络或稍后重试。");
        }
    }

    public async Task<UpdateInstallResult> DownloadAndInstallUpdatesAsync(
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default)
    {
        try
        {
            StoreContext context = GetOrCreateStoreContext(ownerWindowHandle);
            IReadOnlyList<StorePackageUpdate>? updates = _pendingUpdates;

            if (updates == null || updates.Count == 0)
            {
                updates = await context.GetAppAndOptionalStorePackageUpdatesAsync().AsTask(cancellationToken);
            }

            if (updates == null || updates.Count == 0)
            {
                return UpdateInstallResult.Fail("当前没有可用的 Microsoft Store 更新包。");
            }

            var asyncOp = context.RequestDownloadAndInstallStorePackageUpdatesAsync(updates);

            if (progress != null)
            {
                asyncOp.Progress = (asyncInfo, updateProgress) =>
                {
                    int percent = (int)Math.Clamp(updateProgress.PackageDownloadProgress * 100.0, 0.0, 100.0);
                    long totalBytes = (long)updateProgress.PackageDownloadSizeInBytes;
                    long bytesReceived = (long)(totalBytes * Math.Clamp(updateProgress.PackageDownloadProgress, 0.0, 1.0));
                    progress.Report(new UpdateDownloadProgress(bytesReceived, totalBytes, percent));
                };
            }

            StorePackageUpdateResult result = await asyncOp.AsTask(cancellationToken);

            return result.OverallState switch
            {
                StorePackageUpdateState.Completed => UpdateInstallResult.Success("Microsoft Store 更新已完成。"),
                StorePackageUpdateState.Canceled => UpdateInstallResult.Cancelled("用户取消了 Microsoft Store 安装操作。"),
                _ => UpdateInstallResult.Fail($"Microsoft Store 更新未完成 (状态: {result.OverallState})。")
            };
        }
        catch (OperationCanceledException)
        {
            return UpdateInstallResult.Cancelled();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WindowsStoreUpdateClient] DownloadAndInstall error: {ex}");
            return UpdateInstallResult.Fail("Microsoft Store 安装更新遇到异常，请稍后重试。");
        }
    }
}
