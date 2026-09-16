namespace Polyglance.Platform.Update;

public enum UpdateInstallStatus
{
    Completed,
    Cancelled,
    Failed
}

public sealed class UpdateInstallResult
{
    public UpdateInstallStatus Status { get; init; }
    public string Message { get; init; } = "";

    public static UpdateInstallResult Success(string message = "") =>
        new() { Status = UpdateInstallStatus.Completed, Message = message };

    public static UpdateInstallResult Cancelled(string message = "用户取消了更新操作。") =>
        new() { Status = UpdateInstallStatus.Cancelled, Message = message };

    public static UpdateInstallResult Fail(string message) =>
        new() { Status = UpdateInstallStatus.Failed, Message = message };
}
