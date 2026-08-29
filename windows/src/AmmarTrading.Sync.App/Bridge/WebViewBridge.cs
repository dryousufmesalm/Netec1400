using System.Text.Json;
using AmmarTrading.Sync.App.Hosting;
using AmmarTrading.Sync.Core.Bridge;
using Microsoft.Web.WebView2.Core;

namespace AmmarTrading.Sync.App.Bridge;

internal sealed class WebMessageJsonEventArgs : EventArgs
{
    public WebMessageJsonEventArgs(string json)
    {
        Json = json ?? throw new ArgumentNullException(nameof(json));
    }

    public string Json { get; }
}

internal interface IWebViewMessageHost : IDisposable
{
    event EventHandler<WebMessageJsonEventArgs>? MessageReceived;

    ValueTask PostWebMessageAsJsonAsync(string json, CancellationToken token);
}

internal sealed class CoreWebViewMessageHost : IWebViewMessageHost
{
    private readonly CoreWebView2 _coreWebView;
    private readonly IWebViewDispatcher _dispatcher;
    private readonly DeferredWebMessageReceiver _receiver;
    private int _disposed;

    public CoreWebViewMessageHost(
        CoreWebView2 coreWebView,
        IWebViewDispatcher dispatcher,
        IAppMetadataLogger logger)
    {
        _coreWebView = coreWebView ?? throw new ArgumentNullException(nameof(coreWebView));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _receiver = new DeferredWebMessageReceiver(
            _dispatcher,
            logger ?? throw new ArgumentNullException(nameof(logger)));
        _coreWebView.WebMessageReceived += OnWebMessageReceived;
    }

    public event EventHandler<WebMessageJsonEventArgs>? MessageReceived
    {
        add => _receiver.MessageReceived += value;
        remove => _receiver.MessageReceived -= value;
    }

    public async ValueTask PostWebMessageAsJsonAsync(string json, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(json);
        token.ThrowIfCancellationRequested();
        await _dispatcher.InvokeAsync(
                () => _coreWebView.PostWebMessageAsJson(json),
                token)
            .ConfigureAwait(false);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            _coreWebView.WebMessageReceived -= OnWebMessageReceived;
        }
    }

    private void OnWebMessageReceived(
        object? sender,
        CoreWebView2WebMessageReceivedEventArgs eventArgs)
    {
        _receiver.Receive(eventArgs.Source, eventArgs.WebMessageAsJson);
    }
}

internal sealed class WebViewBridge : IAsyncDisposable
{
    private const int MaximumConcurrentCommands = 4;

    private readonly HashSet<Task> _activeTasks = new();
    private readonly IWebViewMessageHost _host;
    private readonly IWebViewDispatcher _dispatcher;
    private readonly IAppMetadataLogger _logger;
    private readonly BridgeCommandRouter _router;
    private readonly CancellationTokenSource _shutdown = new();
    private readonly SemaphoreSlim _slots = new(MaximumConcurrentCommands, MaximumConcurrentCommands);
    private readonly object _sync = new();
    private bool _accepting = true;
    private Task? _disposeTask;

    public WebViewBridge(
        BridgeCommandRouter router,
        IWebViewMessageHost host,
        IWebViewDispatcher dispatcher,
        IAppMetadataLogger logger)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _host.MessageReceived += OnMessageReceived;
    }

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_disposeTask is not null)
            {
                return new ValueTask(_disposeTask);
            }

            _accepting = false;
            _shutdown.Cancel();
            _disposeTask = DrainAndDisposeAsync(_activeTasks.ToArray());
            return new ValueTask(_disposeTask);
        }
    }

    private void OnMessageReceived(object? sender, WebMessageJsonEventArgs eventArgs)
    {
        Task task;
        lock (_sync)
        {
            if (!_accepting)
            {
                return;
            }

            task = HandleMessageAsync(eventArgs.Json);
            _activeTasks.Add(task);
        }

        _ = ObserveAsync(task);
    }

    private async Task HandleMessageAsync(string json)
    {
        var entered = false;
        try
        {
            await _slots.WaitAsync(_shutdown.Token).ConfigureAwait(false);
            entered = true;
            var response = await _dispatcher.InvokeAsync(
                    () => _router.RouteAsync(json, _shutdown.Token),
                    _shutdown.Token)
                .ConfigureAwait(false);
            if (_shutdown.IsCancellationRequested)
            {
                return;
            }

            string responseJson;
            try
            {
                responseJson = JsonSerializer.Serialize(response);
            }
            catch
            {
                _logger.Write(AppLogEvent.BridgeResponseSerializationFailed);
                responseJson = JsonSerializer.Serialize(new BridgeResponse(
                    1,
                    response.Id,
                    false,
                    "OperationFailed",
                    "The requested operation could not be completed.",
                    null));
            }

            await _host.PostWebMessageAsJsonAsync(responseJson, _shutdown.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_shutdown.IsCancellationRequested)
        {
        }
        catch
        {
            _logger.Write(AppLogEvent.BridgeMessageFailed);
        }
        finally
        {
            if (entered)
            {
                _slots.Release();
            }
        }
    }

    private async Task ObserveAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
        }
        finally
        {
            lock (_sync)
            {
                _activeTasks.Remove(task);
            }
        }
    }

    private async Task DrainAndDisposeAsync(Task[] activeTasks)
    {
        try
        {
            await Task.WhenAll(activeTasks).ConfigureAwait(false);
        }
        catch
        {
            _logger.Write(AppLogEvent.BridgeMessageFailed);
        }
        try
        {
            await _dispatcher.InvokeAsync(
                    () =>
                    {
                        _host.MessageReceived -= OnMessageReceived;
                        _host.Dispose();
                    },
                    CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch
        {
            _logger.Write(AppLogEvent.WebViewTeardownFailed);
        }
        finally
        {
            _slots.Dispose();
            _shutdown.Dispose();
        }
    }
}
