using System.IO;
using System.Text;
using System.Text.Json;
using AmmarTrading.Sync.App.Services;

namespace AmmarTrading.Sync.App.Hosting;

internal sealed record AppRuntimePaths(
    string RuntimeRoot,
    string LogDirectory,
    string WebViewUserDataDirectory)
{
    public static AppRuntimePaths CreateDefault()
    {
        var localApplicationData = Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new InvalidOperationException("The local application data folder is unavailable.");
        }

        return FromLocalApplicationData(localApplicationData);
    }

    public static AppRuntimePaths FromLocalApplicationData(string localApplicationData)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(localApplicationData);
        var runtimeRoot = Path.Combine(
            Path.GetFullPath(localApplicationData),
            "AmarTrading",
            "Sync");
        return new AppRuntimePaths(
            runtimeRoot,
            Path.Combine(runtimeRoot, "Logs"),
            Path.Combine(runtimeRoot, "WebView2"));
    }
}

internal enum AppLogEvent
{
    ApplicationStarted,
    ApplicationStopping,
    ActivationListenerFailed,
    ActivationSignalFailed,
    ActivationSignalReceived,
    BridgeMessageFailed,
    BridgeResponseSerializationFailed,
    SecondaryInstanceActivated,
    UntrustedWebMessageRejected,
    WebViewTeardownFailed,
    WebViewAssetsMapped,
    WebViewControlInitialized,
    WebViewEnvironmentCreated,
    WebViewInitializationFailed,
    WebViewInitialized,
    WebViewPolicyConfigured,
    WindowCloseApproved,
}

internal interface IAppMetadataLogger
{
    void Write(AppLogEvent eventCode);
}

internal sealed class AppMetadataLogger : IAppMetadataLogger
{
    private readonly object _writeLock = new();
    private readonly string _logDirectory;
    private readonly string _logPath;

    public AppMetadataLogger(AppRuntimePaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        _logDirectory = Path.GetFullPath(paths.LogDirectory);
        _logPath = Path.Combine(_logDirectory, "application.jsonl");
    }

    public void Write(AppLogEvent eventCode)
    {
        try
        {
            lock (_writeLock)
            {
                SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_logDirectory);
                var line = JsonSerializer.Serialize(new
                {
                    timestampUtc = DateTimeOffset.UtcNow,
                    eventCode = eventCode.ToString(),
                });
                File.AppendAllText(
                    _logPath,
                    line + Environment.NewLine,
                    new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                SecureRuntimeFiles.RestrictFileToCurrentUser(_logPath);
            }
        }
        catch
        {
            // Logging must never replace a stable UI or bridge outcome.
        }
    }
}
