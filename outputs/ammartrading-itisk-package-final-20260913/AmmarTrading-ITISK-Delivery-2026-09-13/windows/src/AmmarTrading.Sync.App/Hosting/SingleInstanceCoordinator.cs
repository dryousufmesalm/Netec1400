using System.Diagnostics;
using System.IO;
using System.IO.Pipes;

namespace AmmarTrading.Sync.App.Hosting;

internal sealed class ActivationPipe : IDisposable, IAsyncDisposable
{
    private const byte ActivationMessage = 0x41;

    private readonly CancellationTokenSource _disposeCancellation = new();
    private readonly Func<CancellationToken, Task> _listenerFailureBackoff;
    private readonly IAppMetadataLogger _logger;
    private readonly string _pipeName;
    private int _disposed;

    public ActivationPipe(
        string pipeName,
        IAppMetadataLogger logger,
        Func<CancellationToken, Task>? listenerFailureBackoff = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        _pipeName = pipeName;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _listenerFailureBackoff = listenerFailureBackoff ?? DefaultListenerFailureBackoffAsync;
    }

    public async Task ListenAsync(Action activate, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(activate);
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            token,
            _disposeCancellation.Token);
        var linkedToken = linkedCancellation.Token;

        while (!linkedToken.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    _pipeName,
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(linkedToken).ConfigureAwait(false);
                var signal = new byte[1];
                var received = await server.ReadAsync(signal, linkedToken).ConfigureAwait(false);
                if (received == 1 && signal[0] == ActivationMessage)
                {
                    _logger.Write(AppLogEvent.ActivationSignalReceived);
                    activate();
                }
            }
            catch (OperationCanceledException) when (linkedToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                _logger.Write(AppLogEvent.ActivationListenerFailed);
                try
                {
                    await _listenerFailureBackoff(linkedToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (linkedToken.IsCancellationRequested)
                {
                    break;
                }
            }
        }
    }

    public static async Task<bool> TrySignalAsync(
        string pipeName,
        TimeSpan timeout,
        CancellationToken token = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        if (timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(timeout));
        }

        using var timeoutCancellation = new CancellationTokenSource(timeout);
        using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            token,
            timeoutCancellation.Token);
        var linkedToken = linkedCancellation.Token;

        while (!linkedToken.IsCancellationRequested)
        {
            try
            {
                using var client = new NamedPipeClientStream(
                    ".",
                    pipeName,
                    PipeDirection.Out,
                    PipeOptions.Asynchronous);
                await client.ConnectAsync(200, linkedToken).ConfigureAwait(false);
                await client.WriteAsync(new[] { ActivationMessage }, linkedToken).ConfigureAwait(false);
                await client.FlushAsync(linkedToken).ConfigureAwait(false);
                return true;
            }
            catch (TimeoutException)
            {
                await DelayBeforeRetryAsync(linkedToken).ConfigureAwait(false);
            }
            catch (IOException)
            {
                await DelayBeforeRetryAsync(linkedToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (linkedToken.IsCancellationRequested)
            {
                break;
            }
        }

        return false;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            _disposeCancellation.Cancel();
            _disposeCancellation.Dispose();
        }
    }

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }

    private static async Task DelayBeforeRetryAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(50, token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    private static Task DefaultListenerFailureBackoffAsync(CancellationToken token) =>
        Task.Delay(TimeSpan.FromMilliseconds(250), token);
}

internal sealed class SingleInstanceCoordinator : IDisposable
{
    internal const string MutexName = @"Local\AmmarTrading.Sync";

    private readonly ActivationPipe? _activationPipe;
    private readonly IAppMetadataLogger _logger;
    private readonly Mutex _mutex;
    private readonly string _pipeName;
    private Task? _listener;
    private int _disposed;

    public SingleInstanceCoordinator(IAppMetadataLogger logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _pipeName = PipeNameForSession(CurrentSessionId());
        _mutex = new Mutex(initiallyOwned: false, MutexName);
        try
        {
            IsPrimary = _mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            IsPrimary = true;
        }

        if (IsPrimary)
        {
            _activationPipe = new ActivationPipe(_pipeName, _logger);
        }
    }

    public bool IsPrimary { get; }

    internal static string PipeNameForSession(int sessionId)
    {
        if (sessionId < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(sessionId));
        }

        return $"AmmarTrading.Sync.Activation.Session.{sessionId}";
    }

    public void StartListening(Action activate)
    {
        if (!IsPrimary || _activationPipe is null)
        {
            throw new InvalidOperationException("Only the primary instance can listen for activation.");
        }

        if (_listener is not null)
        {
            throw new InvalidOperationException("The activation listener is already running.");
        }

        _listener = _activationPipe.ListenAsync(activate);
    }

    public async Task<bool> TryActivatePrimaryAsync(CancellationToken token = default)
    {
        if (IsPrimary)
        {
            return true;
        }

        var activated = await ActivationPipe.TrySignalAsync(
            _pipeName,
            TimeSpan.FromSeconds(3),
            token).ConfigureAwait(false);
        _logger.Write(activated
            ? AppLogEvent.SecondaryInstanceActivated
            : AppLogEvent.ActivationSignalFailed);
        return activated;
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _activationPipe?.Dispose();
        if (IsPrimary)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
            }
        }

        _mutex.Dispose();
    }

    private static int CurrentSessionId()
    {
        using var process = Process.GetCurrentProcess();
        return process.SessionId;
    }
}
