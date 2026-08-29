using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using AmmarTrading.Sync.Core.Services;

namespace AmmarTrading.Sync.App.Services;

public sealed record ProcessInvocation(
    string FileName,
    IReadOnlyList<string> ArgumentList,
    string WorkingDirectory,
    TimeSpan Timeout);

public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError);

public interface IRunningProcess : IDisposable
{
    Task<ProcessResult> Completion { get; }

    void Kill();
}

public interface IProcessRunner
{
    IRunningProcess Start(ProcessInvocation invocation);
}

public sealed class PowerShellOperationException : Exception
{
    public PowerShellOperationException(string code, string message)
        : base(message)
    {
        Code = code;
    }

    public string Code { get; }
}

public sealed class PowerShellOperations : IAmmarTradingOperations
{
    private const int MaximumResponseBytes = 1024 * 1024;

    private static readonly TimeSpan DefaultShortTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan DefaultSetupTimeout = TimeSpan.FromSeconds(120);
    private static readonly JsonElement EmptyPayload = JsonSerializer.SerializeToElement(new { });

    private readonly string _entryPointPath;
    private readonly string _runtimeRoot;
    private readonly string _requestRoot;
    private readonly string _diagnosticLogPath;
    private readonly IProcessRunner _processRunner;
    private readonly INativeDialogService _nativeDialogService;
    private readonly ISupportReportService _supportReportService;
    private readonly TimeSpan _shortTimeout;
    private readonly TimeSpan _setupTimeout;

    public PowerShellOperations()
        : this(
            AppContext.BaseDirectory,
            GetDefaultRuntimeRoot(),
            new SystemProcessRunner(),
            new NativeDialogService(),
            new SupportReportService(GetDefaultRuntimeRoot()))
    {
    }

    public PowerShellOperations(
        string applicationRoot,
        string runtimeRoot,
        IProcessRunner processRunner,
        INativeDialogService nativeDialogService,
        ISupportReportService supportReportService,
        TimeSpan? shortTimeout = null,
        TimeSpan? setupTimeout = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(applicationRoot);
        ArgumentException.ThrowIfNullOrWhiteSpace(runtimeRoot);
        _processRunner = processRunner ?? throw new ArgumentNullException(nameof(processRunner));
        _nativeDialogService = nativeDialogService ?? throw new ArgumentNullException(nameof(nativeDialogService));
        _supportReportService = supportReportService ?? throw new ArgumentNullException(nameof(supportReportService));
        _shortTimeout = ValidateTimeout(shortTimeout ?? DefaultShortTimeout, nameof(shortTimeout));
        _setupTimeout = ValidateTimeout(setupTimeout ?? DefaultSetupTimeout, nameof(setupTimeout));

        var canonicalApplicationRoot = Path.GetFullPath(applicationRoot);
        _runtimeRoot = Path.GetFullPath(runtimeRoot);
        _entryPointPath = Path.Combine(
            canonicalApplicationRoot,
            "Scripts",
            "Invoke-AmmarTradingDesktopOperation.ps1");
        _requestRoot = Path.Combine(_runtimeRoot, "requests");
        _diagnosticLogPath = Path.Combine(_runtimeRoot, "logs", "desktop-operations.log");

        SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_runtimeRoot);
        SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_requestRoot);
        SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(Path.GetDirectoryName(_diagnosticLogPath)!);
    }

    public Task<object> GetSystemStatusAsync(CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.SystemStatus, EmptyPayload, _shortTimeout, token);

    public Task<object> DiscoverMt4AccountsAsync(CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.Discover, EmptyPayload, _shortTimeout, token);

    public async Task<object> BrowseForCsvAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var selectedPath = _nativeDialogService.BrowseForCsv();
        if (selectedPath is null)
        {
            throw new PowerShellOperationException("Cancelled", "No CSV file was selected.");
        }

        var payload = JsonSerializer.SerializeToElement(new { manualCsv = new[] { selectedPath } });
        return await InvokeObjectAsync(DesktopOperation.Discover, payload, _shortTimeout, token).ConfigureAwait(false);
    }

    public Task<object> GetOneDriveRootsAsync(CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.OneDriveRoots, EmptyPayload, _shortTimeout, token);

    public Task<object> GetConfiguredAccountsAsync(CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.Status, EmptyPayload, _shortTimeout, token);

    public Task<object> ValidateSelectionAsync(JsonElement payload, CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.Validate, payload, _setupTimeout, token);

    public Task<object> ApplySetupAsync(JsonElement payload, CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.Apply, payload, _setupTimeout, token);

    public Task<object> RunSyncNowAsync(JsonElement payload, CancellationToken token) =>
        InvokeObjectAsync(DesktopOperation.SyncNow, payload, _setupTimeout, token);

    public async Task<object> OpenReportingFolderAsync(JsonElement payload, CancellationToken token)
    {
        var configuredStatus = await InvokeAsync(
            DesktopOperation.Status,
            EmptyPayload,
            _shortTimeout,
            token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        return _nativeDialogService.OpenConfiguredReportingFolder(payload, configuredStatus);
    }

    public async Task<object> ExportSupportReportAsync(CancellationToken token)
    {
        var systemStatus = await InvokeAsync(
            DesktopOperation.SystemStatus,
            EmptyPayload,
            _shortTimeout,
            token).ConfigureAwait(false);
        var discovery = await InvokeAsync(
            DesktopOperation.Discover,
            EmptyPayload,
            _shortTimeout,
            token).ConfigureAwait(false);
        var configuredStatus = await InvokeAsync(
            DesktopOperation.Status,
            EmptyPayload,
            _shortTimeout,
            token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        return _supportReportService.Export(systemStatus, discovery, configuredStatus);
    }

    private static string GetDefaultRuntimeRoot()
    {
        var localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new InvalidOperationException("The local application data folder is unavailable.");
        }

        return Path.Combine(localApplicationData, "AmmarTrading", "Sync");
    }

    private async Task<object> InvokeObjectAsync(
        DesktopOperation operation,
        JsonElement payload,
        TimeSpan timeout,
        CancellationToken token) =>
        await InvokeAsync(operation, payload, timeout, token).ConfigureAwait(false);

    private async Task<JsonElement> InvokeAsync(
        DesktopOperation operation,
        JsonElement payload,
        TimeSpan timeout,
        CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!File.Exists(_entryPointPath))
        {
            WriteDiagnostic(operation, "ApplicationFilesMissing", null, 0, 0);
            throw new PowerShellOperationException(
                "ApplicationFilesMissing",
                "A required application file is missing. Reinstall AmmarTrading Sync.");
        }

        var requestPath = CreateRequestFile(payload);
        var invocation = new ProcessInvocation(
            "powershell.exe",
            new[]
            {
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                _entryPointPath,
                "-Operation",
                operation.ToString(),
                "-RequestPath",
                requestPath,
                "-RuntimeRoot",
                _runtimeRoot,
            },
            Path.GetDirectoryName(_entryPointPath)!,
            timeout);

        IRunningProcess? runningProcess = null;
        try
        {
            try
            {
                runningProcess = _processRunner.Start(invocation);
            }
            catch
            {
                WriteDiagnostic(operation, "ProcessStartFailed", null, 0, 0);
                throw new PowerShellOperationException(
                    "PowerShellUnavailable",
                    "Windows PowerShell could not be started.");
            }

            ProcessResult result;
            try
            {
                result = await runningProcess.Completion.WaitAsync(timeout, token).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                KillWithoutMasking(runningProcess);
                WriteDiagnostic(operation, "OperationTimedOut", null, 0, 0);
                throw new PowerShellOperationException(
                    "OperationTimedOut",
                    "The operation did not finish in time.");
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                KillWithoutMasking(runningProcess);
                WriteDiagnostic(operation, "OperationCancelled", null, 0, 0);
                throw;
            }

            if (result.ExitCode != 0 || result.StandardError.Length > 0)
            {
                WriteDiagnostic(
                    operation,
                    "PowerShellFailed",
                    result.ExitCode,
                    result.StandardOutput.Length,
                    result.StandardError.Length);
                throw new PowerShellOperationException(
                    "PowerShellFailed",
                    "The operation could not be completed.");
            }

            try
            {
                if (Encoding.UTF8.GetByteCount(result.StandardOutput) > MaximumResponseBytes)
                {
                    throw new JsonException("The response was too large.");
                }

                using var document = JsonDocument.Parse(result.StandardOutput, new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 64,
                });
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    throw new JsonException("The response root was not an object.");
                }

                return document.RootElement.Clone();
            }
            catch (JsonException)
            {
                WriteDiagnostic(
                    operation,
                    "InvalidPowerShellResponse",
                    result.ExitCode,
                    result.StandardOutput.Length,
                    result.StandardError.Length);
                throw new PowerShellOperationException(
                    "InvalidPowerShellResponse",
                    "The operation returned an unreadable response.");
            }
        }
        finally
        {
            runningProcess?.Dispose();
            DeleteRequestWithoutMasking(requestPath);
        }
    }

    private string CreateRequestFile(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object)
        {
            throw new PowerShellOperationException("InvalidRequest", "The operation request is not valid.");
        }

        SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_requestRoot);
        var requestPath = Path.Combine(_requestRoot, $"request.{Guid.NewGuid():N}.json");
        using (var stream = new FileStream(
            requestPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            bufferSize: 4096,
            FileOptions.WriteThrough))
        using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
        {
            writer.Write(payload.GetRawText());
        }

        SecureRuntimeFiles.RestrictFileToCurrentUser(requestPath);
        return requestPath;
    }

    private void WriteDiagnostic(
        DesktopOperation operation,
        string eventCode,
        int? exitCode,
        int stdoutLength,
        int stderrLength)
    {
        try
        {
            SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(Path.GetDirectoryName(_diagnosticLogPath)!);
            var line = JsonSerializer.Serialize(new
            {
                timestampUtc = DateTimeOffset.UtcNow,
                operation = operation.ToString(),
                eventCode,
                exitCode,
                stdoutLength,
                stderrLength,
            });
            File.AppendAllText(
                _diagnosticLogPath,
                line + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch
        {
            // Diagnostic failures must never replace a stable operation error.
        }
    }

    private static void KillWithoutMasking(IRunningProcess process)
    {
        try
        {
            process.Kill();
        }
        catch
        {
            // Preserve the timeout or cancellation that triggered the kill.
        }
    }

    private static void DeleteRequestWithoutMasking(string requestPath)
    {
        try
        {
            File.Delete(requestPath);
        }
        catch
        {
            // Do not obscure the operation result with cleanup errors.
        }
    }

    private static TimeSpan ValidateTimeout(TimeSpan timeout, string parameterName)
    {
        if (timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(parameterName, "The timeout must be positive.");
        }

        return timeout;
    }

    private enum DesktopOperation
    {
        SystemStatus,
        Discover,
        OneDriveRoots,
        Validate,
        Apply,
        Status,
        SyncNow,
    }
}

public sealed class SystemProcessRunner : IProcessRunner
{
    public IRunningProcess Start(ProcessInvocation invocation)
    {
        ArgumentNullException.ThrowIfNull(invocation);
        var startInfo = new ProcessStartInfo
        {
            FileName = invocation.FileName,
            WorkingDirectory = invocation.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (var argument in invocation.ArgumentList)
        {
            startInfo.ArgumentList.Add(argument);
        }

        var process = new Process
        {
            StartInfo = startInfo,
            EnableRaisingEvents = true,
        };
        if (!process.Start())
        {
            process.Dispose();
            throw new InvalidOperationException("The process did not start.");
        }

        return new SystemRunningProcess(process);
    }

    private sealed class SystemRunningProcess : IRunningProcess
    {
        private readonly Process _process;
        private int _disposeScheduled;

        public SystemRunningProcess(Process process)
        {
            _process = process;
            Completion = CompleteAsync();
        }

        public Task<ProcessResult> Completion { get; }

        public void Kill()
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposeScheduled, 1) != 0)
            {
                return;
            }

            if (Completion.IsCompleted)
            {
                _process.Dispose();
                return;
            }

            _ = Completion.ContinueWith(
                _ => _process.Dispose(),
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private async Task<ProcessResult> CompleteAsync()
        {
            var standardOutput = _process.StandardOutput.ReadToEndAsync();
            var standardError = _process.StandardError.ReadToEndAsync();
            await _process.WaitForExitAsync().ConfigureAwait(false);
            return new ProcessResult(
                _process.ExitCode,
                await standardOutput.ConfigureAwait(false),
                await standardError.ConfigureAwait(false));
        }
    }
}

internal static class SecureRuntimeFiles
{
    public static void EnsureCurrentUserOnlyDirectory(string path)
    {
        Directory.CreateDirectory(path);
        var currentUser = CurrentUser();
        var security = new DirectorySecurity();
        security.SetOwner(currentUser);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            currentUser,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(security);
    }

    public static void RestrictFileToCurrentUser(string path)
    {
        var currentUser = CurrentUser();
        var security = new FileSecurity();
        security.SetOwner(currentUser);
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.AddAccessRule(new FileSystemAccessRule(
            currentUser,
            FileSystemRights.FullControl,
            AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }

    private static SecurityIdentifier CurrentUser() =>
        WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("The current Windows user could not be identified.");
}
