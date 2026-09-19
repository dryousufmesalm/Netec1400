using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text.Json;
using System.Threading.Channels;
using System.Windows.Threading;
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
    public void DeferredWebMessageReceiver_DeliversOnlyAfterTheWebViewCallbackReturns()
    {
        var dispatcher = new ManualWebViewDispatcher();
        var receiver = new DeferredWebMessageReceiver(
            dispatcher,
            new RecordingMetadataLogger());
        var callbackReturned = false;
        var observedAfterReturn = false;
        receiver.MessageReceived += (_, _) => observedAfterReturn = callbackReturned;

        receiver.Receive(
            "https://ammartrading.app/",
            """
            {"version":1,"id":"request-1","command":"getSystemStatus","payload":{}}
            """);

        Assert.False(observedAfterReturn);
        callbackReturned = true;
        dispatcher.RunPostedCallback();
        Assert.True(observedAfterReturn);
    }

    [Fact]
    public async Task WebMessageBridge_PostsExactlyOneLowercaseBridgeResponse()
    {
        var host = new FakeWebMessageHost();
        await using var bridge = new WebViewBridge(
            new BridgeCommandRouter(new ImmediateOperations()),
            host,
            new InlineWebViewDispatcher(),
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
            new InlineWebViewDispatcher(),
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
    public async Task WebMessageBridge_InvokesAQueuedBrowseOnTheOwningStaDispatcher()
    {
        await using var dispatcherThread = new StaDispatcherThread();
        var dispatcher = new WpfWebViewDispatcher(dispatcherThread.Dispatcher);
        var operations = new SaturatedBrowseOperations(dispatcher);
        var host = new FakeWebMessageHost();
        var bridge = new WebViewBridge(
            new BridgeCommandRouter(operations),
            host,
            dispatcher,
            new RecordingMetadataLogger());

        for (var index = 0; index < 4; index++)
        {
            host.Receive(
                $"{{\"version\":1,\"id\":\"request-{index}\",\"command\":\"getSystemStatus\",\"payload\":{{}}}}");
        }

        await operations.FourStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        host.Receive(
            """
            {"version":1,"id":"request-browse","command":"browseForCsv","payload":{}}
            """);
        await Task.Delay(100);
        Assert.False(operations.BrowseAffinity.Task.IsCompleted);

        operations.ReleaseOneSlot();
        var affinity = await operations.BrowseAffinity.Task.WaitAsync(TimeSpan.FromSeconds(5));

        Assert.Equal(ApartmentState.STA, affinity.ApartmentState);
        Assert.True(affinity.HasDispatcherAccess);
        await bridge.DisposeAsync();
    }

    [Fact]
    public void WindowCloseState_CancelsRepeatedCloseUntilDrainIsApproved()
    {
        var state = new WindowCloseState();

        var firstClose = state.RequestClose(canDrainBridge: true);
        var secondClose = state.RequestClose(canDrainBridge: false);

        Assert.True(firstClose.CancelClose);
        Assert.True(firstClose.StartDrain);
        Assert.True(secondClose.CancelClose);
        Assert.False(secondClose.StartDrain);

        state.ApproveClose();
        var approvedClose = state.RequestClose(canDrainBridge: false);
        Assert.False(approvedClose.CancelClose);
        Assert.False(approvedClose.StartDrain);
    }

    [Fact]
    public async Task WebMessageBridge_TearsDownTheHostOnItsDispatcherAndLogsFailure()
    {
        await using var dispatcherThread = new StaDispatcherThread();
        var dispatcher = new WpfWebViewDispatcher(dispatcherThread.Dispatcher);
        var logger = new RecordingMetadataLogger();
        var host = new ThrowingDisposeWebMessageHost(dispatcher);
        var bridge = new WebViewBridge(
            new BridgeCommandRouter(new ImmediateOperations()),
            host,
            dispatcher,
            logger);

        await Task.Run(async () => await bridge.DisposeAsync());

        Assert.True(host.UnsubscribeHadDispatcherAccess);
        Assert.True(host.DisposeHadDispatcherAccess);
        Assert.Contains(AppLogEvent.WebViewTeardownFailed, logger.Events);
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

    [Fact]
    public void SingleInstanceCoordinator_SeparatesActivationPipesByWindowsSession()
    {
        var firstSessionPipe = SingleInstanceCoordinator.PipeNameForSession(1);
        var secondSessionPipe = SingleInstanceCoordinator.PipeNameForSession(2);

        Assert.NotEqual(firstSessionPipe, secondSessionPipe);
    }

    [Fact]
    public async Task ActivationPipe_BacksOffAfterAListenerCollision()
    {
        var pipeName = $"AmmarTrading.Sync.Tests.{Guid.NewGuid():N}";
        using var occupiedServer = new NamedPipeServerStream(
            pipeName,
            PipeDirection.In,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var logger = new RecordingMetadataLogger();
        var backoffStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseBackoff = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        await using var pipe = new ActivationPipe(
            pipeName,
            logger,
            async token =>
            {
                backoffStarted.TrySetResult();
                await releaseBackoff.Task.WaitAsync(token);
            });
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        var listening = pipe.ListenAsync(() => { }, cancellation.Token);
        await backoffStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Task.Delay(100);

        Assert.Equal(
            1,
            logger.Events.Count(eventCode => eventCode == AppLogEvent.ActivationListenerFailed));
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

    private sealed class ThrowingDisposeWebMessageHost : IWebViewMessageHost
    {
        private readonly IWebViewDispatcher _dispatcher;

        public ThrowingDisposeWebMessageHost(IWebViewDispatcher dispatcher)
        {
            _dispatcher = dispatcher;
        }

        public event EventHandler<WebMessageJsonEventArgs>? MessageReceived
        {
            add { }
            remove => UnsubscribeHadDispatcherAccess = _dispatcher.CheckAccess();
        }

        public bool DisposeHadDispatcherAccess { get; private set; }

        public bool UnsubscribeHadDispatcherAccess { get; private set; }

        public ValueTask PostWebMessageAsJsonAsync(string json, CancellationToken token) =>
            ValueTask.CompletedTask;

        public void Dispose()
        {
            DisposeHadDispatcherAccess = _dispatcher.CheckAccess();
            throw new InvalidOperationException("sensitive teardown detail");
        }
    }

    private sealed class ManualWebViewDispatcher : IWebViewDispatcher
    {
        private readonly Queue<Action> _postedCallbacks = new();

        public bool CheckAccess() => true;

        public void Post(Action callback) => _postedCallbacks.Enqueue(callback);

        public Task InvokeAsync(Action callback, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            callback();
            return Task.CompletedTask;
        }

        public Task<T> InvokeAsync<T>(Func<Task<T>> callback, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return callback();
        }

        public void RunPostedCallback()
        {
            Assert.Single(_postedCallbacks);
            _postedCallbacks.Dequeue()();
        }
    }

    private sealed class InlineWebViewDispatcher : IWebViewDispatcher
    {
        public bool CheckAccess() => true;

        public void Post(Action callback) => callback();

        public Task InvokeAsync(Action callback, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            callback();
            return Task.CompletedTask;
        }

        public Task<T> InvokeAsync<T>(Func<Task<T>> callback, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return callback();
        }
    }

    private sealed class StaDispatcherThread : IAsyncDisposable
    {
        private readonly Thread _thread;

        public StaDispatcherThread()
        {
            var ready = new TaskCompletionSource<Dispatcher>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            _thread = new Thread(() =>
            {
                ready.TrySetResult(System.Windows.Threading.Dispatcher.CurrentDispatcher);
                System.Windows.Threading.Dispatcher.Run();
            });
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();
            Dispatcher = ready.Task.GetAwaiter().GetResult();
        }

        public Dispatcher Dispatcher { get; }

        public ValueTask DisposeAsync()
        {
            Dispatcher.BeginInvokeShutdown(DispatcherPriority.Send);
            if (!_thread.Join(TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException("The test STA dispatcher did not stop.");
            }

            return ValueTask.CompletedTask;
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

    private sealed class SaturatedBrowseOperations : IAmmarTradingOperations
    {
        private static readonly object Result = JsonSerializer.SerializeToElement(new { ready = true });
        private readonly IWebViewDispatcher _dispatcher;
        private readonly SemaphoreSlim _release = new(0);
        private int _started;

        public SaturatedBrowseOperations(IWebViewDispatcher dispatcher)
        {
            _dispatcher = dispatcher;
        }

        public TaskCompletionSource<(ApartmentState ApartmentState, bool HasDispatcherAccess)> BrowseAffinity { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource FourStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<object> GetSystemStatusAsync(CancellationToken token) => BlockAsync(token);

        public Task<object> DiscoverMt4AccountsAsync(CancellationToken token) => Completed(token);

        public Task<object> BrowseForCsvAsync(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            BrowseAffinity.TrySetResult((
                Thread.CurrentThread.GetApartmentState(),
                _dispatcher.CheckAccess()));
            return Task.FromResult(Result);
        }

        public Task<object> GetOneDriveRootsAsync(CancellationToken token) => Completed(token);

        public Task<object> GetConfiguredAccountsAsync(CancellationToken token) => Completed(token);

        public Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token) => Completed(token);

        public Task<object> ExportSupportReportAsync(CancellationToken token) => Completed(token);

        public void ReleaseOneSlot() => _release.Release();

        private async Task<object> BlockAsync(CancellationToken token)
        {
            if (Interlocked.Increment(ref _started) == 4)
            {
                FourStarted.TrySetResult();
            }

            await _release.WaitAsync(token);
            return Result;
        }

        private static Task<object> Completed(CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult(Result);
        }
    }
}
