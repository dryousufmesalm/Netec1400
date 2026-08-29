using System.Windows.Threading;
using AmmarTrading.Sync.App.Hosting;

namespace AmmarTrading.Sync.App.Bridge;

internal interface IWebViewDispatcher
{
    bool CheckAccess();

    void Post(Action callback);

    Task InvokeAsync(Action callback, CancellationToken token);

    Task<T> InvokeAsync<T>(Func<Task<T>> callback, CancellationToken token);
}

internal sealed class WpfWebViewDispatcher : IWebViewDispatcher
{
    private readonly Dispatcher _dispatcher;

    public WpfWebViewDispatcher(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
    }

    public bool CheckAccess() => _dispatcher.CheckAccess();

    public void Post(Action callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        _ = _dispatcher.BeginInvoke(callback, DispatcherPriority.Normal);
    }

    public Task InvokeAsync(Action callback, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(callback);
        token.ThrowIfCancellationRequested();
        if (_dispatcher.CheckAccess())
        {
            callback();
            return Task.CompletedTask;
        }

        return _dispatcher.InvokeAsync(
                callback,
                DispatcherPriority.Normal,
                token)
            .Task;
    }

    public async Task<T> InvokeAsync<T>(Func<Task<T>> callback, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(callback);
        token.ThrowIfCancellationRequested();
        Task<T> callbackTask;
        if (_dispatcher.CheckAccess())
        {
            callbackTask = callback();
        }
        else
        {
            callbackTask = await _dispatcher.InvokeAsync(
                    callback,
                    DispatcherPriority.Normal,
                    token)
                .Task
                .ConfigureAwait(false);
        }

        return await callbackTask.ConfigureAwait(false);
    }
}

internal sealed class DeferredWebMessageReceiver
{
    private readonly IWebViewDispatcher _dispatcher;
    private readonly IAppMetadataLogger _logger;

    public DeferredWebMessageReceiver(
        IWebViewDispatcher dispatcher,
        IAppMetadataLogger logger)
    {
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public event EventHandler<WebMessageJsonEventArgs>? MessageReceived;

    public void Receive(string? source, string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        try
        {
            _dispatcher.Post(() => Deliver(source, json));
        }
        catch
        {
            _logger.Write(AppLogEvent.BridgeMessageFailed);
        }
    }

    private void Deliver(string? source, string json)
    {
        if (!WebViewSecurityPolicy.IsAllowedAppAddress(source))
        {
            _logger.Write(AppLogEvent.UntrustedWebMessageRejected);
            return;
        }

        try
        {
            MessageReceived?.Invoke(this, new WebMessageJsonEventArgs(json));
        }
        catch
        {
            _logger.Write(AppLogEvent.BridgeMessageFailed);
        }
    }
}
