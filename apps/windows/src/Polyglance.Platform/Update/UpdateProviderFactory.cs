using System;
using Polyglance.Platform.Packaging;

namespace Polyglance.Platform.Update;

public static class UpdateProviderFactory
{
    public static IAppUpdateProvider Create(
        Func<string> gitHubAppcastUrlAccessor,
        DistributionChannel? channelOverride = null,
        IStoreUpdateClient? storeClientOverride = null)
    {
        DistributionChannel channel = channelOverride ?? PackageEnvironment.DistributionChannel;

        return channel switch
        {
            DistributionChannel.MicrosoftStore => new MicrosoftStoreUpdateProvider(storeClientOverride),
            _ => new GitHubUpdateProvider(gitHubAppcastUrlAccessor)
        };
    }

    public static IAppUpdateProvider Create(
        string gitHubAppcastUrl,
        DistributionChannel? channelOverride = null,
        IStoreUpdateClient? storeClientOverride = null)
    {
        return Create(() => gitHubAppcastUrl, channelOverride, storeClientOverride);
    }
}
