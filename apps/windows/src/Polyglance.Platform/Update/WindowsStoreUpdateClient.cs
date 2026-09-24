using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Polyglance.Core.Native;

namespace Polyglance.Platform.Update;

public sealed class WindowsStoreUpdateClient : IStoreUpdateClient
{
    private sealed class NativeUpdateCheckResult
    {
        [JsonPropertyName("has_update")]
        public bool HasUpdate { get; set; }

        [JsonPropertyName("version")]
        public string Version { get; set; } = string.Empty;

        [JsonPropertyName("title")]
        public string Title { get; set; } = string.Empty;
    }

    private sealed class NativeUpdateInstallResult
    {
        [JsonPropertyName("success")]
        public bool Success { get; set; }

        [JsonPropertyName("cancelled")]
        public bool Cancelled { get; set; }

        [JsonPropertyName("message")]
        public string Message { get; set; } = string.Empty;
    }

    public Task<StoreUpdateCheckResult> CheckForUpdatesAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            IntPtr outJsonPtr = IntPtr.Zero;
            int status = NativeMethods.polyglance_windows_store_check_updates(IntPtr.Zero, out outJsonPtr);
            if (status != 0 || outJsonPtr == IntPtr.Zero)
            {
                return Task.FromResult(StoreUpdateCheckResult.Error("暂时无法连接 Microsoft Store，请检查网络或稍后重试。"));
            }

            string json = Marshal.PtrToStringUTF8(outJsonPtr) ?? "{}";
            NativeMethods.polyglance_free_string(outJsonPtr);

            var info = JsonSerializer.Deserialize<NativeUpdateCheckResult>(json);
            if (info == null || !info.HasUpdate)
            {
                return Task.FromResult(StoreUpdateCheckResult.NoUpdate());
            }

            return Task.FromResult(StoreUpdateCheckResult.UpdateAvailable(
                version: string.IsNullOrWhiteSpace(info.Version) ? "最新版" : info.Version,
                title: string.IsNullOrWhiteSpace(info.Title) ? "Microsoft Store 新版本可用" : info.Title,
                description: "Microsoft Store 准备了新的应用程序包更新。"));
        }
        catch (OperationCanceledException)
        {
            return Task.FromResult(StoreUpdateCheckResult.Error("已取消检查更新。"));
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WindowsStoreUpdateClient] CheckForUpdates error: {ex}");
            return Task.FromResult(StoreUpdateCheckResult.Error("暂时无法连接 Microsoft Store，请检查网络或稍后重试。"));
        }
    }

    public Task<UpdateInstallResult> DownloadAndInstallUpdatesAsync(
        IProgress<UpdateDownloadProgress>? progress = null,
        IntPtr ownerWindowHandle = default,
        CancellationToken cancellationToken = default)
    {
        try
        {
            IntPtr outJsonPtr = IntPtr.Zero;
            int status = NativeMethods.polyglance_windows_store_install_updates(ownerWindowHandle, out outJsonPtr);
            if (status != 0 || outJsonPtr == IntPtr.Zero)
            {
                return Task.FromResult(UpdateInstallResult.Fail("Microsoft Store 安装更新遇到异常，请稍后重试。"));
            }

            string json = Marshal.PtrToStringUTF8(outJsonPtr) ?? "{}";
            NativeMethods.polyglance_free_string(outJsonPtr);

            var info = JsonSerializer.Deserialize<NativeUpdateInstallResult>(json);
            if (info == null)
            {
                return Task.FromResult(UpdateInstallResult.Fail("Microsoft Store 更新未完成。"));
            }

            if (info.Success)
            {
                return Task.FromResult(UpdateInstallResult.Success(info.Message));
            }

            if (info.Cancelled)
            {
                return Task.FromResult(UpdateInstallResult.Cancelled(info.Message));
            }

            return Task.FromResult(UpdateInstallResult.Fail(info.Message));
        }
        catch (OperationCanceledException)
        {
            return Task.FromResult(UpdateInstallResult.Cancelled());
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[WindowsStoreUpdateClient] DownloadAndInstall error: {ex}");
            return Task.FromResult(UpdateInstallResult.Fail("Microsoft Store 安装更新遇到异常，请稍后重试。"));
        }
    }
}
