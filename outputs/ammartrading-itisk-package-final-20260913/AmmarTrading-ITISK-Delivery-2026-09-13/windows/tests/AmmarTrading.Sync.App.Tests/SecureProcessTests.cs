using System.Diagnostics;
using AmmarTrading.Sync.App.Services;
using Xunit;

namespace AmmarTrading.Sync.App.Tests;

public sealed class SecureProcessTests : IDisposable
{
    private readonly string _testRoot = Path.Combine(
        Path.GetTempPath(),
        $"AmmarTradingSecureProcessTests_{Guid.NewGuid():N}");

    public SecureProcessTests()
    {
        Directory.CreateDirectory(_testRoot);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SystemRunner_WhenRedirectedStreamExceedsByteCap_TerminatesWithoutUnboundedCapture(
        bool useStandardError)
    {
        var scriptPath = Path.Combine(_testRoot, $"overflow-{useStandardError}.ps1");
        var streamExpression = useStandardError
            ? "[Console]::OpenStandardError()"
            : "[Console]::OpenStandardOutput()";
        File.WriteAllText(
            scriptPath,
            $"$bytes=New-Object byte[] 131072; {streamExpression}.Write($bytes,0,$bytes.Length); Start-Sleep -Seconds 30");
        var runner = new SystemProcessRunner(32 * 1024, 32 * 1024);
        using var process = runner.Start(Invocation(scriptPath));
        var stopwatch = Stopwatch.StartNew();

        await Assert.ThrowsAsync<ProcessOutputLimitException>(() => process.Completion);

        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(10));
        await process.TerminateAndConfirmAsync();
    }

    [Fact]
    public async Task SystemRunner_TerminateAndConfirm_KillsDescendantInJobObject()
    {
        var childIdPath = Path.Combine(_testRoot, "child.pid");
        var scriptPath = Path.Combine(_testRoot, "job-tree.ps1");
        File.WriteAllText(
            scriptPath,
            $"$child=Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -PassThru; Set-Content -LiteralPath '{childIdPath.Replace("'", "''")}' -Value $child.Id; Start-Sleep -Seconds 60");
        var runner = new SystemProcessRunner();
        using var process = runner.Start(Invocation(scriptPath));
        using var wait = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        while (!File.Exists(childIdPath))
        {
            await Task.Delay(25, wait.Token);
        }

        var childId = int.Parse(File.ReadAllText(childIdPath));
        await process.TerminateAndConfirmAsync();
        await Assert.ThrowsAsync<ArgumentException>(() => Task.Run(() => Process.GetProcessById(childId)));
    }

    [Fact]
    public async Task SystemRunner_WhenRedirectedOutputIsNotUtf8_RejectsIt()
    {
        var scriptPath = Path.Combine(_testRoot, "invalid-utf8.ps1");
        File.WriteAllText(
            scriptPath,
            "$bytes=[byte[]](255); [Console]::OpenStandardOutput().Write($bytes,0,$bytes.Length)");
        var runner = new SystemProcessRunner();
        using var process = runner.Start(Invocation(scriptPath));

        await Assert.ThrowsAsync<ProcessOutputEncodingException>(() => process.Completion);
    }

    public void Dispose()
    {
        if (Directory.Exists(_testRoot))
        {
            Directory.Delete(_testRoot, recursive: true);
        }
    }

    private ProcessInvocation Invocation(string scriptPath) =>
        new(
            "powershell.exe",
            ["-NoProfile", "-NonInteractive", "-File", scriptPath],
            _testRoot,
            TimeSpan.FromSeconds(10));
}
