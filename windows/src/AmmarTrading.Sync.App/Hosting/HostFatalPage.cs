namespace AmmarTrading.Sync.App.Hosting;

internal sealed record HostFatalPageContent(string Title, string Message);

internal static class HostFatalPage
{
    public static HostFatalPageContent ForWebViewInitializationFailure(Exception error)
    {
        ArgumentNullException.ThrowIfNull(error);
        return new HostFatalPageContent(
            "AmmarTrading Sync couldn't start",
            "The secure Windows web component could not be initialized. Repair or install Microsoft Edge WebView2 Runtime, then reopen AmmarTrading Sync.");
    }
}
