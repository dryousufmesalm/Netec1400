using System.Windows;
using AmmarTrading.Sync.App.Hosting;
using AmmarTrading.Sync.App.Services;
using AmmarTrading.Sync.Core.Bridge;

namespace AmmarTrading.Sync.App;

public partial class App : Application
{
    private IAppMetadataLogger? _logger;
    private MainWindow? _window;
    private SingleInstanceCoordinator? _singleInstance;

    protected override void OnStartup(StartupEventArgs eventArgs)
    {
        base.OnStartup(eventArgs);

        try
        {
            var paths = AppRuntimePaths.CreateDefault();
            _logger = new AppMetadataLogger(paths);
            _singleInstance = new SingleInstanceCoordinator(_logger);
            if (!_singleInstance.IsPrimary)
            {
                var activated = _singleInstance.TryActivatePrimaryAsync()
                    .GetAwaiter()
                    .GetResult();
                _singleInstance.Dispose();
                _singleInstance = null;
                Shutdown(activated ? 0 : 2);
                return;
            }

            _logger.Write(AppLogEvent.ApplicationStarted);
            var router = new BridgeCommandRouter(new PowerShellOperations());
            _window = new MainWindow(router, paths, _logger);
            MainWindow = _window;
            _singleInstance.StartListening(() =>
                _window.Dispatcher.BeginInvoke(() => WindowActivation.BringToForeground(_window)));
            _window.Show();
        }
        catch
        {
            MessageBox.Show(
                "AmmarTrading Sync could not start. Reinstall the application, then try again.",
                "AmmarTrading Sync",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    protected override void OnExit(ExitEventArgs eventArgs)
    {
        _logger?.Write(AppLogEvent.ApplicationStopping);
        _singleInstance?.Dispose();
        base.OnExit(eventArgs);
    }
}
