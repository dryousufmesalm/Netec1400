using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace AmmarTrading.Sync.App.Hosting;

internal static class WindowActivation
{
    private const int RestoreWindow = 9;

    public static void BringToForeground(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (!window.Dispatcher.CheckAccess())
        {
            window.Dispatcher.BeginInvoke(() => BringToForeground(window));
            return;
        }

        if (!window.IsVisible)
        {
            window.Show();
        }

        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }

        var handle = new WindowInteropHelper(window).Handle;
        if (handle != IntPtr.Zero)
        {
            ShowWindow(handle, RestoreWindow);
            BringWindowToTop(handle);
            SetForegroundWindow(handle);
        }

        var wasTopmost = window.Topmost;
        if (!wasTopmost)
        {
            window.Topmost = true;
        }
        window.Activate();
        window.Focus();
        if (!wasTopmost)
        {
            window.Topmost = false;
        }
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool BringWindowToTop(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);
}
