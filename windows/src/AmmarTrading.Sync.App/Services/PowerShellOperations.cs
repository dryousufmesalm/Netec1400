using System.Diagnostics;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using AmmarTrading.Sync.Core.Services;
using Microsoft.Win32.SafeHandles;

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

    Task TerminateAndConfirmAsync();
}

public sealed class ProcessOutputLimitException : Exception
{
    public ProcessOutputLimitException()
        : base("A redirected process stream exceeded its byte limit.")
    {
    }
}

public sealed class ProcessOutputEncodingException : Exception
{
    public ProcessOutputEncodingException()
        : base("A redirected process stream was not valid UTF-8.")
    {
    }
}

public interface IProcessRunner
{
    IRunningProcess Start(ProcessInvocation invocation);
}

public sealed class PowerShellOperationException : SafeOperationException
{
    public PowerShellOperationException(string code, string message)
        : base(code, message)
    {
    }
}

public sealed class PowerShellOperations : IAmmarTradingOperations
{
    private const int MaximumResponseBytes = 1024 * 1024;
    private static readonly Regex SafeDesktopFailureCode = new(
        "^[A-Za-z][A-Za-z0-9]{0,63}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly Regex SafeDesktopFailureMessage = new(
        "^[A-Za-z0-9 .,'()-]{1,200}$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

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

    public Task<object> BrowseForOneDriveFolderAsync(JsonElement payload, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var initialPath = payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("initialPath", out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;
        var selectedPath = _nativeDialogService.BrowseForOneDriveFolder(initialPath);
        if (selectedPath is null) throw new PowerShellOperationException("Cancelled", "No OneDrive folder was selected.");
        return Task.FromResult<object>(new { path = selectedPath });
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

        return Path.Combine(localApplicationData, "AmarTrading", "Sync");
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
                "A required application file is missing. Reinstall AmarTrading Sync.");
        }

        SecureRequestFile? requestFile = null;
        IRunningProcess? runningProcess = null;
        var operationFailed = false;
        try
        {
            try
            {
                requestFile = SecureRequestFile.Create(_requestRoot, payload);
            }
            catch (SecureRequestFileException error)
            {
                WriteDiagnostic(operation, error.Code, null, 0, 0);
                throw new PowerShellOperationException(error.Code, error.SafeMessage);
            }

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
                    requestFile.Path,
                    "-RuntimeRoot",
                    _runtimeRoot,
                },
                Path.GetDirectoryName(_entryPointPath)!,
                timeout);

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
                await ConfirmTerminationAsync(runningProcess, operation).ConfigureAwait(false);
                WriteDiagnostic(operation, "OperationTimedOut", null, 0, 0);
                throw new PowerShellOperationException(
                    "OperationTimedOut",
                    "The operation did not finish in time.");
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            {
                await ConfirmTerminationAsync(runningProcess, operation).ConfigureAwait(false);
                WriteDiagnostic(operation, "OperationCancelled", null, 0, 0);
                throw;
            }
            catch (ProcessOutputLimitException)
            {
                await ConfirmTerminationAsync(runningProcess, operation).ConfigureAwait(false);
                WriteDiagnostic(operation, "OutputLimitExceeded", null, MaximumResponseBytes, MaximumResponseBytes);
                throw new PowerShellOperationException(
                    "OutputLimitExceeded",
                    "The operation produced too much output.");
            }
            catch (ProcessOutputEncodingException)
            {
                await ConfirmTerminationAsync(runningProcess, operation).ConfigureAwait(false);
                WriteDiagnostic(operation, "InvalidPowerShellResponse", null, 0, 0);
                throw new PowerShellOperationException(
                    "InvalidPowerShellResponse",
                    "The operation returned an unreadable response.");
            }
            catch
            {
                await ConfirmTerminationAsync(runningProcess, operation).ConfigureAwait(false);
                WriteDiagnostic(operation, "ProcessExecutionFailed", null, 0, 0);
                throw new PowerShellOperationException(
                    "PowerShellFailed",
                    "The operation could not be completed.");
            }

            if (result.ExitCode != 0 || result.StandardError.Length > 0)
            {
                WriteDiagnostic(
                    operation,
                    "PowerShellFailed",
                    result.ExitCode,
                    result.StandardOutput.Length,
                    result.StandardError.Length);
                if (result.ExitCode != 0 &&
                    result.StandardError.Length == 0 &&
                    TryReadSafeDesktopFailure(result.StandardOutput, out var failureCode, out var failureMessage))
                {
                    throw new PowerShellOperationException(failureCode, failureMessage);
                }

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
        catch
        {
            operationFailed = true;
            throw;
        }
        finally
        {
            runningProcess?.Dispose();
            if (requestFile is not null)
            {
                try
                {
                    requestFile.DeleteAndConfirm();
                }
                catch
                {
                    WriteDiagnostic(operation, "RequestCleanupFailed", null, 0, 0);
                    if (!operationFailed)
                    {
                        throw new PowerShellOperationException(
                            "RequestCleanupFailed",
                            "The private operation request could not be removed safely.");
                    }
                }
                finally
                {
                    requestFile.Dispose();
                }
            }
        }
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

    private async Task ConfirmTerminationAsync(IRunningProcess process, DesktopOperation operation)
    {
        try
        {
            await process.TerminateAndConfirmAsync().ConfigureAwait(false);
        }
        catch
        {
            WriteDiagnostic(operation, "TerminationUnconfirmed", null, 0, 0);
            throw new PowerShellOperationException(
                "TerminationUnconfirmed",
                "The operation process could not be stopped safely.");
        }
    }

    private static bool TryReadSafeDesktopFailure(string stdout, out string code, out string message)
    {
        code = string.Empty;
        message = string.Empty;
        if (string.IsNullOrWhiteSpace(stdout) || Encoding.UTF8.GetByteCount(stdout) > 4096)
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(stdout, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8,
            });
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            if (!document.RootElement.TryGetProperty("Ok", out var okElement) &&
                !document.RootElement.TryGetProperty("ok", out okElement))
            {
                return false;
            }

            if (okElement.ValueKind != JsonValueKind.False)
            {
                return false;
            }

            if (!TryReadJsonString(document.RootElement, "Code", "code", out var parsedCode) ||
                !TryReadJsonString(document.RootElement, "Message", "message", out var parsedMessage))
            {
                return false;
            }

            if (!SafeDesktopFailureCode.IsMatch(parsedCode) ||
                !SafeDesktopFailureMessage.IsMatch(parsedMessage))
            {
                return false;
            }

            code = parsedCode;
            message = parsedMessage;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool TryReadJsonString(JsonElement root, string pascalName, string camelName, out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(pascalName, out var property) &&
            !root.TryGetProperty(camelName, out property))
        {
            return false;
        }

        if (property.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var parsed = property.GetString();
        if (string.IsNullOrWhiteSpace(parsed))
        {
            return false;
        }

        value = parsed;
        return true;
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
    private const int DefaultStreamLimitBytes = 1024 * 1024;

    private readonly int _standardOutputLimitBytes;
    private readonly int _standardErrorLimitBytes;

    public SystemProcessRunner(
        int standardOutputLimitBytes = DefaultStreamLimitBytes,
        int standardErrorLimitBytes = DefaultStreamLimitBytes)
    {
        if (standardOutputLimitBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(standardOutputLimitBytes));
        }

        if (standardErrorLimitBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(standardErrorLimitBytes));
        }

        _standardOutputLimitBytes = standardOutputLimitBytes;
        _standardErrorLimitBytes = standardErrorLimitBytes;
    }

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
        var job = WindowsJobObject.Create();
        if (!process.Start())
        {
            job.Dispose();
            process.Dispose();
            throw new InvalidOperationException("The process did not start.");
        }

        try
        {
            job.Assign(process);
            return new SystemRunningProcess(
                process,
                job,
                _standardOutputLimitBytes,
                _standardErrorLimitBytes);
        }
        catch
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(5000);
                }
            }
            finally
            {
                job.Dispose();
                process.Dispose();
            }

            throw;
        }
    }

    private sealed class SystemRunningProcess : IRunningProcess
    {
        private static readonly UTF8Encoding StrictUtf8 = new(false, true);

        private readonly Process _process;
        private readonly WindowsJobObject _job;
        private readonly int _standardOutputLimitBytes;
        private readonly int _standardErrorLimitBytes;
        private int _disposeScheduled;
        private int _terminationRequested;

        public SystemRunningProcess(
            Process process,
            WindowsJobObject job,
            int standardOutputLimitBytes,
            int standardErrorLimitBytes)
        {
            _process = process;
            _job = job;
            _standardOutputLimitBytes = standardOutputLimitBytes;
            _standardErrorLimitBytes = standardErrorLimitBytes;
            Completion = CompleteAsync();
        }

        public Task<ProcessResult> Completion { get; }

        public async Task TerminateAndConfirmAsync()
        {
            if (Interlocked.Exchange(ref _terminationRequested, 1) == 0)
            {
                _job.Terminate();
            }

            using var confirmationTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await Task.WhenAll(
                    _process.WaitForExitAsync(confirmationTimeout.Token),
                    _job.WaitForEmptyAsync(confirmationTimeout.Token))
                .ConfigureAwait(false);
            if (!_process.HasExited || _job.ActiveProcessCount != 0)
            {
                throw new InvalidOperationException("Process-tree termination was not confirmed.");
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
                _job.Dispose();
                _process.Dispose();
                return;
            }

            _ = Completion.ContinueWith(
                _ =>
                {
                    _job.Dispose();
                    _process.Dispose();
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private async Task<ProcessResult> CompleteAsync()
        {
            var standardOutput = ReadBoundedAsync(
                _process.StandardOutput.BaseStream,
                _standardOutputLimitBytes);
            var standardError = ReadBoundedAsync(
                _process.StandardError.BaseStream,
                _standardErrorLimitBytes);
            var processExit = _process.WaitForExitAsync();
            try
            {
                await Task.WhenAll(standardOutput, standardError, processExit).ConfigureAwait(false);
                return new ProcessResult(
                    _process.ExitCode,
                    StrictUtf8.GetString(await standardOutput.ConfigureAwait(false)),
                    StrictUtf8.GetString(await standardError.ConfigureAwait(false)));
            }
            catch (ProcessOutputLimitException)
            {
                await TerminateAndConfirmAsync().ConfigureAwait(false);
                throw;
            }
            catch (DecoderFallbackException)
            {
                await TerminateAndConfirmAsync().ConfigureAwait(false);
                throw new ProcessOutputEncodingException();
            }
        }

        private async Task<byte[]> ReadBoundedAsync(Stream stream, int maximumBytes)
        {
            using var output = new MemoryStream(Math.Min(maximumBytes, 16 * 1024));
            var buffer = new byte[8192];
            while (true)
            {
                var read = await stream.ReadAsync(buffer).ConfigureAwait(false);
                if (read == 0)
                {
                    return output.ToArray();
                }

                if (output.Length + read > maximumBytes)
                {
                    if (Interlocked.Exchange(ref _terminationRequested, 1) == 0)
                    {
                        _job.Terminate();
                    }

                    throw new ProcessOutputLimitException();
                }

                output.Write(buffer, 0, read);
            }
        }
    }
}

internal sealed class WindowsJobObject : IDisposable
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private readonly SafeFileHandle _handle;

    private WindowsJobObject(SafeFileHandle handle)
    {
        _handle = handle;
    }

    public static WindowsJobObject Create()
    {
        var handle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
        if (handle.IsInvalid)
        {
            throw new InvalidOperationException("A Windows Job Object could not be created.");
        }

        var information = new NativeMethods.JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new NativeMethods.JobObjectBasicLimitInformation
            {
                LimitFlags = JobObjectLimitKillOnJobClose,
            },
        };
        var length = Marshal.SizeOf<NativeMethods.JobObjectExtendedLimitInformation>();
        var pointer = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(information, pointer, false);
            if (!NativeMethods.SetInformationJobObject(handle, 9, pointer, (uint)length))
            {
                throw new InvalidOperationException("The Windows Job Object could not be configured.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }

        return new WindowsJobObject(handle);
    }

    public void Assign(Process process)
    {
        if (!NativeMethods.AssignProcessToJobObject(_handle, process.Handle))
        {
            throw new InvalidOperationException("The operation process could not be assigned to its Windows Job Object.");
        }
    }

    public void Terminate()
    {
        if (!NativeMethods.TerminateJobObject(_handle, 1))
        {
            throw new InvalidOperationException("The Windows Job Object could not be terminated.");
        }
    }

    public uint ActiveProcessCount
    {
        get
        {
            var information = new NativeMethods.JobObjectBasicAccountingInformation();
            if (!NativeMethods.QueryInformationJobObject(
                    _handle,
                    1,
                    ref information,
                    (uint)Marshal.SizeOf<NativeMethods.JobObjectBasicAccountingInformation>(),
                    out _))
            {
                throw new InvalidOperationException("The Windows Job Object state could not be queried.");
            }

            return information.ActiveProcesses;
        }
    }

    public async Task WaitForEmptyAsync(CancellationToken token)
    {
        while (ActiveProcessCount != 0)
        {
            await Task.Delay(25, token).ConfigureAwait(false);
        }
    }

    public void Dispose() => _handle.Dispose();

    private static class NativeMethods
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateJobObject(IntPtr jobAttributes, string? name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(
            SafeFileHandle job,
            int informationClass,
            IntPtr information,
            uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool QueryInformationJobObject(
            SafeFileHandle job,
            int informationClass,
            ref JobObjectBasicAccountingInformation jobObjectInformation,
            uint jobObjectInformationLength,
            out uint returnLength);

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectBasicLimitInformation
        {
            internal long PerProcessUserTimeLimit;
            internal long PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize;
            internal UIntPtr MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass;
            internal uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectBasicAccountingInformation
        {
            internal long TotalUserTime;
            internal long TotalKernelTime;
            internal long ThisPeriodTotalUserTime;
            internal long ThisPeriodTotalKernelTime;
            internal uint TotalPageFaultCount;
            internal uint TotalProcesses;
            internal uint ActiveProcesses;
            internal uint TotalTerminatedProcesses;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct IoCounters
        {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectExtendedLimitInformation
        {
            internal JobObjectBasicLimitInformation BasicLimitInformation;
            internal IoCounters IoInfo;
            internal UIntPtr ProcessMemoryLimit;
            internal UIntPtr JobMemoryLimit;
            internal UIntPtr PeakProcessMemoryUsed;
            internal UIntPtr PeakJobMemoryUsed;
        }
    }
}

internal sealed class SecureRequestFileException : Exception
{
    public SecureRequestFileException(string code, string safeMessage)
        : base(safeMessage)
    {
        Code = code;
        SafeMessage = safeMessage;
    }

    public string Code { get; }

    public string SafeMessage { get; }
}

internal sealed class SecureRequestFile : IDisposable
{
    private FileStream? _handle;
    private int _deleted;

    private SecureRequestFile(string path, FileStream handle)
    {
        Path = path;
        _handle = handle;
    }

    public string Path { get; }

    public static SecureRequestFile Create(string requestRoot, JsonElement payload) =>
        Create(requestRoot, payload, null);

    internal static SecureRequestFile Create(
        string requestRoot,
        JsonElement payload,
        Action<SecureRequestFileStage, string>? testObserver)
    {
        if (payload.ValueKind != JsonValueKind.Object)
        {
            throw new SecureRequestFileException("InvalidRequest", "The operation request is not valid.");
        }

        requestRoot = System.IO.Path.GetFullPath(requestRoot);
        string? requestPath = null;
        FileStream? stream = null;
        try
        {
            try
            {
                SecureRuntimeFiles.VerifyLocalDirectoryPath(requestRoot, requireFinalDirectory: false);
            }
            catch
            {
                throw new SecureRequestFileException(
                    "RequestDirectoryUntrusted",
                    "The private operation request directory is not trusted.");
            }

            if (!Directory.Exists(requestRoot))
            {
                throw new SecureRequestFileException(
                    "RequestFileUnavailable",
                    "A private operation request could not be created.");
            }

            try
            {
                SecureRuntimeFiles.VerifyCurrentUserOnlyDirectory(requestRoot);
            }
            catch
            {
                throw new SecureRequestFileException(
                    "RequestDirectoryUntrusted",
                    "The private operation request directory is not trusted.");
            }

            requestPath = System.IO.Path.Combine(requestRoot, $"request.{Guid.NewGuid():N}.json");
            stream = new FileStream(
                requestPath,
                FileMode.CreateNew,
                FileAccess.ReadWrite,
                FileShare.Read,
                bufferSize: 4096,
                FileOptions.WriteThrough);
            testObserver?.Invoke(SecureRequestFileStage.BeforeWrite, requestPath);
            using (var writer = new StreamWriter(
                       stream,
                       new UTF8Encoding(false, true),
                       bufferSize: 4096,
                       leaveOpen: true))
            {
                writer.Write(payload.GetRawText());
                writer.Flush();
            }

            stream.Flush(flushToDisk: true);
            stream.Position = 0;
            testObserver?.Invoke(SecureRequestFileStage.BeforeAcl, requestPath);
            SecureRuntimeFiles.RestrictFileToCurrentUser(requestPath);
            var attributes = File.GetAttributes(requestPath);
            if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                !SecureRuntimeFiles.IsCurrentUserOnlyFile(requestPath))
            {
                throw new InvalidOperationException("The request file protection could not be verified.");
            }
            return new SecureRequestFile(requestPath, stream);
        }
        catch (SecureRequestFileException)
        {
            stream?.Dispose();
            throw;
        }
        catch
        {
            stream?.Dispose();
            if (requestPath is not null && File.Exists(requestPath))
            {
                try
                {
                    File.Delete(requestPath);
                }
                catch
                {
                    throw new SecureRequestFileException(
                        "RequestCleanupFailed",
                        "The private operation request could not be removed safely.");
                }
            }

            throw new SecureRequestFileException(
                "RequestFileUnavailable",
                "A private operation request could not be created.");
        }
    }

    public void DeleteAndConfirm()
    {
        if (Interlocked.Exchange(ref _deleted, 1) != 0)
        {
            return;
        }

        _handle?.Dispose();
        _handle = null;
        File.Delete(Path);
        if (File.Exists(Path))
        {
            throw new IOException("Request deletion was not confirmed.");
        }
    }

    public void Dispose()
    {
        _handle?.Dispose();
        _handle = null;
    }

}

internal enum SecureRequestFileStage
{
    BeforeWrite,
    BeforeAcl,
}

internal static class SecureRuntimeFiles
{
    public static void EnsureCurrentUserOnlyDirectory(string path)
    {
        var canonicalPath = Path.GetFullPath(path);
        VerifyLocalNonReparsePath(canonicalPath, requireFinalDirectory: false);
        Directory.CreateDirectory(canonicalPath);
        VerifyLocalNonReparsePath(canonicalPath, requireFinalDirectory: true);
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
        new DirectoryInfo(canonicalPath).SetAccessControl(security);
        VerifyCurrentUserOnlyDirectory(canonicalPath);
    }

    public static void VerifyCurrentUserOnlyDirectory(string path)
    {
        var canonicalPath = Path.GetFullPath(path);
        VerifyLocalNonReparsePath(canonicalPath, requireFinalDirectory: true);
        var currentUser = CurrentUser();
        var security = new DirectoryInfo(canonicalPath).GetAccessControl();
        if (!security.AreAccessRulesProtected ||
            !Equals(security.GetOwner(typeof(SecurityIdentifier)), currentUser))
        {
            throw new InvalidOperationException("The private directory protection could not be verified.");
        }

        var rules = security.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                typeof(SecurityIdentifier))
            .Cast<FileSystemAccessRule>()
            .ToArray();
        if (rules.Length != 1 ||
            rules[0].AccessControlType != AccessControlType.Allow ||
            !rules[0].IdentityReference.Equals(currentUser) ||
            (rules[0].FileSystemRights & FileSystemRights.FullControl) != FileSystemRights.FullControl)
        {
            throw new InvalidOperationException("The private directory ACL could not be verified.");
        }
    }

    public static void VerifyLocalDirectoryPath(string path, bool requireFinalDirectory) =>
        VerifyLocalNonReparsePath(Path.GetFullPath(path), requireFinalDirectory);

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

    public static bool IsCurrentUserOnlyFile(string path)
    {
        var security = new FileInfo(path).GetAccessControl();
        var currentUser = CurrentUser();
        if (!security.AreAccessRulesProtected ||
            !Equals(security.GetOwner(typeof(SecurityIdentifier)), currentUser))
        {
            return false;
        }

        var rules = security.GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            typeof(SecurityIdentifier));
        var allowRules = rules.Cast<FileSystemAccessRule>()
            .Where(rule => rule.AccessControlType == AccessControlType.Allow)
            .ToArray();
        return allowRules.Length == 1 &&
               allowRules[0].IdentityReference.Equals(currentUser) &&
               (allowRules[0].FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl;
    }

    private static void VerifyLocalNonReparsePath(string canonicalPath, bool requireFinalDirectory)
    {
        if (!Path.IsPathRooted(canonicalPath) || canonicalPath.StartsWith("\\\\", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("The private directory must use a local filesystem path.");
        }

        var volumeRoot = Path.GetPathRoot(canonicalPath);
        if (string.IsNullOrWhiteSpace(volumeRoot) || new DriveInfo(volumeRoot).DriveType == DriveType.Network)
        {
            throw new InvalidOperationException("The private directory must use a local filesystem volume.");
        }

        var current = volumeRoot;
        foreach (var part in canonicalPath[volumeRoot.Length..].Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
                     StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (!File.Exists(current) && !Directory.Exists(current))
            {
                break;
            }

            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("The private directory cannot contain a reparse point.");
            }
        }

        if (requireFinalDirectory && !Directory.Exists(canonicalPath))
        {
            throw new InvalidOperationException("The private directory is unavailable.");
        }
    }

    private static SecurityIdentifier CurrentUser() =>
        WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("The current Windows user could not be identified.");
}
