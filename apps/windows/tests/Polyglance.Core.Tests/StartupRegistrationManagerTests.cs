using Polyglance.Core.Services;

namespace Polyglance.Core.Tests;

public sealed class StartupRegistrationManagerTests
{
    [Fact]
    public void StartupCommandQuotesExecutableAndUsesBackgroundLaunchArgument()
    {
        var store = new StubStartupValueStore();
        var manager = new StartupRegistrationManager(store, @"C:\Program Files\Polyglance\Polyglance.exe");

        Assert.Equal(
            "\"C:\\Program Files\\Polyglance\\Polyglance.exe\" --autostart",
            manager.StartupCommand);
    }

    [Fact]
    public void IsEnabledOnlyWhenRegisteredCommandTargetsCurrentExecutable()
    {
        var store = new StubStartupValueStore
        {
            Value = "\"C:\\Old\\Polyglance.exe\" --autostart"
        };
        var manager = new StartupRegistrationManager(store, @"C:\Apps\Polyglance.exe");

        Assert.False(manager.IsEnabled);

        store.Value = manager.StartupCommand.ToUpperInvariant();
        Assert.True(manager.IsEnabled);
    }

    [Theory]
    [InlineData("\"C:\\Old\\Polyglance.exe\" --autostart")]
    [InlineData("\"D:\\Portable\\Polyglance.UI.exe\" --autostart")]
    public void RefreshRegistrationMigratesRecognizedPreviousInstallations(string previousCommand)
    {
        var store = new StubStartupValueStore { Value = previousCommand };
        var manager = new StartupRegistrationManager(store, @"C:\Apps\Polyglance.exe");

        Assert.True(manager.RefreshRegistration());
        Assert.Equal(manager.StartupCommand, store.Value);
        Assert.Equal(StartupRegistrationManager.ValueName, store.LastWrittenName);
    }

    [Theory]
    [InlineData("\"C:\\Tools\\Other.exe\" --autostart")]
    [InlineData("\"C:\\Old\\Polyglance.exe\" --unexpected")]
    [InlineData("not a command")]
    public void RefreshRegistrationDoesNotAdoptUnrelatedOrMalformedCommands(string command)
    {
        var store = new StubStartupValueStore { Value = command };
        var manager = new StartupRegistrationManager(store, @"C:\Apps\Polyglance.exe");

        Assert.False(manager.RefreshRegistration());
        Assert.Equal(command, store.Value);
        Assert.Null(store.LastWrittenName);
    }

    [Fact]
    public void EnablingWritesCurrentUserStartupValue()
    {
        var store = new StubStartupValueStore();
        var manager = new StartupRegistrationManager(store, @"C:\Apps\Polyglance.exe");

        manager.SetEnabled(true);

        Assert.Equal(StartupRegistrationManager.ValueName, store.LastWrittenName);
        Assert.Equal(manager.StartupCommand, store.Value);
        Assert.Equal(0, store.DeleteCallCount);
    }

    [Fact]
    public void DisablingDeletesStartupValueIncludingStaleRegistration()
    {
        var store = new StubStartupValueStore { Value = "stale command" };
        var manager = new StartupRegistrationManager(store, @"C:\Apps\Polyglance.exe");

        manager.SetEnabled(false);

        Assert.Null(store.Value);
        Assert.Equal(StartupRegistrationManager.ValueName, store.LastDeletedName);
        Assert.Equal(1, store.DeleteCallCount);
    }

    [Fact]
    public void EmptyExecutablePathIsRejected()
    {
        Assert.Throws<ArgumentException>(() =>
            new StartupRegistrationManager(new StubStartupValueStore(), " "));
    }

    private sealed class StubStartupValueStore : IStartupValueStore
    {
        public string? Value { get; set; }
        public string? LastWrittenName { get; private set; }
        public string? LastDeletedName { get; private set; }
        public int DeleteCallCount { get; private set; }

        public string? Read(string name) => Value;

        public void Write(string name, string value)
        {
            LastWrittenName = name;
            Value = value;
        }

        public void Delete(string name)
        {
            LastDeletedName = name;
            DeleteCallCount += 1;
            Value = null;
        }
    }
}
