using Microsoft.Web.WebView2.Core;

namespace AmmarTrading.Sync.App.Hosting;

internal sealed record WebViewFeaturePolicy(
    bool DevTools,
    bool ContextMenus,
    bool BrowserAccelerators,
    bool StatusBar,
    bool PasswordAutosave,
    bool GeneralAutofill);

internal static class WebViewSecurityPolicy
{
    public const string AppHostName = "ammartrading.app";
    public const string AppOrigin = "https://ammartrading.app/";

    public static WebViewFeaturePolicy ReleaseFeatures { get; } = new(
        DevTools: false,
        ContextMenus: false,
        BrowserAccelerators: false,
        StatusBar: false,
        PasswordAutosave: false,
        GeneralAutofill: false);

    public static bool IsAllowedAppUri(Uri? uri) =>
        uri is { IsAbsoluteUri: true, IsDefaultPort: true } &&
        uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
        uri.IdnHost.Equals(AppHostName, StringComparison.OrdinalIgnoreCase) &&
        string.IsNullOrEmpty(uri.UserInfo);

    public static bool IsAllowedAppAddress(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && IsAllowedAppUri(uri);

    public static bool IsAllowedResourceAddress(string? address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return IsAllowedAppUri(uri) || uri.Scheme.Equals("data", StringComparison.OrdinalIgnoreCase);
    }

    public static void ApplyReleaseFeatures(CoreWebView2Settings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var policy = ReleaseFeatures;
        settings.AreDevToolsEnabled = policy.DevTools;
        settings.AreDefaultContextMenusEnabled = policy.ContextMenus;
        settings.AreBrowserAcceleratorKeysEnabled = policy.BrowserAccelerators;
        settings.IsStatusBarEnabled = policy.StatusBar;
        settings.IsPasswordAutosaveEnabled = policy.PasswordAutosave;
        settings.IsGeneralAutofillEnabled = policy.GeneralAutofill;
    }
}
