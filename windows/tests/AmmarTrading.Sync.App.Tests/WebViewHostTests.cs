using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using AmmarTrading.Sync.App.Bridge;
using AmmarTrading.Sync.App.Hosting;
using AmmarTrading.Sync.Core.Bridge;
using AmmarTrading.Sync.Core.Services;
using Xunit;

namespace AmmarTrading.Sync.App.Tests;

public sealed class WebViewHostTests : IDisposable
{
    private readonly string _testRoot = Path.Combine(
        Path.GetTempPath(),
        $"AmmarTradingWebViewHostTests_{Guid.NewGuid():N}");

    [Theory]
    [InlineData("https://ammartrading.app/")]
    [InlineData("https://ammartrading.app/index.html")]
    [InlineData("https://AMMARTRADING.APP/assets/app.js?cache=1")]
    public void NavigationPolicy_AllowsOnlyTheBundledHttpsOrigin(string address)
    {
        Assert.True(WebViewSecurityPolicy.IsAllowedAppUri(new Uri(address)));
    }

    [Theory]
    [InlineData("http://ammartrading.app/")]
    [InlineData("https://ammartrading.app.evil.invalid/")]
    [InlineData("https://example.invalid/")]
    [InlineData("https://ammartrading.app:444/")]
    [InlineData("https://user@ammartrading.app/")]
    [InlineData("file:///C:/Windows/System32/drivers/etc/hosts")]
    [InlineData("about:blank")]
    public void NavigationPolicy_RejectsEveryOtherTopLevelAddress(string address)
    {
        Assert.False(WebViewSecurityPolicy.IsAllowedAppUri(new Uri(address)));
    }

    [Fact]
    public void ReleaseFeaturePolicy_DisablesInteractiveBrowserSurface()
    {
        var policy = WebViewSecurityPolicy.ReleaseFeatures;

        Assert.False(policy.DevTools);
        Assert.False(policy.ContextMenus);
        Assert.False(policy.BrowserAccelerators);
        Assert.False(policy.StatusBar);
        Assert.False(policy.PasswordAutosave);
        Assert.False(policy.GeneralAutofill);
    }

    [Fact]
    public void RuntimePaths_PutMetadataLogsBelowTheRequiredLocalAppDataDirectory()
    {
        var paths = AppRuntimePaths.FromLocalApplicationData(Path.Combine(_testRoot, "LocalAppData"));

        Assert.Equal(
            Path.Combine(_testRoot, "LocalAppData", "AmmarTrading", "Sync", "Logs"),
            paths.LogDirectory);
        Assert.Equal(
            Path.Combine(_testRoot, "LocalAppData", "AmmarTrading", "Sync", "WebView2"),
            paths.WebViewUserDataDirectory);
    }

    [Fact]
    public void MetadataLogger_WritesOnlyTimestampAndStableEventCode()
    {
        var localAppData = Path.Combine(_testRoot, "LocalAppData");
        var logger = new AppMetadataLogger(AppRuntimePaths.FromLocalApplicationData(localAppData));

        logger.Write(AppLogEvent.WebViewInitializationFailed);

        var logPath = Path.Combine(
            localAppData,
            "AmmarTrading",
            "Sync",
            "Logs",
            "application.jsonl");
        using var line = JsonDocument.Parse(File.ReadAllText(logPath));
        Assert.Equal(
            new[] { "eventCode", "timestampUtc" },
            line.RootElement.EnumerateObject().Select(property => property.Name).Order().ToArray());
        Assert.Equal("WebViewInitializationFailed", line.RootElement.GetProperty("eventCode").GetString());
    }

    [Fact]
    public void FatalWebViewPage_DoesNotExposeInitializationExceptionDetails()
    {
        const string sensitiveDetail = @"C:\Users\Trader\secret-profile\WebView2 failed";

        var content = HostFatalPage.ForWebViewInitializationFailure(
            new InvalidOperationException(sensitiveDetail));

        Assert.Equal("AmmarTrading Sync couldn't start", content.Title);
        Assert.Contains("Microsoft Edge WebView2 Runtime", content.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(sensitiveDetail, $"{content.Title}\n{content.Message}", StringComparison.Ordinal);
    }

    [Fact]
    public async Task WebMessageBridge_PostsExactlyOneLowercaseBridgeResponse()
    {
        var host = new FakeWebMessageHost();
        await using var bridge = new WebViewBridge(
            new BridgeCommandRouter(new ImmediateOperations()),
            host,
            new RecordingMetadataLogger());

        host.Receive("""
            {"version":1,"id":"request-1","command":"getSystemStatus","payload":{}}
            """);

        var posted = await host.ReadPostedAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        using var response = JsonDocument.Parse(posted);
        Assert.Equal(
            new[] { "code", "data", "id", "message", "ok", "version" },
            response.RootElement.EnumerateObject().Select(property => property.Name).Order().ToArray());
        Assert.Equal("request-1", response.RootElement.GetProperty("id").GetString());
        Assert.True(response.RootElement.GetProperty("ok").GetBoolean());
        Assert.Equal("Success", response.RootElement.GetProperty("code").GetString());
        Assert.Equal(1, host.PostCount);
    }

    [Fact]
    public async Task WebMessageBridge_LimitsCommandsToFourAndCancelsActiveWorkOnClose()
    {
        var operations = new BlockingOperations();
        var host = new FakeWebMessageHost();
        var bridge = new WebViewBridge(
            new BridgeCommandRouter(operations),
            host,
            new RecordingMetadataLogger());

        for (var index = 0; index < 5; index++)
        {
            host.Receive(
                $"{{\"version\":1,\"id\":\"request-{index}\",\"command\":\"getSystemStatus\",\"payload\":{{}}}}");
        }

        await operations.FourStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Task.Delay(100);
        Assert.Equal(4, operations.StartedCount);
        Assert.Equal(4, operations.MaximumActiveCount);

        await bridge.DisposeAsync();

        Assert.Equal(4, operations.CancellationCount);
        Assert.Equal(4, operations.StartedCount);
    }

    [Fact]
    public async Task ActivationPipe_NotifiesTheExistingInstanceThroughLocalIpc()
    {
        var pipeName = $"AmmarTrading.Sync.Tests.{Guid.NewGuid():N}";
        await using var pipe = new ActivationPipe(pipeName, new RecordingMetadataLogger());
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var activated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var listening = pipe.ListenAsync(
            () => activated.TrySetResult(),
            cancellation.Token);

        var signaled = await ActivationPipe.TrySignalAsync(
            pipeName,
            TimeSpan.FromSeconds(2),
            cancellation.Token);

        Assert.True(signaled);
        await activated.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancellation.Cancel();
        await listening;
    }

    public void Dispose()
    {
        if (Directory.Exists(_testRoot))
        {
            Directory.Delete(_testRoot, recursive: true);
        }
    }

    private sealed class FakeWebMessageHost : IWebViewMessageHost
    {
        private readonly Channel<string> _posted = Channel.CreateUnbounded<string>();
        private int _postCount;

        public event EventHandler<WebMessageJsonEventArgs>? MessageReceived;

        public int PostCount => Volatile.Read(ref _postCount);

        public void Receive(string json) =>
            MessageReceived?.Invoke(this, new WebMessageJsonEventArgs(json));

        public ValueTask PostWebMessageAsJsonAsync(string json, CancellationToken token)
        {
            Interlocked.Increment(ref _postCount);
            return _posted.Writer.WriteAsync(json, token);
        }

        public ValueTask<string> ReadPostedAsync() => _posted.Reader.ReadAsync();

        public void Dispose()
        {
        }
    }

    private sealed class RecordingMetadataLogger : IAppMetadataLogger
    {
        public ConcurrentQueue<AppLogEvent> Events { get; } = new();

        public void Write(AppLogEvent eventCode) => Events.Enqueue(eventCode);
    }

    private sealed class ImmediateOperations : IAmmarTradingOperations
    {
        private static readonly object Result = JsonSerializer.SerializeToElement(new { ready = true });

        public Task<object> GetSystemStatusAsync(CancellationToken token) => Completed(token);

        public Task<object> DiscoverMt4AccountsAsync(CancellationToken token) => Completed(token);

        public Task<object> BrowseForCsvAsync(CancellationToken token) => Completed(token);

        public Task<object> GetOneDriveRootsAsync(CancellationToken token) => Completed(token);

        public Task<object> GetConfiguredAccountsAsync(CancellationToken token) => Completed(token);

        public Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> ExportSupportReportAsync(CancellationToken token) => Completed(token);

        private static Task<object> Completed(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult(Result);
        }
    }

    private sealed class BlockingOperations : IAmmarTradingOperations
    {
        private int _activeCount;
        private int _cancellationCount;
        private int _maximumActiveCount;
        private int _startedCount;

        public int CancellationCount => Volatile.Read(ref _cancellationCount);

        public TaskCompletionSource FourStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public int MaximumActiveCount => Volatile.Read(ref _maximumActiveCount);

        public int StartedCount => Volatile.Read(ref _startedCount);

        public Task<object> GetSystemStatusAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> DiscoverMt4AccountsAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> BrowseForCsvAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> GetOneDriveRootsAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> GetConfiguredAccountsAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token) => BlockAsync(token);

        public Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token) => BlockAsync(token);

        public Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token) => BlockAsync(token);

        public Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token) => BlockAsync(token);

        public Task<object> ExportSupportReportAsync(CancellationToken token) => BlockAsync(token);

        private async Task<object> BlockAsync(CancellationToken token)
        {
            var started = Interlocked.Increment(ref _startedCount);
            var active = Interlocked.Increment(ref _activeCount);
            UpdateMaximum(active);
            if (started == 4)
            {
                FourStarted.TrySetResult();
            }

            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return new object();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                Interlocked.Increment(ref _cancellationCount);
                throw;
            }
            finally
            {
                Interlocked.Decrement(ref _activeCount);
            }
        }

        private void UpdateMaximum(int candidate)
        {
            while (true)
            {
                var current = Volatile.Read(ref _maximumActiveCount);
                if (candidate <= current ||
                    Interlocked.CompareExchange(ref _maximumActiveCount, candidate, current) == current)
                {
                    return;
                }
            }
        }
    }
}
