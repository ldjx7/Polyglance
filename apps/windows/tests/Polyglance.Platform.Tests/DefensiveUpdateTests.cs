using System;
using System.Reflection;
using System.Threading.Tasks;
using Polyglance.Platform.Packaging;
using Polyglance.Platform.Update;
using Xunit;

namespace Polyglance.Platform.Tests;

[Collection("PackageEnvironment")]
public sealed class DefensiveUpdateTests
{
    [Fact]
    public async Task DownloadAndPrepareUpdateAsync_ThrowsInPackagedEnvironment()
    {
        try
        {
            PackageEnvironment.SetPackagedOverrideForTesting(true);

            var ex = await Assert.ThrowsAsync<InvalidOperationException>(() =>
                AppUpdater.DownloadAndPrepareUpdateAsync("https://example.com/update.zip"));

            Assert.Contains("Microsoft Store", ex.Message);
        }
        finally
        {
            PackageEnvironment.SetPackagedOverrideForTesting(null);
        }
    }

    [Fact]
    public void ApplyAndRestart_ThrowsInPackagedEnvironment()
    {
        try
        {
            PackageEnvironment.SetPackagedOverrideForTesting(true);

            var ctor = typeof(PreparedUpdate).GetConstructor(
                BindingFlags.NonPublic | BindingFlags.Instance,
                null,
                new[] { typeof(string), typeof(string) },
                null);

            Assert.NotNull(ctor);
            var prepared = (PreparedUpdate)ctor.Invoke(new object[] { "test.cmd", "Polyglance.exe" });

            var ex = Assert.Throws<InvalidOperationException>(() => prepared.ApplyAndRestart());
            Assert.Contains("Microsoft Store", ex.Message);
        }
        finally
        {
            PackageEnvironment.SetPackagedOverrideForTesting(null);
        }
    }
}
