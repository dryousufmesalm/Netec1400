using System.ComponentModel;
using System.IO;
using System.Windows;
using AmmarTrading.Sync.App.Bridge;
using AmmarTrading.Sync.App.Hosting;
using AmmarTrading.Sync.App.Services;
using AmmarTrading.Sync.Core.Bridge;
using Microsoft.Web.WebView2.Core;

namespace AmmarTrading.Sync.App;

public partial class MainWindow : Window
{
    private readonly IAppMetadataLogger _logger;
    private readonly AppRuntimePaths _paths;
    private readonly BridgeCommandRouter _router;
    private WebViewBridge? _bridge;
    private bool _closeApproved;
    private bool _closeDrainStarted;
    private bool _initializationStarted;
    private bool _windowClosed;

    internal MainWindow(
        BridgeCommandRouter router,
        AppRuntimePaths paths,
        IAppMetadataLogger logger)
    {
        _router = router ?? throw new ArgumentNullException(nameof(router));
        _paths = paths ?? throw new ArgumentNullException(nameof(paths));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        InitializeComponent();
        Loaded += OnLoaded;
    }

    protected override void OnClosing(CancelEventArgs eventArgs)
    {
        if (!_closeApproved && _bridge is not null)
        {
            eventArgs.Cancel = true;
            if (!_closeDrainStarted)
            {
                _closeDrainStarted = true;
                IsEnabled = false;
                _ = CancelCommandsAndCloseAsync();
            }
        }

        base.OnClosing(eventArgs);
    }

    protected override void OnClosed(EventArgs eventArgs)
    {
        _windowClosed = true;
        Browser.Dispose();
        base.OnClosed(eventArgs);
    }

    private async void OnLoaded(object sender, RoutedEventArgs eventArgs)
    {
        if (_initializationStarted)
        {
            return;
        }

        _initializationStarted = true;
        try
        {
            var assetRoot = Path.Combine(AppContext.BaseDirectory, "Assets", "Web");
            if (!File.Exists(Path.Combine(assetRoot, "index.html")))
            {
                throw new FileNotFoundException("The packaged application entry point is unavailable.");
            }

            SecureRuntimeFiles.EnsureCurrentUserOnlyDirectory(_paths.WebViewUserDataDirectory);
            var environment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: _paths.WebViewUserDataDirectory);
            _logger.Write(AppLogEvent.WebViewEnvironmentCreated);
            await Browser.EnsureCoreWebView2Async(environment);
            _logger.Write(AppLogEvent.WebViewControlInitialized);
            if (_windowClosed)
            {
                return;
            }

            var coreWebView = Browser.CoreWebView2;
            ConfigureCoreWebView(coreWebView);
            _logger.Write(AppLogEvent.WebViewPolicyConfigured);
            coreWebView.SetVirtualHostNameToFolderMapping(
                WebViewSecurityPolicy.AppHostName,
                assetRoot,
                CoreWebView2HostResourceAccessKind.DenyCors);
            _logger.Write(AppLogEvent.WebViewAssetsMapped);
            var messageHost = new CoreWebViewMessageHost(coreWebView, Dispatcher, _logger);
            _bridge = new WebViewBridge(_router, messageHost, _logger);
            Browser.Source = new Uri($"{WebViewSecurityPolicy.AppOrigin}index.html");
            _logger.Write(AppLogEvent.WebViewInitialized);
        }
        catch (Exception error)
        {
            if (!_windowClosed)
            {
                ShowFatalInitializationPage(
                    HostFatalPage.ForWebViewInitializationFailure(error));
                _logger.Write(AppLogEvent.WebViewInitializationFailed);
            }
        }
    }

    private void ConfigureCoreWebView(CoreWebView2 coreWebView)
    {
        coreWebView.Settings.IsWebMessageEnabled = true;
#if !DEBUG
        WebViewSecurityPolicy.ApplyReleaseFeatures(coreWebView.Settings);
#endif
        coreWebView.NavigationStarting += (_, eventArgs) =>
        {
            if (!WebViewSecurityPolicy.IsAllowedAppAddress(eventArgs.Uri))
            {
                eventArgs.Cancel = true;
            }
        };
        coreWebView.NewWindowRequested += (_, eventArgs) => eventArgs.Handled = true;
        coreWebView.PermissionRequested += (_, eventArgs) =>
        {
            eventArgs.State = CoreWebView2PermissionState.Deny;
            eventArgs.Handled = true;
        };
        coreWebView.DownloadStarting += (_, eventArgs) => eventArgs.Cancel = true;
        coreWebView.AddWebResourceRequestedFilter(
            "*",
            CoreWebView2WebResourceContext.All);
        coreWebView.WebResourceRequested += (_, eventArgs) =>
        {
            if (!WebViewSecurityPolicy.IsAllowedResourceAddress(eventArgs.Request.Uri))
            {
                eventArgs.Response = coreWebView.Environment.CreateWebResourceResponse(
                    Stream.Null,
                    403,
                    "Forbidden",
                    "Content-Type: text/plain");
            }
        };
    }

    private async Task CancelCommandsAndCloseAsync()
    {
        var bridge = _bridge;
        _bridge = null;
        if (bridge is not null)
        {
            await bridge.DisposeAsync();
        }

        _closeApproved = true;
        Close();
    }

    private void ShowFatalInitializationPage(HostFatalPageContent content)
    {
        Browser.Visibility = Visibility.Collapsed;
        FatalTitle.Text = content.Title;
        FatalMessage.Text = content.Message;
        FatalPanel.Visibility = Visibility.Visible;
    }
}
