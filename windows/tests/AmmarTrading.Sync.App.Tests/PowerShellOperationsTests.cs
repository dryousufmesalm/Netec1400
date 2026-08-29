using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using AmmarTrading.Sync.App.Services;
using Xunit;

namespace AmmarTrading.Sync.App.Tests;

public sealed class PowerShellOperationsTests : IDisposable
{
    private const string CsvFilter = "MT4 basket CSV (AGOLD___Baskets.csv)|AGOLD___Baskets.csv|CSV files (*.csv)|*.csv";

    private readonly string _testRoot = Path.Combine(
        Path.GetTempPath(),
        $"AmmarTradingOperationsTests_{Guid.NewGuid():N}");

    public PowerShellOperationsTests()
    {
        Directory.CreateDirectory(Path.Combine(_testRoot, "app", "Scripts"));
        File.WriteAllText(
            Path.Combine(_testRoot, "app", "Scripts", "Invoke-AmmarTradingDesktopOperation.ps1"),
            "# fixed test entry point");
    }

    [Fact]
    public async Task ValidateSelection_UsesFixedExecutableAndSeparateArgumentsWithoutUserValues()
    {
        const string userValue = "C:\\MT4\\value'; Invoke-Expression 'credential=secret";
        string? requestJson = null;
        var runner = FakeProcessRunner.Completes(invocation =>
        {
            var requestPath = ArgumentAfter(invocation, "-RequestPath");
            requestJson = File.ReadAllText(requestPath);
            AssertCurrentUserOnly(requestPath);
            return Success("{\"Stages\":[]}");
        });
        var operations = CreateOperations(runner);
        using var payload = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            vpsName = userValue,
            oneDriveRoot = "C:\\OneDrive",
            accounts = Array.Empty<object>(),
        }));

        await operations.ValidateSelectionAsync(payload.RootElement, default);

        var invocation = Assert.Single(runner.Invocations);
        Assert.Equal("powershell.exe", invocation.FileName);
        Assert.Contains("-NoProfile", invocation.ArgumentList);
        Assert.Contains("-NonInteractive", invocation.ArgumentList);
        Assert.Contains("-File", invocation.ArgumentList);
        Assert.Equal("Validate", ArgumentAfter(invocation, "-Operation"));
        Assert.Equal(Path.Combine(_testRoot, "app", "Scripts", "Invoke-AmmarTradingDesktopOperation.ps1"), ArgumentAfter(invocation, "-File"));
        Assert.DoesNotContain(invocation.ArgumentList, value => value.Contains("Invoke-Expression", StringComparison.OrdinalIgnoreCase));
        Assert.DoesNotContain(invocation.ArgumentList, value => value.Contains(userValue, StringComparison.Ordinal));
        Assert.Equal(TimeSpan.FromSeconds(120), invocation.Timeout);
        using (var request = JsonDocument.Parse(Assert.IsType<string>(requestJson)))
        {
            Assert.Equal(userValue, request.RootElement.GetProperty("vpsName").GetString());
        }
        Assert.False(File.Exists(ArgumentAfter(invocation, "-RequestPath")));
    }

    [Fact]
    public async Task DiscoverMt4Accounts_WhenTimeoutExpires_KillsChildAndDeletesRequest()
    {
        var process = new FakeRunningProcess();
        var runner = new FakeProcessRunner(_ => process);
        var operations = CreateOperations(runner, shortTimeout: TimeSpan.FromMilliseconds(20));

        var error = await Assert.ThrowsAsync<PowerShellOperationException>(
            () => operations.DiscoverMt4AccountsAsync(default));

        Assert.Equal("OperationTimedOut", error.Code);
        Assert.Equal("The operation did not finish in time.", error.Message);
        Assert.Equal(1, process.KillCount);
        var invocation = Assert.Single(runner.Invocations);
        Assert.Equal(TimeSpan.FromMilliseconds(20), invocation.Timeout);
        Assert.False(File.Exists(ArgumentAfter(invocation, "-RequestPath")));
    }

    [Fact]
    public async Task GetSystemStatus_WhenCancelled_KillsChildAndDeletesRequest()
    {
        var process = new FakeRunningProcess();
        var runner = new FakeProcessRunner(_ => process);
        var operations = CreateOperations(runner);
        using var cancellation = new CancellationTokenSource();
        var operation = operations.GetSystemStatusAsync(cancellation.Token);

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operation);
        Assert.Equal(1, process.KillCount);
        var invocation = Assert.Single(runner.Invocations);
        Assert.False(File.Exists(ArgumentAfter(invocation, "-RequestPath")));
    }

    [Theory]
    [InlineData("not-json")]
    [InlineData("[]")]
    [InlineData("{\"ok\":true}{\"second\":true}")]
    public async Task GetSystemStatus_WhenStdoutIsNotOneJsonObject_ReturnsStableSafeError(string stdout)
    {
        var runner = FakeProcessRunner.Returns(Success(stdout));
        var operations = CreateOperations(runner);

        var error = await Assert.ThrowsAsync<PowerShellOperationException>(
            () => operations.GetSystemStatusAsync(default));

        Assert.Equal("InvalidPowerShellResponse", error.Code);
        Assert.Equal("The operation returned an unreadable response.", error.Message);
        Assert.DoesNotContain(stdout, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ApplySetup_WhenChildFails_DoesNotExposeOrLogStderrContents()
    {
        const string secret = "password=correct-horse-battery-staple";
        const string csvRow = "1234,Broker,1,XAUUSD,BUY";
        var runner = FakeProcessRunner.Returns(new ProcessResult(17, string.Empty, $"{secret}\n{csvRow}"));
        var operations = CreateOperations(runner);
        using var payload = JsonDocument.Parse("{\"accounts\":[]}");

        var error = await Assert.ThrowsAsync<PowerShellOperationException>(
            () => operations.ApplySetupAsync(payload.RootElement, default));

        Assert.Equal("PowerShellFailed", error.Code);
        Assert.Equal("The operation could not be completed.", error.Message);
        var log = File.ReadAllText(Path.Combine(_testRoot, "runtime", "logs", "desktop-operations.log"));
        Assert.DoesNotContain(secret, log, StringComparison.Ordinal);
        Assert.DoesNotContain(csvRow, log, StringComparison.Ordinal);
        Assert.Contains("PowerShellFailed", log, StringComparison.Ordinal);
        Assert.Contains("\"exitCode\":17", log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task GetSystemStatus_WhenChildWritesStderrDespiteZeroExit_ReturnsSafeError()
    {
        const string secret = "credential=must-not-escape";
        var runner = FakeProcessRunner.Returns(new ProcessResult(0, "{}", secret));
        var operations = CreateOperations(runner);

        var error = await Assert.ThrowsAsync<PowerShellOperationException>(
            () => operations.GetSystemStatusAsync(default));

        Assert.Equal("PowerShellFailed", error.Code);
        Assert.Equal("The operation could not be completed.", error.Message);
        Assert.DoesNotContain(secret, error.Message, StringComparison.Ordinal);
        var log = File.ReadAllText(Path.Combine(_testRoot, "runtime", "logs", "desktop-operations.log"));
        Assert.DoesNotContain(secret, log, StringComparison.Ordinal);
        Assert.Contains("\"stderrLength\":26", log, StringComparison.Ordinal);
    }

    [Fact]
    public async Task Operations_MapEveryPowerShellBackedMethodToAllowlistedOperationAndTimeout()
    {
        var runner = FakeProcessRunner.Completes(invocation =>
        {
            var operation = ArgumentAfter(invocation, "-Operation");
            return operation switch
            {
                "Status" => Success("{\"Accounts\":[]}"),
                _ => Success("{}"),
            };
        });
        var operations = CreateOperations(runner);
        using var payload = JsonDocument.Parse("{}");

        await operations.GetSystemStatusAsync(default);
        await operations.DiscoverMt4AccountsAsync(default);
        await operations.GetOneDriveRootsAsync(default);
        await operations.GetConfiguredAccountsAsync(default);
        await operations.ValidateSelectionAsync(payload.RootElement, default);
        await operations.ApplySetupAsync(payload.RootElement, default);
        await operations.RunSyncNowAsync(payload.RootElement, default);

        Assert.Equal(
            new[] { "SystemStatus", "Discover", "OneDriveRoots", "Status", "Validate", "Apply", "SyncNow" },
            runner.Invocations.Select(value => ArgumentAfter(value, "-Operation")));
        Assert.Equal(
            new[] { 30, 30, 30, 30, 120, 120, 120 },
            runner.Invocations.Select(value => (int)value.Timeout.TotalSeconds));
    }

    [Fact]
    public async Task BrowseForCsv_UsesExactFilterAndSendsCanonicalPathThroughDiscovery()
    {
        var csvPath = Path.Combine(_testRoot, "selected", "AGOLD___Baskets.csv");
        Directory.CreateDirectory(Path.GetDirectoryName(csvPath)!);
        File.WriteAllText(csvPath, "header");
        var picker = new FakeFilePicker(csvPath);
        var native = new NativeDialogService(picker, new FakeNativeProcessLauncher());
        string? requestJson = null;
        var runner = FakeProcessRunner.Completes(invocation =>
        {
            requestJson = File.ReadAllText(ArgumentAfter(invocation, "-RequestPath"));
            return Success("{\"Accounts\":[]}");
        });
        var operations = CreateOperations(runner, nativeDialogService: native);

        await operations.BrowseForCsvAsync(default);

        Assert.Equal(CsvFilter, picker.Filter);
        Assert.Equal("Discover", ArgumentAfter(Assert.Single(runner.Invocations), "-Operation"));
        using var request = JsonDocument.Parse(Assert.IsType<string>(requestJson));
        Assert.Equal(Path.GetFullPath(csvPath), request.RootElement.GetProperty("manualCsv")[0].GetString());
    }

    [Fact]
    public async Task BrowseForCsv_WhenDialogIsCancelled_DoesNotStartPowerShell()
    {
        var runner = FakeProcessRunner.Returns(Success("{}"));
        var native = new NativeDialogService(new FakeFilePicker(null), new FakeNativeProcessLauncher());
        var operations = CreateOperations(runner, nativeDialogService: native);

        var error = await Assert.ThrowsAsync<PowerShellOperationException>(
            () => operations.BrowseForCsvAsync(default));

        Assert.Equal("Cancelled", error.Code);
        Assert.Empty(runner.Invocations);
    }

    [Fact]
    public async Task OpenReportingFolder_OpensOnlyMatchedConfiguredAccountDirectory()
    {
        var accountDirectory = Path.Combine(_testRoot, "OneDrive", "AmmarTrading", "Account_123456");
        Directory.CreateDirectory(accountDirectory);
        var launcher = new FakeNativeProcessLauncher();
        var native = new NativeDialogService(new FakeFilePicker(null), launcher);
        var statusJson = JsonSerializer.Serialize(new
        {
            Accounts = new[]
            {
                new
                {
                    AccountNumber = "123456",
                    Destination = Path.Combine(accountDirectory, "Baskets.csv"),
                },
            },
        });
        var runner = FakeProcessRunner.Returns(Success(statusJson));
        var operations = CreateOperations(runner, nativeDialogService: native);
        using var payload = JsonDocument.Parse("{\"accountNumbers\":[\"123456\"],\"path\":\"C:\\\\Windows\"}");

        await operations.OpenReportingFolderAsync(payload.RootElement, default);

        var invocation = Assert.Single(launcher.Invocations);
        Assert.Equal("explorer.exe", invocation.FileName);
        Assert.Equal(new[] { accountDirectory }, invocation.ArgumentList);
        Assert.DoesNotContain("Windows", invocation.ArgumentList[0], StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SupportReport_AllowlistsMetadataRedactsPathsAndOmitsRowsAndCredentials()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var source = Path.Combine(profile, "MetaQuotes", "Terminal", "ABC", "MQL4", "Files", "AGOLD___Baskets.csv");
        using var system = JsonDocument.Parse("""
            {
              "ApplicationVersion":"1.2.3",
              "WindowsVersion":"Windows 11",
              "OneDriveRoots":[{"Path":"C:\\Users\\operator\\OneDrive","Available":true,"Credential":"onedrive-secret"}],
              "Checks":[{"Code":"ScheduledTasks","Status":"Ready"}],
              "MicrosoftPassword":"never-export-this"
            }
            """);
        using var discovery = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            Accounts = new[]
            {
                new
                {
                    TerminalId = "ABC",
                    AccountNumber = "123456",
                    SchemaVersion = "3",
                    Eligibility = "Ready",
                    ReasonCode = "Ready",
                    SourceCsv = source,
                    CsvRows = new[] { "123456,Broker,1,XAUUSD" },
                },
            },
        }));
        using var status = JsonDocument.Parse("""
            {"Accounts":[{"AccountNumber":"123456","StatusCode":"Fresh","TaskResultCode":"0","Credential":"task-secret"}]}
            """);
        var service = new SupportReportService(Path.Combine(_testRoot, "runtime"), "1.2.3");

        var result = service.Export(system.RootElement, discovery.RootElement, status.RootElement);
        var report = File.ReadAllText(result.Path);

        Assert.Contains("\"applicationVersion\": \"1.2.3\"", report, StringComparison.Ordinal);
        Assert.Contains("\"terminalId\": \"ABC\"", report, StringComparison.Ordinal);
        Assert.Contains("\"accountNumber\": \"123456\"", report, StringComparison.Ordinal);
        Assert.Contains("\"schemaVersion\": \"3\"", report, StringComparison.Ordinal);
        Assert.Contains("\"taskResultCode\": \"0\"", report, StringComparison.Ordinal);
        Assert.Contains("%USERPROFILE%", report, StringComparison.Ordinal);
        Assert.DoesNotContain("CsvRows", report, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("123456,Broker,1,XAUUSD", report, StringComparison.Ordinal);
        Assert.DoesNotContain("Password", report, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("secret", report, StringComparison.OrdinalIgnoreCase);
        if (!string.IsNullOrWhiteSpace(profile))
        {
            Assert.DoesNotContain(profile, report, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public async Task ExportSupportReport_CollectsOnlyDiagnosticOperationsThenWritesReport()
    {
        var runner = FakeProcessRunner.Completes(invocation => ArgumentAfter(invocation, "-Operation") switch
        {
            "SystemStatus" => Success("{\"WindowsVersion\":\"Windows 11\",\"OneDriveRoots\":[]}"),
            "Discover" => Success("{\"Accounts\":[]}"),
            "Status" => Success("{\"Accounts\":[]}"),
            _ => throw new InvalidOperationException("Unexpected operation."),
        });
        var operations = CreateOperations(runner);

        var exported = await operations.ExportSupportReportAsync(default);

        Assert.Equal(new[] { "SystemStatus", "Discover", "Status" }, runner.Invocations.Select(value => ArgumentAfter(value, "-Operation")));
        var result = Assert.IsType<SupportReportResult>(exported);
        Assert.True(File.Exists(result.Path));
    }

    public void Dispose()
    {
        if (Directory.Exists(_testRoot))
        {
            Directory.Delete(_testRoot, recursive: true);
        }
    }

    private PowerShellOperations CreateOperations(
        IProcessRunner runner,
        TimeSpan? shortTimeout = null,
        INativeDialogService? nativeDialogService = null) =>
        new(
            Path.Combine(_testRoot, "app"),
            Path.Combine(_testRoot, "runtime"),
            runner,
            nativeDialogService ?? new NativeDialogService(new FakeFilePicker(null), new FakeNativeProcessLauncher()),
            new SupportReportService(Path.Combine(_testRoot, "runtime"), "test-version"),
            shortTimeout,
            TimeSpan.FromSeconds(120));

    private static ProcessResult Success(string json) => new(0, json, string.Empty);

    private static string ArgumentAfter(ProcessInvocation invocation, string name)
    {
        var index = invocation.ArgumentList.ToList().IndexOf(name);
        Assert.True(index >= 0 && index + 1 < invocation.ArgumentList.Count, $"Argument '{name}' was not present.");
        return invocation.ArgumentList[index + 1];
    }

    private static void AssertCurrentUserOnly(string path)
    {
        var currentUser = WindowsIdentity.GetCurrent().User;
        Assert.NotNull(currentUser);
        var rules = new FileInfo(path).GetAccessControl().GetAccessRules(
            includeExplicit: true,
            includeInherited: false,
            typeof(SecurityIdentifier));
        var allowRules = rules.Cast<FileSystemAccessRule>()
            .Where(rule => rule.AccessControlType == AccessControlType.Allow)
            .ToArray();
        var rule = Assert.Single(allowRules);
        Assert.Equal(currentUser, rule.IdentityReference);
    }

    private sealed class FakeProcessRunner : IProcessRunner
    {
        private readonly Func<ProcessInvocation, IRunningProcess> _start;

        public FakeProcessRunner(Func<ProcessInvocation, IRunningProcess> start)
        {
            _start = start;
        }

        public List<ProcessInvocation> Invocations { get; } = [];

        public IRunningProcess Start(ProcessInvocation invocation)
        {
            Invocations.Add(invocation);
            return _start(invocation);
        }

        public static FakeProcessRunner Returns(ProcessResult result) =>
            new(_ => FakeRunningProcess.Completed(result));

        public static FakeProcessRunner Completes(Func<ProcessInvocation, ProcessResult> result) =>
            new(invocation => FakeRunningProcess.Completed(result(invocation)));
    }

    private sealed class FakeRunningProcess : IRunningProcess
    {
        private readonly TaskCompletionSource<ProcessResult> _completion = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<ProcessResult> Completion => _completion.Task;

        public int KillCount { get; private set; }

        public static FakeRunningProcess Completed(ProcessResult result)
        {
            var process = new FakeRunningProcess();
            process._completion.SetResult(result);
            return process;
        }

        public void Kill()
        {
            KillCount++;
        }

        public void Dispose()
        {
        }
    }

    private sealed class FakeFilePicker : IFilePicker
    {
        private readonly string? _result;

        public FakeFilePicker(string? result)
        {
            _result = result;
        }

        public string? Filter { get; private set; }

        public string? PickFile(string filter)
        {
            Filter = filter;
            return _result;
        }
    }

    private sealed class FakeNativeProcessLauncher : INativeProcessLauncher
    {
        public List<NativeProcessInvocation> Invocations { get; } = [];

        public void Start(NativeProcessInvocation invocation)
        {
            Invocations.Add(invocation);
        }
    }
}
